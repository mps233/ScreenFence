import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var hotkeys: GlobalHotKeys!
    private var toggleItem: NSMenuItem!
    private var displayItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let other = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.miaopasi.screenfence"
        ).first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        setupStatusItem()
        hotkeys = GlobalHotKeys(
            onToggle: { [weak self] in self?.model.toggleLock() },
            onEmergency: { [weak self] in self?.model.emergencyUnlock() }
        )
        model.setHotkeysAvailable(hotkeys.register())
        model.onStateChange = { [weak self] in self?.updateStatus() }
        updateStatus()

        showSettings(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
        hotkeys?.unregister()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return true
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        displayItem = NSMenuItem(title: "屏界 · 未锁定", action: nil, keyEquivalent: "")
        menu.addItem(displayItem)
        menu.addItem(.separator())
        toggleItem = NSMenuItem(title: "3 秒后锁定", action: #selector(toggleFromMenu), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let emergency = NSMenuItem(title: "立即解除    ⌃⌥⌘Esc", action: #selector(emergencyUnlock), keyEquivalent: "")
        emergency.target = self
        menu.addItem(emergency)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置与屏幕选择…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "退出屏界", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.refreshPermissions()
        updateStatus()
    }

    private func updateStatus() {
        let symbol = model.isLocked ? "lock.display" : "display"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "屏界")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = ""
        statusItem.button?.toolTip = model.statusMessage
        if let id = model.lockedDisplayID, let display = model.displays.first(where: { $0.id == id }) {
            displayItem.title = "已锁定 · \(display.name)"
        } else {
            displayItem.title = model.countdown > 0 ? "\(model.countdown) 秒后锁定" : "屏界 · 未锁定"
        }
        toggleItem.title = model.isLocked ? "解除锁定    ⌘L" :
            (model.countdown > 0 ? "取消倒计时" : "3 秒后锁定    ⌘L")
    }

    @objc private func toggleFromMenu() {
        if model.isLocked || model.countdown > 0 { model.unlock() }
        else { model.beginLockCountdown() }
    }

    @objc private func emergencyUnlock() {
        model.emergencyUnlock()
    }

    @objc private func showSettings(_ sender: Any?) {
        if window == nil {
            let panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            panel.title = "屏界"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: SettingsView(model: model))
            panel.minSize = NSSize(width: 630, height: 620)
            panel.center()
            window = panel
        }
        if let id = model.lockedDisplayID,
           let screen = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
           }), let window {
            let area = screen.visibleFrame
            var frame = window.frame
            frame.size.width = min(frame.width, area.width)
            frame.size.height = min(frame.height, area.height)
            frame.origin = NSPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
            window.setFrame(frame, display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func quitApp() {
        model.emergencyUnlock()
        NSApp.terminate(nil)
    }

}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) {
        application.run()
    }
}
