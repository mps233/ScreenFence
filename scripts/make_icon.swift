import Cocoa
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
// macOS squircle-ish rounded rect with inset
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
ctx.saveGState()
let shadow = NSShadow(); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.set()
NSColor.black.setFill(); path.fill()
ctx.restoreGState()
path.addClip()
let grad = NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.45, blue: 1.0, alpha: 1),
                               NSColor(calibratedRed: 0.42, green: 0.20, blue: 0.95, alpha: 1)])!
grad.draw(in: rect, angle: -60)
// symbol
let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "lock.rectangle", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = sym.size
    let r = CGRect(x: (size - s.width)/2, y: (size - s.height)/2, width: s.width, height: s.height)
    sym.draw(in: r)
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
