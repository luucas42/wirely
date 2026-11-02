// Usage: swift scripts/make-icon.swift Resources/IconArtwork.png Resources/AppIcon.icns
//
// Composes the macOS app icon from square, full-bleed artwork: the artwork is clipped to the
// rounded-square body of Apple's 1024 pt icon grid (824 pt, centred) with the standard soft drop
// shadow, then rendered at every iconset size and packed with iconutil.
import AppKit
import CoreGraphics

/// Fraction of the artwork kept (centre crop) so the mark fills the icon body a little more.
let cropFraction: CGFloat = 0.94

func loadArtwork(_ path: String) -> CGImage {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("cannot read artwork: \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    let side = CGFloat(min(cg.width, cg.height)) * cropFraction
    let crop = CGRect(x: (CGFloat(cg.width) - side) / 2, y: (CGFloat(cg.height) - side) / 2,
                      width: side, height: side).integral
    return cg.cropping(to: crop) ?? cg
}

func render(_ art: CGImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let c = ctx.cgContext
    c.interpolationQuality = .high
    c.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)   // draw in 1024 space

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the body (Apple grid: ~28 pt blur, 12 pt down).
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.32))
    c.addPath(shape)
    c.setFillColor(CGColor(srgbRed: 0.04, green: 0.06, blue: 0.09, alpha: 1))
    c.fillPath()
    c.restoreGState()

    // Artwork, clipped to the body.
    c.saveGState()
    c.addPath(shape)
    c.clip()
    c.draw(art, in: body)
    // Hairline highlight so the dark icon doesn't vanish on dark backgrounds.
    c.addPath(shape)
    c.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
    c.setLineWidth(3)
    c.strokePath()
    c.restoreGState()

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write("usage: make-icon.swift <artwork.png> <output.icns>\n".data(using: .utf8)!)
    exit(2)
}
let art = loadArtwork(CommandLine.arguments[1])
let out = CommandLine.arguments[2]
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wirely-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

for base in [16, 32, 128, 256, 512] {
    try render(art, pixels: base).write(to: tmp.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(art, pixels: base * 2).write(to: tmp.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", out]
try p.run(); p.waitUntilExit()
exit(p.terminationStatus)
