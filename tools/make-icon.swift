// make-icon.swift — renders Resources/AppIcon.icns for My MacMonitor.
// Drawn with plain Core Graphics paths (no SF Symbols: Apple's license forbids them in app icons).
// Usage:  swift tools/make-icon.swift   (from the repo root; needs iconutil, ships with macOS)
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px) / 1024   // all geometry is authored on a 1024 grid
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }

    // Background squircle on the macOS icon grid (824 pt body, 100 pt margin).
    let body = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(srgbRed: 0.43, green: 0.20, blue: 0.93, alpha: 1),
               ending: NSColor(srgbRed: 0.10, green: 0.09, blue: 0.32, alpha: 1))!
        .draw(in: body, angle: -90)

    // Monitor: white bezel, dark screen, neck and foot.
    NSColor.white.setFill()
    NSBezierPath(roundedRect: r(232, 400, 560, 360), xRadius: 34 * s, yRadius: 34 * s).fill()
    NSBezierPath(roundedRect: r(472, 300, 80, 110), xRadius: 8 * s, yRadius: 8 * s).fill()
    NSBezierPath(roundedRect: r(372, 262, 280, 52), xRadius: 26 * s, yRadius: 26 * s).fill()
    let screen = NSBezierPath(roundedRect: r(262, 430, 500, 300), xRadius: 16 * s, yRadius: 16 * s)
    NSGradient(starting: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.16, alpha: 1),
               ending: NSColor(srgbRed: 0.18, green: 0.13, blue: 0.42, alpha: 1))!
        .draw(in: screen, angle: 90)

    // Speaker cone on the screen.
    let cyan = NSColor(srgbRed: 0.40, green: 0.91, blue: 0.98, alpha: 1)
    cyan.setFill()
    let spk = NSBezierPath()
    spk.move(to: NSPoint(x: 360 * s, y: 545 * s))
    spk.line(to: NSPoint(x: 405 * s, y: 545 * s))
    spk.line(to: NSPoint(x: 465 * s, y: 495 * s))
    spk.line(to: NSPoint(x: 465 * s, y: 665 * s))
    spk.line(to: NSPoint(x: 405 * s, y: 615 * s))
    spk.line(to: NSPoint(x: 360 * s, y: 615 * s))
    spk.close()
    spk.fill()

    // Three sound waves, growing and fading out.
    for (i, radius) in [CGFloat(60), 110, 160].enumerated() {
        cyan.withAlphaComponent(1 - CGFloat(i) * 0.25).setStroke()
        let wave = NSBezierPath()
        wave.appendArc(withCenter: NSPoint(x: 470 * s, y: 580 * s), radius: radius * s,
                       startAngle: -40, endAngle: 40)
        wave.lineWidth = 26 * s
        wave.lineCapStyle = .round
        wave.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
