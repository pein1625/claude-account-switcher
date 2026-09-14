// Renders the app icon (two account circles + a swap arrow) into an .iconset directory.
// usage: swift scripts/make-icon.swift build/AppIcon.iconset
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size
    let bg = NSBezierPath(roundedRect: NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9), xRadius: s * 0.2, yRadius: s * 0.2)
    let grad = NSGradient(colors: [NSColor(calibratedRed: 0.85, green: 0.45, blue: 0.25, alpha: 1), NSColor(calibratedRed: 0.55, green: 0.22, blue: 0.12, alpha: 1)])!
    grad.draw(in: bg, angle: -90)
    NSColor.white.withAlphaComponent(0.95).setFill()
    NSBezierPath(ovalIn: NSRect(x: s * 0.16, y: s * 0.50, width: s * 0.30, height: s * 0.30)).fill()
    NSColor.white.withAlphaComponent(0.65).setFill()
    NSBezierPath(ovalIn: NSRect(x: s * 0.54, y: s * 0.20, width: s * 0.30, height: s * 0.30)).fill()
    let arrow = NSBezierPath()
    arrow.lineWidth = s * 0.06
    arrow.lineCapStyle = .round
    arrow.move(to: NSPoint(x: s * 0.32, y: s * 0.42))
    arrow.curve(to: NSPoint(x: s * 0.68, y: s * 0.58), controlPoint1: NSPoint(x: s * 0.32, y: s * 0.25), controlPoint2: NSPoint(x: s * 0.68, y: s * 0.75))
    NSColor.white.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.lineWidth = s * 0.06; head.lineCapStyle = .round; head.lineJoinStyle = .round
    head.move(to: NSPoint(x: s * 0.68, y: s * 0.45)); head.line(to: NSPoint(x: s * 0.68, y: s * 0.58)); head.line(to: NSPoint(x: s * 0.56, y: s * 0.60))
    head.stroke()
    img.unlockFocus()
    return img
}

func write(_ img: NSImage, _ px: Int, _ name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}

for base in [16, 32, 128, 256, 512] {
    write(draw(CGFloat(base)), base, "icon_\(base)x\(base).png")
    write(draw(CGFloat(base * 2)), base * 2, "icon_\(base)x\(base)@2x.png")
}
print("iconset -> \(out)")
