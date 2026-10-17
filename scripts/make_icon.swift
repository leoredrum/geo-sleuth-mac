// Renders the app icon PNG: a map-pin over a globe on a gradient tile.
import AppKit

let size = CGFloat(Int(CommandLine.arguments[2]) ?? 1024)
let out = CommandLine.arguments[1]
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
let tile = NSBezierPath(roundedRect: rect, xRadius: size * 0.18, yRadius: size * 0.18)
NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.95, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.75, blue: 0.55, alpha: 1)])!
    .draw(in: tile, angle: -60)
let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
for (name, dy, alpha) in [("globe.asia.australia", -0.03, 0.35), ("mappin.and.ellipse", 0.02, 1.0)] {
    if let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = sym.size
        let r = NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + size * dy, width: s.width, height: s.height)
        sym.draw(in: r, from: .zero, operation: .sourceOver, fraction: alpha)
    }
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
