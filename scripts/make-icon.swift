// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit
import CoreGraphics

func hex(_ v: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let c = ctx.cgContext
    let s = CGFloat(pixels) / 1024
    c.scaleBy(x: s, y: s)  // draw in 1024 space, origin bottom-left
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!

    // Squircle-ish rounded rect: 824 centred, radius 185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.saveGState()
    c.addPath(path); c.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [hex(0x1590A8), hex(0x117E94)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Tunnel portal. Centre x=512; arch outer radius, sides down to baseY.
    let cx: CGFloat = 512, baseY: CGFloat = 270, sideTopY: CGFloat = 560
    let r: CGFloat = 215          // centreline radius
    let stroke: CGFloat = 70
    // Filled opening (inner region of the arch).
    let inner = CGMutablePath()
    inner.move(to: CGPoint(x: cx - r, y: baseY))
    inner.addLine(to: CGPoint(x: cx - r, y: sideTopY))
    inner.addArc(center: CGPoint(x: cx, y: sideTopY), radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
    inner.addLine(to: CGPoint(x: cx + r, y: baseY))
    inner.closeSubpath()
    c.addPath(inner); c.setFillColor(hex(0x0B5566)); c.fillPath()

    // Light at the vanishing point.
    let lc = CGPoint(x: cx, y: 500)
    let glow = CGGradient(colorsSpace: cs, colors: [hex(0xFFE7A3).copy(alpha: 0.55)!, hex(0xFFE7A3).copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: lc, startRadius: 0, endCenter: lc, endRadius: 120, options: [])
    c.setFillColor(hex(0xFFE7A3))
    c.fillEllipse(in: CGRect(x: lc.x - 46, y: lc.y - 46, width: 92, height: 92))

    // White arch stroke.
    let arch = CGMutablePath()
    arch.move(to: CGPoint(x: cx - r, y: baseY))
    arch.addLine(to: CGPoint(x: cx - r, y: sideTopY))
    arch.addArc(center: CGPoint(x: cx, y: sideTopY), radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
    arch.addLine(to: CGPoint(x: cx + r, y: baseY))
    c.addPath(arch)
    c.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    c.setLineWidth(stroke); c.setLineCap(.butt); c.setLineJoin(.round)
    c.strokePath()
    c.restoreGState()

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.icns>\n".data(using: .utf8)!)
    exit(2)
}
let out = CommandLine.arguments[1]
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wirely-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

for base in [16, 32, 128, 256, 512] {
    try render(pixels: base).write(to: tmp.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2).write(to: tmp.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", out]
try p.run(); p.waitUntilExit()
exit(p.terminationStatus)
