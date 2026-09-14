// Renders the disk-image background (1x and 2x PNG) for the drag-to-Applications window.
// usage: swift scripts/make-dmg-bg.swift build/dmg-bg      -> build/dmg-bg.png, build/dmg-bg@2x.png
// Layout constants must match scripts/dmg-settings.py (window 640x460, icons at x=160 and x=480, y=170 from top).
import AppKit

let base = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/dmg-bg"
let W: CGFloat = 640, H: CGFloat = 460

func render(scale: CGFloat) -> Data {
    let px = Int(W * scale), py = Int(H * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)   // points; the context maps them onto the 1x/2x pixel grid
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!

    // soft warm gradient, same family as the app icon
    let bg = NSGradient(colors: [NSColor(calibratedRed: 0.99, green: 0.97, blue: 0.95, alpha: 1),
                                 NSColor(calibratedRed: 0.96, green: 0.92, blue: 0.88, alpha: 1)])!
    bg.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // arrow between the app (x=160) and Applications (x=480); icons are 112pt, centred on y=170 (from top)
    let y: CGFloat = H - 170
    let arrow = NSBezierPath()
    arrow.lineWidth = 6; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 250, y: y))
    arrow.line(to: NSPoint(x: 385, y: y))
    arrow.move(to: NSPoint(x: 360, y: y + 22))
    arrow.line(to: NSPoint(x: 390, y: y))
    arrow.line(to: NSPoint(x: 360, y: y - 22))
    NSColor(calibratedRed: 0.75, green: 0.40, blue: 0.22, alpha: 0.9).setStroke()
    arrow.stroke()

    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: (W - sz.width) / 2, y: centerY - sz.height / 2))
    }
    let ink = NSColor(calibratedRed: 0.30, green: 0.20, blue: 0.16, alpha: 1)
    let dim = NSColor(calibratedRed: 0.30, green: 0.20, blue: 0.16, alpha: 0.65)
    text("Kéo Claude Switcher vào Applications", size: 20, weight: .semibold, color: ink, centerY: H - 52)
    text("Lần đầu mở: System Settings › Privacy & Security › Open Anyway", size: 12, weight: .regular, color: dim, centerY: H - 272)
    text("Cài không cần bước trên: lệnh curl trong file README bên dưới", size: 12, weight: .regular, color: dim, centerY: H - 292)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: base + ".png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: base + "@2x.png"))
print("background -> \(base).png, \(base)@2x.png")
