import AppKit
import Foundation

// Self-test for the pure logic: classifier, store, image codec. Exits non-zero on any failure.

var failures = 0
var passes = 0

func check(_ ok: Bool, _ name: String) {
    if ok {
        passes += 1
    } else {
        failures += 1
        print("  FAIL  \(name)")
    }
}

func section(_ title: String) {
    print("• \(title)")
}

func textEntry(_ text: String, app: String = "Test") -> Entry {
    Classifier.entry(for: text, sourceApp: app, sourceBundle: "test.bundle")
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-selftest-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: Classifier

section("Classifier")
do {
    func kind(_ s: String) -> Kind { textEntry(s).kind }
    func tags(_ s: String) -> [String] { textEntry(s).tags }

    check(kind("https://example.com/x") == .url, "https URL")
    check(tags("https://Example.com/x").contains("domain:example.com"), "URL domain tag")
    check(kind("github.com/apple/swift") == .url, "bare domain with path is a URL")
    check(kind("www.example.com") == .url, "www domain is a URL")
    check(kind("notes.txt") == .text, "file name is not a URL")
    check(kind("a@b.co") == .email, "email")
    check(kind("#ff8800") == .color, "hex colour")
    check(kind("rgb(10, 20, 30)") == .color, "rgb colour")
    check(kind("/usr/local/bin") == .path, "absolute path")
    check(tags("/tmp/report.PDF").contains("ext:pdf"), "path extension tag")
    check(kind("[1,2,3]") == .json, "JSON array")
    check(kind("{\"a\": 1}") == .json, "JSON object")
    check(kind("{not json}") != .json, "invalid JSON is not JSON")
    check(kind("1,000") == .number, "number with comma")
    check(kind("nan") == .text, "nan is not a number")
    check(kind("func f() {\n  let x = 1\n  return x\n}") == .code, "Swift code")
    check(kind("SELECT * FROM users WHERE id = 1;\nDELETE FROM x;") == .code, "SQL code")
    check(kind("Please return the book.\nThanks {friend}") == .text, "prose with code-like words stays text")
    check(kind("Let me know what you think.\nI will return on Monday.\nSee you then") == .text, "multi-line prose stays text")

    check(!tags("hello\n").contains("multiline"), "trailing newline is not multiline")
    check(tags("a\nb").contains("multiline"), "two lines are multiline")
    check(textEntry("a\nb\n").lines == 2, "line count ignores trailing newline")

    check(tags("sk-abcdefghijklmnopqrstuvwx").contains("sensitive"), "API key is sensitive")
    check(!tags("task-manager-application-v2").contains("sensitive"), "task-… is not an API key")
    check(tags("ghp_abcdefghijklmnopqrstuvwxyz0123456789").contains("sensitive"), "GitHub token is sensitive")
    check(tags("-----BEGIN RSA PRIVATE KEY-----\nabc").contains("sensitive"), "private key is sensitive")
    check(textEntry("sk-abcdefghijklmnopqrstuvwx").title.hasPrefix("Sensitive value"), "sensitive title is masked")
    check(Classifier.isSensitive("token ghp_abcdefghijklmnopqrstuvwxyz0123456789 end"), "isSensitive finds embedded token")

    // Hostile input must stay fast: no catastrophic regex backtracking.
    let hostile = String(repeating: "a@", count: 400_000)
    let started = Date()
    _ = textEntry(hostile)
    check(Date().timeIntervalSince(started) < 2.0, "800 KB of '@' classifies in under 2s")
}

// MARK: Store

section("Store")
do {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try Store(directory: dir)
    let now = Date()

    let a = store.save(textEntry("alpha beta"), now: now.addingTimeInterval(-30))
    let b = store.save(textEntry("gamma delta"), now: now.addingTimeInterval(-20))
    let c = store.save(textEntry("https://example.com/docs"), now: now.addingTimeInterval(-10))
    check(a?.inserted == true && b?.inserted == true && c?.inserted == true, "three inserts")
    check(store.count() == 3, "count is 3")

    let again = store.save(textEntry("alpha beta"), now: now)
    check(again?.inserted == false && again?.id == a?.id, "duplicate content reuses the row")
    let recent = store.fetch(query: "", kind: nil, limit: 10)
    check(recent.first?.title == "alpha beta", "re-copied item moves to the top")
    check(recent.first?.useCount == 2, "use count increments")

    check(store.fetch(query: "gam", kind: nil, limit: 10).map(\.title) == ["gamma delta"], "prefix search")
    check(store.fetch(query: "example", kind: nil, limit: 10).count == 1, "search matches URL text")
    check(store.fetch(query: "domain example", kind: nil, limit: 10).count == 1, "search matches tags")
    check(store.fetch(query: "Test", kind: nil, limit: 10).count == 3, "search matches source app")
    check(store.fetch(query: "alpha beta", kind: nil, limit: 10).count == 1, "multi-word search is AND")
    check(store.fetch(query: "alpha delta", kind: nil, limit: 10).isEmpty, "multi-word search needs every word")
    check(store.fetch(query: "", kind: .url, limit: 10).count == 1, "kind filter")
    for hostile in ["\"", "\"\"", "*", "alpha AND", "NEAR(", "a OR b", "col:x", "-", "^", "(", "'", "\\"] {
        _ = store.fetch(query: hostile, kind: nil, limit: 10) // must not crash or throw
    }
    check(true, "special characters in queries are safe")

    store.togglePin(b!.id)
    check(store.fetch(query: "", kind: nil, limit: 10).first?.title == "gamma delta", "pinned items sort first")

    check(store.fullText(a!.id) == "alpha beta", "fullText")
    check(store.joinedText([c!.id, a!.id], separator: " | ") == "https://example.com/docs | alpha beta", "joinedText keeps order")

    // Delete removes both the row and the search entry.
    store.remove([a!.id])
    check(store.count() == 2, "delete removes row")
    check(store.fetch(query: "alpha", kind: nil, limit: 10).isEmpty, "delete removes search entry")
    check(store.fetch(query: "gam", kind: nil, limit: 10).count == 1, "other entries survive a delete")

    // Retention
    for i in 0..<10 { store.save(textEntry("filler number \(i)"), now: now.addingTimeInterval(Double(i))) }
    store.prune(keep: 4)
    let kept = store.fetch(query: "", kind: nil, limit: 100)
    check(kept.filter { !$0.pinned }.count == 4, "prune keeps the newest 4 unpinned")
    check(kept.contains { $0.pinned && $0.title == "gamma delta" }, "prune never removes pinned items")
    check(store.fetch(query: "filler", kind: nil, limit: 100).count == 4, "pruned items leave the index")

    // Secrets expire; pinned ones do not.
    let secret1 = store.save(textEntry("sk-aaaaaaaaaaaaaaaaaaaaaaaa"), now: now.addingTimeInterval(-7_200))
    let secret2 = store.save(textEntry("sk-bbbbbbbbbbbbbbbbbbbbbbbb"), now: now.addingTimeInterval(-7_200))
    let fresh = store.save(textEntry("sk-cccccccccccccccccccccccc"), now: now)
    store.togglePin(secret2!.id)
    let purged = store.purgeSensitive(olderThan: 3_600, now: now)
    check(purged == 1, "one expired secret purged")
    let remaining = Set(store.fetch(query: "", kind: nil, limit: 100).map(\.id))
    check(!remaining.contains(secret1!.id), "expired secret removed")
    check(remaining.contains(secret2!.id), "pinned secret kept")
    check(remaining.contains(fresh!.id), "fresh secret kept")

    // Images: budget, OCR text, file cleanup
    func imageEntry(_ n: Int, bytes: Int) -> Entry {
        Entry(kind: .image, title: "Image · \(n)", hash: "image-hash-\(n)", text: "Image · \(n)",
              imageData: Data(repeating: UInt8(n), count: bytes), sourceApp: "Test", bytes: bytes, tags: ["image"])
    }
    let images = (1...3).map { store.save(imageEntry($0, bytes: 100), now: now.addingTimeInterval(Double($0))) }
    check(images.allSatisfy { $0?.inserted == true }, "images stored")
    let imageFiles = { (try? FileManager.default.contentsOfDirectory(atPath: store.imagesDir.path))?.count ?? -1 }
    check(imageFiles() == 3, "three image files on disk")

    store.setImageText(images[0]!.id, text: "Image · 1\ninvoice total due friday", addTags: ["ocr"])
    check(store.fetch(query: "invoice", kind: .image, limit: 10).count == 1, "image found by recognised text")
    check(store.fetch(query: "ocr", kind: nil, limit: 10).count == 1, "ocr tag searchable")

    store.pruneImages(maxBytes: 150)
    check(store.fetch(query: "", kind: .image, limit: 10).count == 1, "image budget keeps what fits")
    check(imageFiles() == 1, "pruned image files are deleted from disk")
    check(store.fetch(query: "invoice", kind: nil, limit: 10).isEmpty, "pruned image leaves the index")

    // Backup
    store.backupIfDue(now: now)
    check(Store.backupFiles(in: dir).count == 1, "backup written")
    store.backupIfDue(now: now.addingTimeInterval(60))
    check(Store.backupFiles(in: dir).count == 1, "no second backup within a day")
    store.backupIfDue(now: now.addingTimeInterval(86_400 * 2))
    check(Store.backupFiles(in: dir).count == 2, "new backup after a day")
    store.backupIfDue(now: now.addingTimeInterval(86_400 * 4), keep: 2)
    store.backupIfDue(now: now.addingTimeInterval(86_400 * 6), keep: 2)
    check(Store.backupFiles(in: dir).count == 2, "old backups rotate out")

    // Permissions
    let mode = (try? FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) ?? 0
    check(mode == 0o700, "data directory is owner-only")

    // Persistence across restart
    let before = store.count()
    store.checkpoint()
    store.close()
    let reopened = try Store(directory: dir)
    check(reopened.count() == before, "history survives a restart")
    check(reopened.fetch(query: "gam", kind: nil, limit: 10).count == 1, "search index survives a restart")

    // Restore from backup into a fresh directory
    let restoreDir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: restoreDir) }
    try FileManager.default.createDirectory(at: restoreDir.appendingPathComponent("backups"), withIntermediateDirectories: true)
    if let newest = Store.backupFiles(in: dir).first {
        try FileManager.default.copyItem(at: newest, to: restoreDir.appendingPathComponent("backups/\(newest.lastPathComponent)"))
    }
    check(Store.restoreLatestBackup(in: restoreDir), "latest backup restores")
    let restored = try Store(directory: restoreDir)
    check(restored.count() > 0, "restored database opens and has history")
    check(restored.fetch(query: "gam", kind: nil, limit: 10).count == 1, "restored database is searchable")

    // Damaged database is detected
    let damagedDir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: damagedDir) }
    try Data(repeating: 0x41, count: 8_192).write(to: damagedDir.appendingPathComponent("history.sqlite3"))
    var detected = false
    do { _ = try Store(directory: damagedDir) } catch { detected = true }
    check(detected, "garbage database file is rejected")
    check(Store.quarantineDatabase(in: damagedDir), "damaged database is renamed aside")
    check(!FileManager.default.fileExists(atPath: damagedDir.appendingPathComponent("history.sqlite3").path), "original name is free")
    check(((try? FileManager.default.contentsOfDirectory(atPath: damagedDir.path)) ?? []).contains { $0.contains(".corrupt-") }, "damaged file is kept, not deleted")
}

// MARK: Renamed or moved data folder

section("Data folder migration")
do {
    let root = tempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("ClipboardHistory")
    let current = root.appendingPathComponent("Clipwell")

    // History with an image lives in the old folder.
    var imageId: Int64 = 0
    do {
        let old = try Store(directory: legacy)
        old.save(textEntry("kept across the rename"))
        let entry = Entry(kind: .image, title: "Image · 1", hash: "move-test", text: "Image · 1",
                          imageData: Data(repeating: 7, count: 64), bytes: 64, tags: ["image"])
        imageId = old.save(entry)!.id
        old.checkpoint()
        old.close()
    }

    check(Store.migrateLegacyDirectory(from: legacy, to: current), "legacy folder is moved")
    check(!FileManager.default.fileExists(atPath: legacy.path), "old folder is gone after the move")
    check(!Store.migrateLegacyDirectory(from: legacy, to: current), "migration is a no-op once done")

    let moved = try Store(directory: current)
    check(moved.fetch(query: "rename", kind: nil, limit: 5).count == 1, "history survives the move")
    let image = moved.fetch(query: "", kind: .image, limit: 5).first { $0.id == imageId }
    check(image?.imagePath?.hasPrefix(moved.imagesDir.path + "/") == true, "image path follows the folder")
    check(image?.imagePath.map { FileManager.default.fileExists(atPath: $0) } == true, "image file is found at the new path")

    // An existing new folder is never overwritten.
    let other = root.appendingPathComponent("Other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    check(!Store.migrateLegacyDirectory(from: legacy, to: other), "existing destination is not overwritten")
}

// MARK: Image codec

section("Image codec")
do {
    func bitmap(width: Int, height: Int, transparent: Bool) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var seed: UInt32 = 12345
        let data = rep.bitmapData!
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Int(seed >> 28) // 0...15 of photo-like grain over a smooth gradient
                let i = y * rep.bytesPerRow + x * 4
                data[i] = UInt8(min(255, x * 255 / width + noise))
                data[i + 1] = UInt8(min(255, y * 255 / height + noise))
                data[i + 2] = UInt8(min(255, (x + y) * 255 / (width + height) + noise))
                data[i + 3] = (transparent && x < 4) ? 0 : 255
            }
        }
        return rep.tiffRepresentation!
    }

    let small = ImageCodec.encode(bitmap(width: 64, height: 64, transparent: false))
    check(small?.ext == "png", "small image stays lossless PNG")

    // Some machines (CI virtual machines) have no HEIC encoder; the codec then falls back to PNG.
    let big = ImageCodec.encode(bitmap(width: 1_600, height: 1_200, transparent: false))
    let heicAvailable = big?.ext == "heic"
    if !heicAvailable { print("  skip  HEIC encoder unavailable on this machine") }
    if heicAvailable, let big, let png = NSBitmapImageRep(data: bitmap(width: 1_600, height: 1_200, transparent: false))?.representation(using: .png, properties: [:]) {
        check(big.data.count < png.count / 2, "HEIC is less than half the PNG size (\(big.data.count) vs \(png.count) bytes)")
    }

    let see = ImageCodec.encode(bitmap(width: 1_600, height: 1_200, transparent: true))
    check(see?.ext == "png", "image with transparency stays PNG")
    check(big?.hash == ImageCodec.encode(bitmap(width: 1_600, height: 1_200, transparent: false))?.hash, "hash is stable across encodes")

    if heicAvailable, let big {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-\(UUID().uuidString).heic")
        try big.data.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let png = ImageCodec.pngData(fromFile: path.path)
        check(png.flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide == 1_600, "HEIC converts back to PNG for pasting")
        check(ImageCache.preview(at: path.path, maxPixel: 400)?.size.width ?? 9_999 <= 400, "preview is downscaled")
    }
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
