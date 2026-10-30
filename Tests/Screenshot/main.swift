import AppKit
import SwiftUI

// Renders the history window with made-up data for the README. Never reads real history.
// Usage: Scripts/screenshot.sh <output.png> [search text]

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "screenshot.png"
let query = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipwell-shot-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: dir) }
let store = try Store(directory: dir)

let now = Date()
func add(_ text: String, app: String, minutesAgo: Double, pinned: Bool = false, copies: Int = 1) {
    let entry = Classifier.entry(for: text, sourceApp: app, sourceBundle: nil)
    let id = store.save(entry, now: now.addingTimeInterval(-minutesAgo * 60))!.id
    for _ in 1..<max(copies, 1) { store.touch(id, now: now.addingTimeInterval(-minutesAgo * 60)) }
    if pinned { store.togglePin(id) }
}

add("Quarterly invoice #4821 is due Friday. Please confirm the amount with finance before sending it to the client.", app: "Notes", minutesAgo: 2)
add("https://github.com/naveenrenji/Clipwell", app: "Safari", minutesAgo: 6, copies: 3)
add("func fetchInvoice(id: Int) async throws -> Invoice {\n    let url = baseURL.appending(path: \"invoices/\\(id)\")\n    return try await client.get(url)\n}", app: "Xcode", minutesAgo: 11)
add("sk-demo1234567890abcdefghijklmnop", app: "Terminal", minutesAgo: 14)
add("maria.lopez@example.com", app: "Mail", minutesAgo: 23)
add("{\"status\": \"ok\", \"items\": 42, \"next\": null}", app: "Postman", minutesAgo: 35)
add("#4F46E5", app: "Figma", minutesAgo: 48)
add("/Users/demo/Projects/website/index.html", app: "Finder", minutesAgo: 70)
add("Standup notes: ship the invoice export, review the OCR search PR, update the changelog.", app: "Slack", minutesAgo: 95, pinned: true)
add("1,284.50", app: "Numbers", minutesAgo: 130)

// A screenshot-like image found through its recognised text.
let entry = Entry(kind: .image, title: "Image · 2400×1500", hash: "demo-image", text: "Image · 2400×1500",
                  imageData: Data(repeating: 1, count: 16), sourceApp: "Screenshot", bytes: 16, tags: ["image"])
let imageId = store.save(entry, now: now.addingTimeInterval(-3 * 60))!.id
store.setImageText(imageId, text: "Image · 2400×1500\nQuarterly invoice total due Friday", addTags: ["ocr"])

let model = HistoryModel(store: store)
model.query = query
model.reload()
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
model.selected = query.isEmpty ? 1 : 0
RunLoop.main.run(until: Date().addingTimeInterval(0.4))

let size = NSSize(width: 860, height: 520)
let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
window.appearance = NSAppearance(named: .darkAqua)
window.backgroundColor = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.16, alpha: 1)
let host = NSHostingView(rootView: HistoryView(model: model).frame(width: size.width, height: size.height))
window.contentView = host
window.setContentSize(size)
window.displayIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.8))
host.layoutSubtreeIfNeeded()

let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
host.cacheDisplay(in: host.bounds, to: rep)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
