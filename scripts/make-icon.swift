import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift make-icon.swift /path/to/ScreenFence.iconset\n", stderr)
    exit(1)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func rectangle(_ rect: NSRect, radius: CGFloat, fill: NSColor? = nil,
               stroke: NSColor? = nil, lineWidth: CGFloat = 0) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    if let fill {
        fill.setFill()
        path.fill()
    }
    if let stroke {
        stroke.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

func render(pixelSize: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "ScreenFenceIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(pixelSize) / 1024, y: CGFloat(pixelSize) / 1024)

    let cobalt = NSColor(srgbRed: 0.141, green: 0.365, blue: 0.847, alpha: 1)
    let pale = NSColor(srgbRed: 0.66, green: 0.77, blue: 1, alpha: 1)
    rectangle(NSRect(x: 58, y: 58, width: 908, height: 908), radius: 204, fill: cobalt)

    // The smaller right-hand display supplies the multi-monitor context.
    rectangle(NSRect(x: 627, y: 304, width: 215, height: 287),
              radius: 26, stroke: pale, lineWidth: 25)
    rectangle(NSRect(x: 184, y: 326, width: 427, height: 326),
              radius: 29, stroke: .white, lineWidth: 31)
    rectangle(NSRect(x: 337, y: 687, width: 122, height: 20),
              radius: 10, fill: .white)

    // A cursor stays inside the main display; its tip points at its border.
    let cursor = NSBezierPath()
    cursor.move(to: NSPoint(x: 428, y: 558))
    cursor.line(to: NSPoint(x: 428, y: 375))
    cursor.line(to: NSPoint(x: 476, y: 422))
    cursor.line(to: NSPoint(x: 512, y: 352))
    cursor.line(to: NSPoint(x: 549, y: 371))
    cursor.line(to: NSPoint(x: 513, y: 442))
    cursor.line(to: NSPoint(x: 577, y: 452))
    cursor.close()
    NSColor.white.setFill()
    cursor.fill()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ScreenFenceIcon", code: 2)
    }
    return data
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let file = output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try render(pixelSize: points * scale).write(to: file)
    }
}
