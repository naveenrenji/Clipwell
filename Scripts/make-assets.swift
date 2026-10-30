// Generates Clipwell's brand assets from code, so they stay reproducible and easy to change:
//   Resources/AppIcon.icns, docs/banner.png (README header), docs/social-preview.png (1280x640)
// Run from the repository root:  swift Scripts/make-assets.swift
import AppKit

let indigo = NSColor(srgbRed: 0.31, green: 0.27, blue: 0.90, alpha: 1)
let cyan = NSColor(srgbRed: 0.02, green: 0.71, blue: 0.83, alpha: 1)

func png(width: Int, height: Int, _ draw: (NSRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage {
    let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))!
    let out = NSImage(size: base.size)
    out.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: base.size))
    color.set()
    NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func centered(_ image: NSImage, at center: NSPoint) {
    image.draw(in: NSRect(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2,
                          width: image.size.width, height: image.size.height))
}

/// The app icon artwork inside `rect` (a square). Follows the macOS margin: the body fills 80%.
func drawIcon(in rect: NSRect, withShadow: Bool) {
    let body = rect.insetBy(dx: rect.width * 0.098, dy: rect.height * 0.098)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    if withShadow {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = rect.width * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.014)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGradient(starting: indigo, ending: cyan)!.draw(in: path, angle: -45)

    // Soft top highlight
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let glyph = symbol("doc.on.clipboard.fill", pointSize: rect.width * 0.42, color: .white)
    centered(glyph, at: NSPoint(x: body.midX - body.width * 0.02, y: body.midY + body.height * 0.02))

    // Magnifier badge: "search everything you copied"
    let badgeCenter = NSPoint(x: body.midX + body.width * 0.20, y: body.midY - body.height * 0.22)
    let radius = body.width * 0.15
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - radius, y: badgeCenter.y - radius, width: radius * 2, height: radius * 2)).fill()
    centered(symbol("magnifyingglass", pointSize: radius * 1.25, color: indigo), at: badgeCenter)
}

func writeIcon(to url: URL) throws {
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Clipwell-\(UUID().uuidString).iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }

    let sizes: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, pixels) in sizes {
        let data = png(width: pixels, height: pixels) { drawIcon(in: $0, withShadow: true) }
        try data.write(to: iconset.appendingPathComponent("\(name).png"))
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", url.path]
    try process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "iconutil failed")
}

func drawBanner(in rect: NSRect) {
    NSGradient(starting: NSColor(srgbRed: 0.04, green: 0.06, blue: 0.14, alpha: 1),
               ending: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.34, alpha: 1))!.draw(in: rect, angle: -20)

    let unit = rect.height / 500
    let iconSide = 330 * unit
    drawIcon(in: NSRect(x: 80 * unit, y: (rect.height - iconSide) / 2 + 10 * unit, width: iconSide, height: iconSide), withShadow: true)

    let textX = 80 * unit + iconSide + 50 * unit
    let rounded = NSFont.systemFont(ofSize: 130 * unit, weight: .bold).fontDescriptor.withDesign(.rounded)
        .flatMap { NSFont(descriptor: $0, size: 130 * unit) } ?? NSFont.boldSystemFont(ofSize: 130 * unit)
    ("Clipwell" as NSString).draw(at: NSPoint(x: textX, y: rect.height * 0.52),
                                  withAttributes: [.font: rounded, .foregroundColor: NSColor.white])

    let tagline = "Remember everything you copy.\nFind it in milliseconds. Tell nobody."
    (tagline as NSString).draw(in: NSRect(x: textX, y: rect.height * 0.27, width: rect.width - textX - 60 * unit, height: 120 * unit),
                               withAttributes: [.font: NSFont.systemFont(ofSize: 36 * unit, weight: .medium),
                                                .foregroundColor: NSColor.white.withAlphaComponent(0.85)])

    var x = textX
    for label in ["⌃⌥V anywhere", "Search inside screenshots", "100% local", "Open source"] {
        let font = NSFont.systemFont(ofSize: 24 * unit, weight: .semibold)
        let size = (label as NSString).size(withAttributes: [.font: font])
        let pill = NSRect(x: x, y: rect.height * 0.12, width: size.width + 36 * unit, height: 50 * unit)
        NSColor.white.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 25 * unit, yRadius: 25 * unit).fill()
        (label as NSString).draw(at: NSPoint(x: pill.minX + 18 * unit, y: pill.minY + (pill.height - size.height) / 2),
                                 withAttributes: [.font: font, .foregroundColor: NSColor.white])
        x = pill.maxX + 14 * unit
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
try FileManager.default.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)

try writeIcon(to: root.appendingPathComponent("Resources/AppIcon.icns"))
try png(width: 1600, height: 500, drawBanner).write(to: root.appendingPathComponent("docs/banner.png"))
try png(width: 1280, height: 640) { rect in
    // Social preview uses the same layout, vertically centred in the taller canvas.
    let band = NSRect(x: 0, y: (rect.height - 400) / 2, width: rect.width, height: 400)
    NSGradient(starting: NSColor(srgbRed: 0.04, green: 0.06, blue: 0.14, alpha: 1),
               ending: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.34, alpha: 1))!.draw(in: rect, angle: -20)
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: 0, yBy: band.minY)
    transform.concat()
    drawBanner(in: NSRect(x: 0, y: 0, width: rect.width, height: 400))
    NSGraphicsContext.restoreGraphicsState()
}.write(to: root.appendingPathComponent("docs/social-preview.png"))
print("Wrote Resources/AppIcon.icns, docs/banner.png, docs/social-preview.png")
