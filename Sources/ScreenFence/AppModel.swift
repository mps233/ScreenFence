import AppKit
import ApplicationServices
import ScreenFenceCore
import SwiftUI

struct DisplayInfo: Identifiable {
    let id: UInt32
    let name: String
    let bounds: CGRect
    let isMain: Bool
    let resolution: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isLocked = false
    @Published private(set) var permissionGranted = false
    @Published private(set) var statusMessage = "将鼠标移到目标屏幕，按 ⌘L 全局锁定；再按一次解除。"
    @Published private(set) var displays: [DisplayInfo] = []
    @Published var selectedDisplayID: UInt32 = 0
    @Published private(set) var lockedDisplayID: UInt32?
    @Published private(set) var countdown = 0
    @Published private(set) var diagnosticSummary = ""

    var onStateChange: (() -> Void)?
    private let engine = CursorFenceEngine()
    private var countdownTimer: Timer?
    private var permissionTimer: Timer?
    private var observations: [NSObjectProtocol] = []
    private var hotkeysReady = false
    private var lockGeneration: UInt64 = 0

    init() {
        refreshDisplays()
        refreshPermissions()
        observeSystemChanges()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    func setHotkeysAvailable(_ available: Bool) {
        hotkeysReady = available
        if !available {
            statusMessage = "快捷键被其他 App 占用，未开启锁定。请关闭冲突的快捷键后重新打开屏界。"
        }
        updateDiagnostics()
    }

    func refreshPermissions() {
        let granted = AXIsProcessTrusted()
        if permissionGranted != granted {
            permissionGranted = granted
            if !granted, isLocked {
                unlock(reason: "辅助功能权限已关闭，已解除锁定。")
            } else if granted {
                statusMessage = "权限已就绪。按 ⌘L 全局锁定鼠标所在屏幕，切换 App 仍保持锁定。"
            }
        }
        if isLocked, !engine.isEnabled {
            unlock(reason: "鼠标限制已停止，已解除锁定。请重新开启。")
        }
        updateDiagnostics()
    }

    func requestPermission() {
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func beginLockCountdown() {
        refreshPermissions()
        guard permissionGranted else { requestPermission(); return }
        guard hotkeysReady else { setHotkeysAvailable(false); return }
        cancelCountdown()
        countdown = 3
        statusMessage = "3 秒后全局锁定，请把鼠标移到目标屏幕。"
        stateChanged()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.countdown -= 1
                if self.countdown <= 0 {
                    self.cancelCountdown()
                    self.lock()
                } else {
                    self.statusMessage = "\(self.countdown) 秒后全局锁定，请把鼠标移到目标屏幕。"
                    self.stateChanged()
                }
            }
        }
    }

    func toggleLock() {
        if isLocked || countdown > 0 {
            unlock()
        } else {
            lock()
        }
    }

    func unlock() {
        unlock(reason: "已解除，可自由跨屏移动。")
    }

    func emergencyUnlock() {
        unlock(reason: "已紧急解除，可自由跨屏移动。")
    }

    func shutdown() {
        cancelCountdown()
        permissionTimer?.invalidate()
        engine.stop()
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
        }
        observations.removeAll()
    }

    func openReadme() {
        if let url = Bundle.main.url(forResource: "使用说明", withExtension: "txt") {
            NSWorkspace.shared.open(url)
        }
    }

    func copyDiagnostics() {
        updateDiagnostics()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticSummary, forType: .string)
        if !isLocked { statusMessage = "诊断信息已复制，包含显示器布局、权限与边界修正次数。"; stateChanged() }
    }

    private func lock() {
        cancelCountdown()
        refreshPermissions()
        guard permissionGranted else {
            statusMessage = "需要先在「隐私与安全性 → 辅助功能」中允许屏界。"
            stateChanged()
            return
        }
        guard hotkeysReady else { setHotkeysAvailable(false); stateChanged(); return }
        refreshDisplays()
        guard let point = CGEvent(source: nil)?.location else {
            statusMessage = "无法读取鼠标位置，未开启锁定。"
            stateChanged()
            return
        }
        let display: DisplayInfo?
        if selectedDisplayID == 0 {
            display = displays.first { $0.bounds.contains(point) }
        } else {
            display = displays.first { $0.id == selectedDisplayID }
        }
        guard let display, let region = FenceRegion(bounds: display.bounds) else {
            statusMessage = "目标屏幕不可用，请重新选择屏幕。"
            stateChanged()
            return
        }
        guard display.bounds.contains(point) else {
            statusMessage = "鼠标还不在 \(display.name)。请移入这块屏幕，再按 ⌘L；也可使用 3 秒倒计时。"
            stateChanged()
            return
        }
        lockGeneration &+= 1
        let generation = lockGeneration
        do {
            try engine.start(region: region) { [weak self] message in
                MainActor.assumeIsolated {
                    guard let self, self.lockGeneration == generation else { return }
                    self.unlock(reason: message)
                }
            }
            lockedDisplayID = display.id
            isLocked = true
            statusMessage = "已全局锁定 \(display.name)，切换 App 仍保持锁定。⌘L 解除；⌃⌥⌘Esc 紧急解除。"
            stateChanged()
        } catch {
            statusMessage = error.localizedDescription
            stateChanged()
        }
    }

    private func unlock(reason: String) {
        cancelCountdown()
        lockGeneration &+= 1
        engine.stop()
        isLocked = false
        lockedDisplayID = nil
        statusMessage = reason
        stateChanged()
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = 0
    }

    private func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = number.uint32Value
            let bounds = CGDisplayBounds(id)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            return DisplayInfo(
                id: id, name: screen.localizedName, bounds: bounds,
                isMain: id == CGMainDisplayID(),
                resolution: "\(Int(bounds.width)) × \(Int(bounds.height))"
            )
        }
        if selectedDisplayID != 0, !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = 0
        }
        updateDiagnostics()
    }

    private func observeSystemChanges() {
        let center = NotificationCenter.default
        observations.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let previous = self.displays
                self.refreshDisplays()
                let changed = previous.count != self.displays.count || previous.contains { before in
                    !self.displays.contains { $0.id == before.id && $0.bounds == before.bounds }
                }
                // App/full-screen transitions can notify without changing the
                // actual display geometry. They must not end a global lock.
                if changed { self.unlock(reason: "显示器布局已变化，已解除锁定。") }
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observations.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.unlock(reason: "系统休眠或会话已切换，已解除锁定。") }
            })
        }
        observations.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshPermissions() } })
    }

    private func stateChanged() {
        updateDiagnostics()
        onStateChange?()
    }

    private func updateDiagnostics() {
        let s = engine.statistics
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "开发版"
        let build = info["CFBundleVersion"] as? String ?? "SwiftPM"
        let layout = displays.map {
            "\($0.id) \($0.name): x=\(Int($0.bounds.minX)), y=\(Int($0.bounds.minY)), \($0.resolution)"
        }.joined(separator: "\n")
        diagnosticSummary = """
        屏界 \(version) (\(build))
        系统: \(ProcessInfo.processInfo.operatingSystemVersionString)
        辅助功能: \(permissionGranted)
        全局快捷键: \(hotkeysReady)
        锁定: \(isLocked), 目标: \(lockedDisplayID.map(String.init) ?? "无")
        事件: \(s.events), 修正: \(s.correctedEvents)
        右: \(s.right), 下: \(s.bottom), 左: \(s.left), 上: \(s.top)
        拦截层: \(s.tapLocation)
        拦截已启用: \(engine.isEnabled)
        实际光标修正: \(s.warps), 失败: \(s.warpFailures)
        恢复关联失败: \(s.associateFailures)
        最长耗时(微秒): 回调 \(Int(s.maxCallbackUsec)), 定位 \(Int(s.maxWarpUsec)), 关联 \(Int(s.maxAssociateUsec))
        范围: 全局锁定，与前台 App 无关
        实现: 保留零抑制事件源，按 HID 事件顺序修正光标并恢复关联，分别限制 X/Y
        \(layout)
        """
    }
}
