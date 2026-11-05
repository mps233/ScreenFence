import CoreFoundation
import CoreGraphics
import Foundation

public struct FenceStatistics {
    public var events: UInt64 = 0
    public var correctedEvents: UInt64 = 0
    public var right: UInt64 = 0
    public var bottom: UInt64 = 0
    public var left: UInt64 = 0
    public var top: UInt64 = 0
    public var warps: UInt64 = 0
    public var warpFailures: UInt64 = 0
    public var associateFailures: UInt64 = 0
    public var maxCallbackUsec: Double = 0
    public var maxWarpUsec: Double = 0
    public var maxAssociateUsec: Double = 0
    public var tapLocation: String = "未启动"
}

public enum FenceEngineError: LocalizedError {
    case permissionDenied
    case startupTimedOut
    case runLoopUnavailable

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "无法建立鼠标限制。请在系统设置的「辅助功能」中允许屏界，然后重新打开 App。"
        case .startupTimedOut:
            return "鼠标限制启动超时，已保持未锁定。"
        case .runLoopUnavailable:
            return "无法启动鼠标事件处理，已保持未锁定。"
        }
    }
}

/// Cursor corrections preserve native HID event ordering on the event thread.
/// No WindowServer operation holds the shared state lock.
public final class CursorFenceEngine {
    private var session: FenceTapSession?
    private var retiringSession: FenceTapSession?
    private var previousStatistics = FenceStatistics()

    public init() {}

    public var statistics: FenceStatistics {
        session?.statistics ?? previousStatistics
    }

    public var isEnabled: Bool {
        session?.isEnabled ?? false
    }

    public func start(region: FenceRegion, onInterruption: @escaping (String) -> Void) throws {
        stop()
        // Release stays immediate. A later start waits for the previous source
        // configuration to be restored before preparing its own configuration.
        if let retiringSession {
            guard retiringSession.waitForCleanup() else { throw FenceEngineError.startupTimedOut }
            self.retiringSession = nil
        }
        let next = FenceTapSession(region: region, onInterruption: onInterruption)
        do {
            try next.start()
            session = next
        } catch {
            retiringSession = next
            throw error
        }
    }

    public func stop() {
        guard let current = session else { return }
        current.stop()
        previousStatistics = current.statistics
        retiringSession = current
        session = nil
    }

    deinit { stop() }
}

private final class FenceTapSession {
    private let region: FenceRegion
    private let onInterruption: (String) -> Void
    private let mutex = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var active = true
    private var installed = false
    private var startupError: Error?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var counters = FenceStatistics()
    private var cursorWorker: CursorControlWorker!

    init(region: FenceRegion, onInterruption: @escaping (String) -> Void) {
        self.region = region
        self.onInterruption = onInterruption
        cursorWorker = CursorControlWorker(
            region: region,
            onCorrection: { [weak self] report in self?.record(report) },
            onFailure: { [weak self] message in self?.interrupt(message) }
        )
    }

    var statistics: FenceStatistics {
        mutex.lock()
        defer { mutex.unlock() }
        return counters
    }

    var isEnabled: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return active && installed
    }

    func start() throws {
        let thread = Thread { [self] in run() }
        thread.name = "ScreenFence.MouseEvents"
        thread.qualityOfService = .userInteractive
        thread.start()
        guard ready.wait(timeout: .now() + 2) == .success else {
            stop()
            throw FenceEngineError.startupTimedOut
        }
        mutex.lock()
        let error = startupError
        mutex.unlock()
        if let error { stop(); throw error }
    }

    func waitForCleanup() -> Bool {
        finished.wait(timeout: .now() + 0.5) == .success
    }

    func stop() {
        mutex.lock()
        active = false
        installed = false
        let currentLoop = runLoop
        let currentTap = tap
        mutex.unlock()
        // A slow cursor API cannot prevent manual or emergency release.
        cursorWorker.stop()
        guard let currentLoop else { return }
        CFRunLoopPerformBlock(currentLoop, CFRunLoopMode.commonModes.rawValue) {
            if let currentTap {
                CGEvent.tapEnable(tap: currentTap, enable: false)
                CFMachPortInvalidate(currentTap)
            }
            CFRunLoopStop(currentLoop)
        }
        CFRunLoopWakeUp(currentLoop)
    }

    private func startupFailed(_ error: Error) {
        mutex.lock()
        startupError = error
        active = false
        installed = false
        tap = nil
        runLoop = nil
        mutex.unlock()
        cursorWorker.stop()
        ready.signal()
    }

    private func run() {
        defer { finished.signal() }
        let eventTypes: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let session = Unmanaged<FenceTapSession>.fromOpaque(context).takeUnretainedValue()
            session.process(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        let makeTap: (CGEventTapLocation) -> CFMachPort? = { location in
            CGEvent.tapCreate(
                tap: location, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        }
        let hidTap = makeTap(.cghidEventTap)
        guard let newTap = hidTap ?? makeTap(.cgSessionEventTap) else {
            startupFailed(FenceEngineError.permissionDenied)
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            startupFailed(FenceEngineError.runLoopUnavailable)
            return
        }
        do { try cursorWorker.start() }
        catch {
            CFMachPortInvalidate(newTap)
            startupFailed(error)
            return
        }
        defer { cursorWorker.finishOnEventThread() }
        let loop = CFRunLoopGetCurrent()!
        mutex.lock()
        tap = newTap
        runLoop = loop
        counters.tapLocation = hidTap == nil ? "session" : "HID"
        let shouldRun = active
        mutex.unlock()
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: shouldRun)
        if shouldRun && !CGEvent.tapIsEnabled(tap: newTap) {
            CFMachPortInvalidate(newTap)
            CFRunLoopRemoveSource(loop, source, .commonModes)
            startupFailed(FenceEngineError.permissionDenied)
            return
        }
        mutex.lock()
        installed = shouldRun && active
        mutex.unlock()
        ready.signal()
        if shouldRun { CFRunLoopRun() }
        cursorWorker.stop()
        CGEvent.tapEnable(tap: newTap, enable: false)
        CFMachPortInvalidate(newTap)
        CFRunLoopRemoveSource(loop, source, .commonModes)
        mutex.lock()
        active = false
        installed = false
        runLoop = nil
        tap = nil
        mutex.unlock()
    }

    private func process(type: CGEventType, event: CGEvent) {
        let began = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000
            mutex.lock()
            counters.maxCallbackUsec = max(counters.maxCallbackUsec, elapsed)
            mutex.unlock()
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? "事件处理超时" : "系统输入状态改变"
            interrupt("\(reason)，已解除锁定。可再次按快捷键开启。")
            return
        }
        mutex.lock()
        guard active else { mutex.unlock(); return }
        counters.events &+= 1
        let point = event.location
        guard point.x.isFinite, point.y.isFinite else { mutex.unlock(); return }
        if point.x > region.maximumX { counters.right &+= 1 }
        if point.y > region.maximumY { counters.bottom &+= 1 }
        if point.x < region.bounds.minX { counters.left &+= 1 }
        if point.y < region.bounds.minY { counters.top &+= 1 }
        let corrected = region.constrain(point)
        let needsCorrection = corrected != point
        if needsCorrection {
            event.location = corrected
            counters.correctedEvents &+= 1
        }
        mutex.unlock()
        // Preserve correction ordering before the HID callback returns, just as
        // the relative-input control test requires. The state lock is released.
        cursorWorker.request(point: corrected, needsCorrection: needsCorrection)
    }

    private func record(_ report: CursorCorrectionReport) {
        mutex.lock()
        if report.warpSucceeded {
            counters.warps &+= 1
        } else { counters.warpFailures &+= 1 }
        if !report.associateSucceeded { counters.associateFailures &+= 1 }
        counters.maxWarpUsec = max(counters.maxWarpUsec, report.warpUsec)
        counters.maxAssociateUsec = max(counters.maxAssociateUsec, report.associateUsec)
        mutex.unlock()
    }

    private func interrupt(_ message: String) {
        mutex.lock()
        guard active else { mutex.unlock(); return }
        active = false
        installed = false
        mutex.unlock()
        cursorWorker.stop()
        DispatchQueue.main.async { [onInterruption] in onInterruption(message) }
    }
}
