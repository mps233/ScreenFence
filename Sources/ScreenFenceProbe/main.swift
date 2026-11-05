import AppKit
import ApplicationServices
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--relative-hid") || arguments.contains("--live") {
    // Isolate pointer observation/injection from the App being tested.
    // Same-process absolute-event checks failed to expose the original bug.
    let project = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = project.appendingPathComponent("scripts/validate-relative-hid.py")
    guard FileManager.default.fileExists(atPath: script.path) else {
        fputs("Missing cross-process validation script: \(script.path)\n", stderr)
        exit(64)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    var forwarded = arguments.filter { $0 != "--relative-hid" && $0 != "--live" }
    if !forwarded.contains("--app") {
        let executable = Bundle.main.executableURL ??
            URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let app = executable.deletingLastPathComponent().appendingPathComponent("ScreenFence")
        guard FileManager.default.isExecutableFile(atPath: app.path) else {
            fputs("Build ScreenFence with the same scratch path before running input validation.\n", stderr)
            exit(64)
        }
        // Avoid a nested SwiftPM build while `swift run` owns its build lock.
        forwarded = ["--app", app.path] + forwarded
    }
    process.arguments = ["python3", script.path] + forwarded
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do {
        try process.run()
        process.waitUntilExit()
        exit(process.terminationStatus)
    } catch {
        fputs("Could not run cross-process validation: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let displays: [[String: Any]] = NSScreen.screens.compactMap { screen in
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
    let id = number.uint32Value
    let bounds = CGDisplayBounds(id)
    return [
        "id": id, "name": screen.localizedName,
        "x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height
    ]
}
let report: [String: Any] = [
    "accessibility": AXIsProcessTrusted(),
    "listenAccess": CGPreflightListenEventAccess(),
    "postAccess": CGPreflightPostEventAccess(),
    "displays": displays,
    "relativeHIDTest": "Run --relative-hid for an explicit cross-process App test."
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
