import Foundation

// Synthetic benchmark on a throwaway database. Never touches your real history.

let count = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 10_000 : 10_000

var seed: UInt64 = 0x2545_F491_4F6C_DD1D
func random(_ upper: Int) -> Int {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((seed >> 33) % UInt64(upper))
}

let words = ["invoice", "meeting", "swift", "database", "customer", "release", "budget", "design", "deploy", "student",
             "report", "schedule", "payment", "account", "project", "review", "feature", "error", "server", "client",
             "quarter", "analysis", "dashboard", "network", "security", "backup", "search", "index", "storage", "token"]

func sentence(wordCount: Int) -> String {
    (0..<wordCount).map { _ in words[random(words.count)] + (random(7) == 0 ? String(random(1_000)) : "") }.joined(separator: " ")
}

func sample(_ i: Int) -> String {
    switch random(100) {
    case 0..<8: return "https://\(words[random(words.count)]).example.com/\(words[random(words.count)])/\(i)"
    case 8..<14: return "func \(words[random(words.count)])\(i)() {\n    let value = \(i)\n    return value\n}"
    case 14..<95: return sentence(wordCount: 3 + random(40)) + " #\(i)"
    default: return (0..<(2_000 + random(8_000))).map { _ in words[random(words.count)] }.joined(separator: " ") + " #\(i)" // ~50 KB
    }
}

func millis(_ block: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    block()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-bench-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let store = try Store(directory: dir)

print("Benchmark: \(count) synthetic items\n")

// Ingest = classify + hash + insert + index, one commit per item, exactly like a real copy.
var ingestTimes: [Double] = []
var rawBytes = 0
let total = millis {
    for i in 0..<count {
        let text = sample(i)
        rawBytes += text.utf8.count
        ingestTimes.append(millis {
            store.save(Classifier.entry(for: text, sourceApp: "Bench", sourceBundle: "bench"), now: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
        })
    }
}
print(String(format: "ingest      %6.0f items/s   p50 %.2f ms   p95 %.2f ms   max %.2f ms", Double(count) / (total / 1_000),
             percentile(ingestTimes, 0.5), percentile(ingestTimes, 0.95), ingestTimes.max() ?? 0))

func measure(_ label: String, runs: Int, _ block: (Int) -> Void) {
    var times: [Double] = []
    for run in 0..<runs { times.append(millis { block(run) }) }
    print(String(format: "%-11@ p50 %6.2f ms   p95 %6.2f ms   max %6.2f ms", label as NSString, percentile(times, 0.5), percentile(times, 0.95), times.max() ?? 0))
}

measure("recent", runs: 100) { _ in _ = store.fetch(query: "", kind: nil, limit: 400) }
measure("search 1w", runs: 200) { i in _ = store.fetch(query: String(words[i % words.count].prefix(4)), kind: nil, limit: 400) }
measure("search 2w", runs: 200) { i in _ = store.fetch(query: "\(words[i % words.count]) \(words[(i + 7) % words.count])", kind: nil, limit: 400) }
measure("search rare", runs: 200) { i in _ = store.fetch(query: "\(i * 37 % count + 100_000)", kind: nil, limit: 400) }
measure("by kind", runs: 100) { _ in _ = store.fetch(query: "", kind: .url, limit: 400) }
measure("kind+search", runs: 100) { i in _ = store.fetch(query: words[i % words.count], kind: .code, limit: 400) }
measure("count", runs: 100) { _ in _ = store.count() }
measure("preview", runs: 100) { i in _ = store.previewText(Int64(1 + (i * 97) % count)) }

var pruneMs = millis { store.prune(keep: count / 2) }
print(String(format: "prune       removed %d items in %.0f ms", count - store.count(), pruneMs))
store.checkpoint()

func size(_ name: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.size] as? Int) ?? 0
}
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
print(String(format: "\ntext copied %.1f MB   database %.1f MB (after pruning half)   peak memory %.0f MB",
             Double(rawBytes) / 1_048_576, Double(size("history.sqlite3")) / 1_048_576, Double(usage.ru_maxrss) / 1_048_576))
