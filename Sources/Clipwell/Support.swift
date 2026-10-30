import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum Hashing {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum Fmt {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let absolute: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func ago(_ date: Date) -> String {
        relative.localizedString(for: date, relativeTo: Date())
    }

    static func when(_ date: Date) -> String {
        absolute.string(from: date)
    }

    static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    /// "1 line", "2 lines".
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

/// Turns pasteboard image bytes into the smallest faithful file to keep on disk.
enum ImageCodec {
    struct Encoded {
        let data: Data
        let ext: String
        /// Hash of the lossless PNG, so the same picture dedupes whatever format it is stored in.
        let hash: String
        let width: Int
        let height: Int
    }

    /// PNGs up to this size are kept as they are.
    static let keepLosslessBelow = 1_000_000

    /// Lossless PNG for small or transparent images; high-quality HEIC for large opaque ones
    /// (typically several times smaller for photos and retina screenshots).
    static func encode(_ raw: Data) -> Encoded? {
        guard let rep = NSBitmapImageRep(data: raw),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let hash = Hashing.hex(png)
        let lossless = Encoded(data: png, ext: "png", hash: hash, width: rep.pixelsWide, height: rep.pixelsHigh)

        guard png.count > keepLosslessBelow, isOpaque(rep),
              let heic = heicData(from: rep), heic.count < png.count * 3 / 4 else { return lossless }
        return Encoded(data: heic, ext: "heic", hash: hash, width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// PNG bytes for putting an image back on the pasteboard, whatever format it is stored in.
    static func pngData(fromFile path: String) -> Data? {
        if path.hasSuffix(".png") { return FileManager.default.contents(atPath: path) }
        guard let image = NSImage(contentsOfFile: path),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Exact check for any transparent pixel, so alpha is never lost to lossy encoding.
    private static func isOpaque(_ rep: NSBitmapImageRep) -> Bool {
        guard rep.hasAlpha else { return true }
        guard rep.bitsPerSample == 8, rep.samplesPerPixel == 4, !rep.isPlanar, let data = rep.bitmapData else { return false }
        let alphaOffset = rep.bitmapFormat.contains(.alphaFirst) ? 0 : 3
        for y in 0..<rep.pixelsHigh {
            var p = data + y * rep.bytesPerRow + alphaOffset
            for _ in 0..<rep.pixelsWide {
                if p.pointee != 255 { return false }
                p += 4
            }
        }
        return true
    }

    private static func heicData(from rep: NSBitmapImageRep) -> Data? {
        guard let cg = rep.cgImage else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

/// Downscaled previews, decoded straight from disk without loading the full-size bitmap.
enum ImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 32
        return c
    }()

    static func preview(at path: String, maxPixel: Int = 1600) -> NSImage? {
        let key = "\(path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        cache.setObject(image, forKey: key)
        return image
    }
}
