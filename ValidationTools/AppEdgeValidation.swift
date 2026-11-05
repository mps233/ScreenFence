// This process drives the App through Accessibility. All cursor queries and
// relative input run in a separate C helper, outside the App's event loop.
import AppKit
import ApplicationServices
import Darwin
import Foundation

struct DriverFailure: Error, CustomStringConvertible { let description: String }
let arguments = CommandLine.arguments
guard arguments.count >= 4, let processID = Int32(arguments[1]) else {
    fputs("Usage: AppEdgeValidation PID REPORT_PATH HELPER_PATH [--axis right|bottom|all] [--trials 2] [--countdown]\n", stderr)
    exit(64)
}
let reportURL = URL(fileURLWithPath: arguments[2])
let helperURL = URL(fileURLWithPath: arguments[3])
let quickMode = !arguments.contains("--countdown")
var axes = ["right", "bottom"]
if let index = arguments.firstIndex(of: "--axis"), arguments.indices.contains(index + 1) {
    switch arguments[index + 1] {
    case "right": axes = ["right"]
    case "bottom": axes = ["bottom"]
    case "all": break
    default: fputs("Invalid --axis\n", stderr); exit(64)
    }
}
var trialCount = 2
if let index = arguments.firstIndex(of: "--trials"), arguments.indices.contains(index + 1) {
    guard let value = Int(arguments[index + 1]), (1...3).contains(value) else {
        fputs("--trials must be between one and three\n", stderr)
        exit(64)
    }
    trialCount = value
}
var checks: [[String: Any]] = []
var edgeTrials: [[String: Any]] = []
var issues: [String] = []
var finalStatus = Int32(1)
var checksComplete = false
var cleanupStarted = false
var cleanupFinished = false
var cleanupAppStopped = false
var cleanupPointerRestored = false
var activeHelperPIDs = Set<pid_t>()
func saveReport() {
    let complete = edgeTrials.count == axes.count * trialCount
    let report: [String: Any] = [
        "passed": checksComplete && finalStatus == 0 && complete &&
            checks.allSatisfy { $0["passed"] as? Bool == true },
        "checksComplete": checksComplete,
        "appPID": processID,
        "axes": axes,
        "trialsPerAxis": trialCount,
        "quickHotkeyLock": quickMode,
        "activeHelperPIDs": activeHelperPIDs.sorted(),
        "cleanup": [
            "started": cleanupStarted,
            "finished": cleanupFinished,
            "appStopped": cleanupAppStopped,
            "pointerRestored": cleanupPointerRestored
        ],
        "scope": "Cross-process App UI and real-relative IOHIDManager input. Separate observer/injector performs all system cursor queries; App handles confinement. Not a physical-hand feel test.",
        "cases": checks,
        "edgeTrials": edgeTrials,
        "errors": issues
    ]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: reportURL, options: .atomic)
    }
}
func check(_ name: String, _ passed: Bool) {
    checks.append(["case": name, "passed": passed])
    print("\(name): \(passed)")
    fflush(stdout)
    saveReport()
}
func wait(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
func runHelper(_ values: [String], timeout: TimeInterval = 2) throws -> (Int32, Data, String) {
    let process = Process()
    process.executableURL = helperURL
    process.arguments = values
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    activeHelperPIDs.insert(process.processIdentifier)
    saveReport()
    defer {
        activeHelperPIDs.remove(process.processIdentifier)
        saveReport()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { wait(0.01) }
    if process.isRunning {
        process.terminate()
        wait(0.08)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        throw DriverFailure(description: "Relative helper exceeded \(timeout)s deadline")
    }
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (process.terminationStatus, data, error)
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}
func find(_ element: AXUIElement, role: String? = nil, text: String, depth: Int = 0) -> AXUIElement? {
    guard depth < 15 else { return nil }
    let r = attribute(element, kAXRoleAttribute) as? String ?? ""
    let descriptions = [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute].compactMap {
        attribute(element, $0) as? String
    }
    if (role == nil || r == role!) && descriptions.contains(where: { $0.contains(text) }) { return element }
    if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children {
            if let result = find(child, role: role, text: text, depth: depth + 1) { return result }
        }
    }
    return nil
}
func tapEnabled() -> Bool {
    var count: UInt32 = 0
    guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return false }
    var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
    guard CGGetEventTapList(count, &list, &count) == .success else { return false }
    return list.contains { $0.tappingProcess == processID && $0.enabled && $0.eventsOfInterest != 0 }
}
func execute() throws {
    guard AXIsProcessTrusted() else {
        finalStatus = 77
        throw DriverFailure(description: "The validation process needs existing Accessibility permission; none was requested")
    }
    var candidate: NSRunningApplication?
    for _ in 0..<60 {
        candidate = NSRunningApplication(processIdentifier: processID)
        if candidate != nil { break }
        wait(0.05)
    }
    guard let app = candidate else { throw DriverFailure(description: "App did not register within three seconds") }
    let root = AXUIElementCreateApplication(processID)
    AXUIElementSetMessagingTimeout(root, 0.7)
    @discardableResult func press(_ role: String, _ text: String) -> Bool {
        guard let element = find(root, role: role, text: text) else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
    let originalResult = try runHelper(["--where"], timeout: 1)
    let original = String(decoding: originalResult.1, as: UTF8.self).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard originalResult.0 == 0 && original.count == 2 else { throw DriverFailure(description: "Could not save pointer position") }
    let emergency = find(root, role: "AXMenuItem", text: "立即解除")
    defer {
        cleanupStarted = true
        saveReport()
        if let emergency { _ = AXUIElementPerformAction(emergency, kAXPressAction as CFString) }
        app.terminate()
        for _ in 0..<20 {
            if app.isTerminated { break }
            wait(0.025)
        }
        if !app.isTerminated { app.forceTerminate() }
        for _ in 0..<8 {
            if app.isTerminated { break }
            wait(0.025)
        }
        cleanupAppStopped = app.isTerminated
        if cleanupAppStopped {
            cleanupPointerRestored = (try? runHelper(["--restore"] + original, timeout: 1).0) == 0
        }
        cleanupFinished = true
        saveReport()
    }
    if find(root, role: "AXButton", text: "开启权限") != nil {
        finalStatus = 77
        throw DriverFailure(description: "App is not Accessibility-authorized; no permission requested")
    }
    guard let countdown = find(root, role: "AXButton", text: "3 秒后锁定") else {
        finalStatus = 77
        throw DriverFailure(description: "App has no ready lock button")
    }
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let center = [String(Double(bounds.midX)), String(Double(bounds.midY))]
    _ = try runHelper(["--restore"] + center, timeout: 1)
    let armed: Bool
    if quickMode {
        app.activate(options: [.activateAllWindows])
        wait(0.08)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 37, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 37, keyDown: false) else {
            throw DriverFailure(description: "Could not allocate the controlled lock hotkey")
        }
        down.flags = [.maskCommand]
        up.flags = [.maskCommand]
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        wait(0.2)
        armed = true
    } else {
        armed = AXUIElementPerformAction(countdown, kAXPressAction as CFString) == .success
        wait(3.2)
    }
    check(quickMode ? "Global hotkey establishes App-owned active tap" : "UI countdown establishes App-owned active tap", armed && tapEnabled())
    guard tapEnabled() else { throw DriverFailure(description: "App did not retain an active tap after lock") }
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(options: [.activateAllWindows])
    wait(0.15)
    check("Finder foreground retains App lock", tapEnabled() && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder")
    for axis in axes {
        for repeatIndex in 1...trialCount {
            let before = tapEnabled()
            let (status, data, error) = try runHelper(["0", axis, String(processID)], timeout: 2)
            guard var trial = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DriverFailure(description: "Relative helper did not return JSON: \(error)")
            }
            let after = tapEnabled()
            let normal = trial[axis == "right" ? "pushedX" : "pushedY"] as? Double ?? .nan
            let expected = Double(axis == "right" ? bounds.maxX - 1 : bounds.maxY - 1)
            let returnedNormal = trial[axis == "right" ? "inwardX" : "inwardY"] as? Double ?? .nan
            let confined = normal.isFinite && abs(normal - expected) < 0.01
            let clean = trial["interference"] as? Bool == false &&
                trial["physicalMonitorAvailable"] as? Bool == true &&
                (trial["events"] as? Int == 27) &&
                (trial["timeouts"] as? Int == 0) &&
                (trial["injectionError"] as? Int == 0)
            let passed = status == 0 && before && after && clean && confined &&
                trial["tangentMoved"] as? Bool == true && trial["inwardImmediate"] as? Bool == true &&
                returnedNormal < normal - 0.5
            trial["repeat"] = repeatIndex
            trial["appTapBefore"] = before
            trial["appTapAfter"] = after
            trial["normalConfined"] = confined
            trial["expectedNormal"] = expected
            trial["passed"] = passed
            trial["helperExit"] = status
            trial["helperStderr"] = error
            edgeTrials.append(trial)
            check("\(axis) sustained edge / tangent / first inward, trial \(repeatIndex)", passed)
            if !before || !after { throw DriverFailure(description: "App tap stopped during relative motion") }
            if trial["timeouts"] as? Int != 0 {
                throw DriverFailure(description: "The external input observer timed out; the trial is invalid")
            }
            if trial["physicalHIDInputs"] as? Int ?? 0 > 0 {
                throw DriverFailure(description: "Physical mouse input interfered with the trial")
            }
            if !clean {
                throw DriverFailure(description: "Relative trial was not clean or did not observe exactly 27 own input events")
            }
        }
    }
    let opened = press("AXMenuItem", "设置与屏幕选择")
    wait(0.08)
    check("opening settings retains App lock", opened && tapEnabled())
    if let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement], let window = windows.first,
       let closeValue = attribute(window, kAXCloseButtonAttribute) {
        let close = unsafeBitCast(closeValue, to: AXUIElement.self)
        let closed = AXUIElementPerformAction(close, kAXPressAction as CFString) == .success
        wait(0.08)
        check("closing settings retains App lock", closed && tapEnabled())
    } else { check("closing settings retains App lock", false) }
    if let emergency { _ = AXUIElementPerformAction(emergency, kAXPressAction as CFString) }
    wait(0.08)
    check("emergency menu releases App lock", !tapEnabled())
    finalStatus = checks.allSatisfy { $0["passed"] as? Bool == true } ? 0 : 1
    checksComplete = true
    // Publish the completed App checks before the potentially slower teardown.
    // The outer harness records cleanup deadlines separately from these results.
    saveReport()
}
do { try execute() }
catch {
    issues.append(String(describing: error))
    fputs("Cross-process check: \(error)\n", stderr)
}
saveReport()
exit(finalStatus)
