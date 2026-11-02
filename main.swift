import Cocoa
import Carbon
import ApplicationServices

final class App: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var lockedScreenID: CGDirectDisplayID?
    var tap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var hotKeyRef: EventHotKeyRef?
    var eventSource: CGEventSource!
    var pullbackWork: DispatchWorkItem?
    let unlockedIcon: NSImage = {
        let img = NSImage(systemSymbolName: "rectangle", accessibilityDescription: "ScreenLock")!
        img.isTemplate = true
        return img
    }()
    let lockedIcon: NSImage = {
        let img = NSImage(systemSymbolName: "lock.rectangle", accessibilityDescription: "ScreenLock locked")!
        img.isTemplate = true
        return img
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        eventSource = CGEventSource(stateID: .combinedSessionState)
        eventSource.localEventsSuppressionInterval = 0
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = unlockedIcon
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "ScreenLock — 把鼠标锁在一块屏幕里"
        rebuildMenu()
        registerHotKey()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    func updateIcon() {
        item.button?.image = lockedScreenID == nil ? unlockedIcon : lockedIcon
        item.button?.title = ""
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let toggleItem = NSMenuItem(
            title: lockedScreenID == nil ? "锁定当前屏幕  (⌥⌘L)" : "解锁鼠标  (⌥⌘L)",
            action: #selector(toggle), keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        let cursor = NSEvent.mouseLocation
        for (i, s) in NSScreen.screens.enumerated() {
            let did = displayID(of: s)
            let main = s == NSScreen.main ? " · 主屏" : ""
            let under = NSMouseInRect(cursor, s.frame, false) ? " · 鼠标在这" : ""
            let name = s.localizedName.isEmpty ? "显示器 \(i + 1)" : s.localizedName
            let mi = NSMenuItem(
                title: "\(name)\(main)\(under)",
                action: #selector(lockToScreen(_:)), keyEquivalent: ""
            )
            mi.target = self
            mi.representedObject = NSNumber(value: did)
            mi.state = lockedScreenID == did ? .on : .off
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        let perm = NSMenuItem(title: "打开辅助功能权限设置", action: #selector(openPerm), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        updateIcon()
    }

    func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return CGDirectDisplayID(num?.uint32Value ?? 0)
    }

    func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == id }
    }

    @objc func screensChanged() {
        if let id = lockedScreenID, screen(for: id) == nil { unlock() }
        rebuildMenu()
    }

    func registerHotKey() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ud in
            let me = Unmanaged<App>.fromOpaque(ud!).takeUnretainedValue()
            DispatchQueue.main.async { me.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x534C4B31), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_L),
            UInt32(optionKey | cmdKey),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    @objc func toggle() {
        if lockedScreenID != nil {
            unlock()
            return
        }
        let cursor = NSEvent.mouseLocation
        let s = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
        guard let s else { return }
        lock(to: displayID(of: s))
    }

    @objc func lockToScreen(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        let id = CGDirectDisplayID(n.uint32Value)
        if lockedScreenID == id { unlock() } else { lock(to: id) }
    }

    func ensureTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        openPerm()
        let a = NSAlert()
        a.messageText = "需要辅助功能权限"
        a.informativeText = "请勾选 ScreenLock。若已勾过，删掉后重新添加 ~/Applications/ScreenLock.app，再打开本应用。"
        a.runModal()
        return false
    }

    /// True only when the point is on this display (half-open bounds, no fake inset).
    func isOnDisplay(_ p: CGPoint, _ b: CGRect) -> Bool {
        p.x >= b.minX && p.x < b.maxX && p.y >= b.minY && p.y < b.maxY
    }

    /// Park just inside so the next HID sample does not immediately re-cross the seam.
    func clamped(_ p: CGPoint, in b: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(p.x, b.minX + 1), b.maxX - 1),
            y: min(max(p.y, b.minY + 1), b.maxY - 1)
        )
    }

    func lock(to id: CGDirectDisplayID) {
        guard ensureTrusted() else { return }
        unlockTap()
        cancelPullback()
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        eventSource.localEventsSuppressionInterval = 0
        lockedScreenID = id

        let b = CGDisplayBounds(id)
        if let loc = CGEvent(source: nil)?.location, !isOnDisplay(loc, b) {
            CGWarpMouseCursorPosition(clamped(loc, in: b))
        }

        startTap()
        rebuildMenu()
    }

    func unlock() {
        unlockTap()
        cancelPullback()
        lockedScreenID = nil
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        rebuildMenu()
    }

    func cancelPullback() {
        pullbackWork?.cancel()
        pullbackWork = nil
    }

    func schedulePullback() {
        cancelPullback()
        let work = DispatchWorkItem { [weak self] in
            self?.pullBackIfNeeded()
        }
        pullbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: work)
    }

    func pullBackIfNeeded() {
        guard let id = lockedScreenID else { return }
        let b = CGDisplayBounds(id)
        guard let loc = CGEvent(source: nil)?.location, !isOnDisplay(loc, b) else { return }
        CGWarpMouseCursorPosition(clamped(loc, in: b))
    }

    func startTap() {
        let mask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
        let ref = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        // listenOnly: never rewrite events, so window dragging stays fully 跟手.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                let me = Unmanaged<App>.fromOpaque(refcon!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                    return nil
                }
                me.observe(event)
                return nil
            },
            userInfo: ref
        ) else {
            lockedScreenID = nil
            let a = NSAlert()
            a.messageText = "无法创建鼠标监听"
            a.informativeText = "请到 系统设置 › 隐私与安全性 › 辅助功能 里勾选 ScreenLock。"
            a.runModal()
            rebuildMenu()
            return
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func unlockTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    func observe(_ event: CGEvent) {
        guard let id = lockedScreenID else { return }
        let b = CGDisplayBounds(id)
        let p = event.location
        guard !isOnDisplay(p, b) else { return }
        CGWarpMouseCursorPosition(clamped(p, in: b))
        // Only for free cursor moves — avoid delayed warps while dragging windows.
        if event.type == .mouseMoved {
            schedulePullback()
        }
    }

    @objc func openPerm() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        unlockTap()
        cancelPullback()
        lockedScreenID = nil
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
