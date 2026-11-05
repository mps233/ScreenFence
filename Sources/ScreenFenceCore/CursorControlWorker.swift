import CoreGraphics
import Foundation

struct CursorCorrectionReport {
    let warpUsec: Double
    let associateUsec: Double
    let warpSucceeded: Bool
    let associateSucceeded: Bool
}

/// Cursor operations remain ordered with the original event on the tap thread.
/// The state lock never covers a cursor/server call. stop() can run on any
/// thread; source restoration belongs to finishOnEventThread() after teardown.
final class CursorControlWorker {
    private struct SavedSource {
        let source: CGEventSource
        let interval: Double
        let suppressionFilter: CGEventFilterMask
        let dragFilter: CGEventFilterMask
    }
    private enum StartupError: LocalizedError {
        case unavailable, stopped
        var errorDescription: String? {
            switch self {
            case .unavailable: return "无法准备鼠标控制，未开启锁定。"
            case .stopped: return "鼠标控制已取消。"
            }
        }
    }

    private let region: FenceRegion
    private let onCorrection: (CursorCorrectionReport) -> Void
    private let onFailure: (String) -> Void
    private let mutex = NSLock()
    private var started = false
    private var stopped = false
    private var active = false
    // Only the event thread accesses source objects and saved settings.
    private var savedSources: [SavedSource] = []

    init(region: FenceRegion,
         onCorrection: @escaping (CursorCorrectionReport) -> Void,
         onFailure: @escaping (String) -> Void) {
        self.region = region
        self.onCorrection = onCorrection
        self.onFailure = onFailure
    }

    /// Invoked by the dedicated event thread before enabling its event tap.
    func start() throws {
        mutex.lock()
        guard !started, !stopped else { mutex.unlock(); throw StartupError.stopped }
        started = true
        mutex.unlock()
        let prepared = prepareSources()
        mutex.lock()
        let cancelled = stopped
        active = prepared && !cancelled
        mutex.unlock()
        guard prepared, !cancelled else {
            restoreSources()
            throw cancelled ? StartupError.stopped : StartupError.unavailable
        }
    }

    /// Invoked synchronously after the session releases its own state mutex.
    /// Completing the correction before returning the hardware event prevents
    /// a later event commit from restoring an already-outside kernel position.
    func request(point: CGPoint, needsCorrection: Bool) {
        guard needsCorrection, point.x.isFinite, point.y.isFinite else { return }
        correct(region.constrain(point))
    }

    /// No IPC or restoration here: an in-flight event must finish its cleanup.
    func stop() {
        mutex.lock()
        stopped = true
        active = false
        mutex.unlock()
    }

    /// Invoked on the event thread after its run loop and tap have stopped.
    func finishOnEventThread() {
        stop()
        restoreSources()
    }

    private var isActive: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return active
    }

    private func prepareSources() -> Bool {
        guard let hid = CGEventSource(stateID: .hidSystemState),
              let combined = CGEventSource(stateID: .combinedSessionState) else { return false }
        let permitAll: CGEventFilterMask = [
            .permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents
        ]
        for source in [hid, combined] {
            savedSources.append(SavedSource(
                source: source, interval: source.localEventsSuppressionInterval,
                suppressionFilter: source.getLocalEventsFilterDuringSuppressionState(
                    .eventSuppressionStateSuppressionInterval),
                dragFilter: source.getLocalEventsFilterDuringSuppressionState(
                    .eventSuppressionStateRemoteMouseDrag)
            ))
            source.localEventsSuppressionInterval = 0
            source.setLocalEventsFilterDuringSuppressionState(
                permitAll, state: .eventSuppressionStateSuppressionInterval)
            source.setLocalEventsFilterDuringSuppressionState(
                permitAll, state: .eventSuppressionStateRemoteMouseDrag)
        }
        return true
    }

    private func restoreSources() {
        let previous = savedSources
        savedSources.removeAll()
        for saved in previous {
            saved.source.localEventsSuppressionInterval = saved.interval
            saved.source.setLocalEventsFilterDuringSuppressionState(
                saved.suppressionFilter, state: .eventSuppressionStateSuppressionInterval)
            saved.source.setLocalEventsFilterDuringSuppressionState(
                saved.dragFilter, state: .eventSuppressionStateRemoteMouseDrag)
        }
    }

    private func correct(_ point: CGPoint) {
        guard isActive else { return }
        let warpStart = DispatchTime.now().uptimeNanoseconds
        let warp = CGWarpMouseCursorPosition(point)
        let warpEnd = DispatchTime.now().uptimeNanoseconds
        // stop() may race the warp. Always finish reassociation after a
        // successful warp so release does not leave hardware input detached.
        let associateStart = DispatchTime.now().uptimeNanoseconds
        let associate: CGError = warp == .success ? CGAssociateMouseAndMouseCursorPosition(1) : .failure
        let associateEnd = DispatchTime.now().uptimeNanoseconds
        onCorrection(CursorCorrectionReport(
            warpUsec: Double(warpEnd - warpStart) / 1_000,
            associateUsec: warp == .success ? Double(associateEnd - associateStart) / 1_000 : 0,
            warpSucceeded: warp == .success,
            associateSucceeded: associate == .success
        ))
        if warp != .success || associate != .success {
            mutex.lock()
            let shouldReport = active
            active = false
            mutex.unlock()
            if shouldReport {
                onFailure("系统拒绝鼠标边界修正，已解除锁定。请检查屏界的辅助功能权限。")
            }
        }
    }
}
