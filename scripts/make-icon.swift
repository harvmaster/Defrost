// Renders Resources/AppIcon.icns: a snowflake on a blue tile that thaws at the bottom.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.80, blue: 0.98, alpha: 1),
                        NSColor(calibratedRed: 0.12, green: 0.42, blue: 0.86, alpha: 1)])!.draw(in: path, angle: -90)

    let c = NSPoint(x: s / 2, y: s * 0.54)
    let r = tile.width * 0.30
    NSColor.white.setStroke()
    for i in 0..<6 {
        let a = CGFloat(i) * .pi / 3 + .pi / 2
        let tip = NSPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
        let arm = NSBezierPath()
        arm.lineWidth = s * 0.035
        arm.lineCapStyle = .round
        arm.move(to: c); arm.line(to: tip)
        for side in [-1.0, 1.0] {
            let mid = NSPoint(x: c.x + cos(a) * r * 0.6, y: c.y + sin(a) * r * 0.6)
            let b = a + CGFloat(side) * .pi / 4
            arm.move(to: mid)
            arm.line(to: NSPoint(x: mid.x + cos(b) * r * 0.32, y: mid.y + sin(b) * r * 0.32))
        }
        arm.stroke()
    }
    // A drip falling from the bottom arm.
    NSColor.white.setFill()
    let dropC = NSPoint(x: c.x, y: c.y - r - s * 0.075)
    let dropR = s * 0.032
    let drop = NSBezierPath(ovalIn: NSRect(x: dropC.x - dropR, y: dropC.y - dropR, width: dropR * 2, height: dropR * 2))
    drop.move(to: NSPoint(x: dropC.x - dropR * 0.95, y: dropC.y + dropR * 0.3))
    drop.line(to: NSPoint(x: dropC.x, y: dropC.y + dropR * 2.3))
    drop.line(to: NSPoint(x: dropC.x + dropR * 0.95, y: dropC.y + dropR * 0.3))
    drop.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
