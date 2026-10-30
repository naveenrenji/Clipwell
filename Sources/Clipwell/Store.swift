import Foundation
import SQLite3

enum StoreError: Error {
    case open(String)
    case sql(String)
    case corrupt
}

/// One row of history as the UI sees it. `text` is a short snippet for the list;
/// the preview and paste fetch more on demand (`Store.previewText`, `Store.fullText`).
struct Item: Identifiable, Hashable {
    let id: Int64
    let kind: Kind
    let title: String
    let text: String?
    let imagePath: String?
    let filePaths: [String]
    let sourceApp: String?
    let sourceBundle: String?
    let createdAt: Date
    let lastUsedAt: Date
    let useCount: Int
    let pinned: Bool
    let chars: Int
    let words: Int
    let lines: Int
    let bytes: Int
    let tags: [String]

    var isSensitive: Bool { tags.contains("sensitive") }
}

/// Everything the classifier and monitor know about a new clipboard value.
struct Entry {
    var kind: Kind
    var title: String
    var hash: String
    var text: String? = nil
    var imageData: Data? = nil
    var filePaths: [String] = []
    var sourceApp: String? = nil
    var sourceBundle: String? = nil
    var chars = 0
    var words = 0
    var lines = 0
    var bytes = 0
    var tags: [String] = []
    /// File extension for `imageData` ("png" or "heic").
    var imageExtension = "png"
}

struct SaveResult {
    let id: Int64
    let inserted: Bool
}

/// SQLite store with an FTS5 index. Every instance method must run on `queue`.
final class Store {
    /// List rows carry only this many characters; the preview loads up to `previewLength` on selection.
    static let snippetLength = 400
    static let previewLength = 20_000

    /// Where the app was called "ClipboardHistory" before it was renamed.
    static var legacyDirectory: URL {
        defaultDirectory.deletingLastPathComponent().appendingPathComponent("ClipboardHistory", isDirectory: true)
    }

    /// One-time rename of the old data folder, so existing history survives the app rename.
    /// Never overwrites: it only moves when the new folder does not exist yet.
    @discardableResult
    static func migrateLegacyDirectory(from legacy: URL = legacyDirectory, to new: URL = defaultDirectory) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: new.path) else { return false }
        return (try? fm.moveItem(at: legacy, to: new)) != nil
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipwell", isDirectory: true)
    }

    let queue = DispatchQueue(label: "clipboard.store", qos: .utility)
    let supportDir: URL
    let imagesDir: URL
    let backupsDir: URL

    private let dbPath: String
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let columns = """
        items.id, items.kind, items.title, substr(items.text, 1, \(snippetLength)), items.image_path, \
        items.file_paths, items.source_app, items.source_bundle, items.created_at, items.last_used_at, \
        items.use_count, items.pinned, items.chars, items.words, items.lines, items.bytes, items.tags
        """

    private static let schema = """
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            hash TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            text TEXT,
            image_path TEXT,
            file_paths TEXT,
            source_app TEXT,
            source_bundle TEXT,
            created_at REAL NOT NULL,
            last_used_at REAL NOT NULL,
            use_count INTEGER NOT NULL DEFAULT 1,
            pinned INTEGER NOT NULL DEFAULT 0,
            chars INTEGER NOT NULL DEFAULT 0,
            words INTEGER NOT NULL DEFAULT 0,
            lines INTEGER NOT NULL DEFAULT 0,
            bytes INTEGER NOT NULL DEFAULT 0,
            tags TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS items_recent ON items(pinned DESC, last_used_at DESC);
        CREATE INDEX IF NOT EXISTS items_kind ON items(kind, last_used_at DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
            text, tags, source_app,
            content = 'items', content_rowid = 'id',
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """

    private enum Value {
        case null
        case text(String)
        case int(Int64)
        case double(Double)
    }

    init(directory: URL? = nil) throws {
        let base = directory ?? Self.defaultDirectory
        supportDir = base
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        backupsDir = base.appendingPathComponent("backups", isDirectory: true)
        dbPath = base.appendingPathComponent("history.sqlite3").path

        // Owner-only directories: clipboard history can contain secrets.
        let private700: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true, attributes: private700)
        try? FileManager.default.setAttributes(private700, ofItemAtPath: base.path)

        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StoreError.open(dbPath)
        }
        // auto_vacuum only takes effect on a brand-new file; existing files are converted below.
        try exec("PRAGMA auto_vacuum = INCREMENTAL;")
        // FULL syncs every commit: a power loss or reboot cannot drop recent history.
        try exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA temp_store = MEMORY; PRAGMA cache_size = -8000;")

        guard scalarText("PRAGMA quick_check", []) == "ok" else { throw StoreError.corrupt }

        try exec(Self.schema)
        try migrate()
        repairImagePaths()
        hardenFilePermissions()
    }

    deinit {
        close()
    }

    func close() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        if let db { sqlite3_close(db) }
        db = nil
    }

    /// Image rows store absolute paths. If the data folder was moved or renamed (or a backup was
    /// restored elsewhere), point them at the current images folder, keeping each file name.
    private func repairImagePaths() {
        let prefix = imagesDir.path + "/"
        execute("""
            UPDATE items
            SET image_path = ? || substr(image_path, length(rtrim(image_path, replace(image_path, '/', ''))) + 1)
            WHERE image_path IS NOT NULL AND substr(image_path, 1, length(?)) != ?
            """, [.text(prefix), .text(prefix), .text(prefix)])
    }

    private func migrate() throws {
        // Older builds kept a second copy of every text inside the FTS index. Rebuild it as an
        // external-content table: same search, one copy of the text. The index is derived data.
        if let sql = scalarText("SELECT sql FROM sqlite_master WHERE name = 'items_fts'", []), !sql.contains("content =") {
            run("DROP TABLE items_fts")
            try exec(Self.schema)
            run("INSERT INTO items_fts(items_fts) VALUES('rebuild')")
        }
        // Older files do not reclaim space when rows are deleted; convert once.
        if scalarInt("PRAGMA auto_vacuum") != 2 {
            try exec("PRAGMA auto_vacuum = INCREMENTAL;")
            try exec("VACUUM;")
        }
    }

    // MARK: Writes

    /// Inserts a new item, or bumps an existing identical one to the top.
    @discardableResult
    func save(_ e: Entry, now: Date = Date()) -> SaveResult? {
        if let id = id(forHash: e.hash) {
            execute("UPDATE items SET last_used_at = ?, use_count = use_count + 1 WHERE id = ?", [.double(now.timeIntervalSince1970), .int(id)])
            return SaveResult(id: id, inserted: false)
        }

        var imagePath: String?
        if let data = e.imageData {
            let url = imagesDir.appendingPathComponent(e.hash + "." + e.imageExtension)
            if !FileManager.default.fileExists(atPath: url.path) {
                do { try data.write(to: url, options: .atomic) } catch { return nil }
            }
            imagePath = url.path
        }
        let filePaths = e.filePaths.isEmpty ? nil : e.filePaths.joined(separator: "\n")
        let tagString = Self.tagString(e.tags)

        let ok = execute("""
            INSERT INTO items (hash, kind, title, text, image_path, file_paths, source_app, source_bundle,
                               created_at, last_used_at, chars, words, lines, bytes, tags)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(e.hash), .text(e.kind.rawValue), .text(e.title), optional(e.text),
                optional(imagePath), optional(filePaths), optional(e.sourceApp), optional(e.sourceBundle),
                .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970),
                .int(Int64(e.chars)), .int(Int64(e.words)), .int(Int64(e.lines)), .int(Int64(e.bytes)),
                .text(tagString),
            ])
        guard ok, let id = id(forHash: e.hash) else { return nil }

        // External-content index: the values must match the row exactly, or later deletes break.
        execute("INSERT INTO items_fts (rowid, text, tags, source_app) VALUES (?, ?, ?, ?)", [
            .int(id), optional(e.text), .text(tagString), optional(e.sourceApp),
        ])
        return SaveResult(id: id, inserted: true)
    }

    /// Replaces an image's searchable text (its title plus recognised text) and adds tags.
    func setImageText(_ id: Int64, text: String, addTags: [String]) {
        guard let s = statement("SELECT text, tags, source_app FROM items WHERE id = ? AND kind = 'image'", [.int(id)]),
              sqlite3_step(s) == SQLITE_ROW else { return }
        let oldText = colText(s, 0)
        let oldTags = colText(s, 1) ?? ""
        let app = colText(s, 2)
        sqlite3_reset(s)

        var tags = Set(oldTags.split(separator: " ").map(String.init))
        addTags.forEach { tags.insert($0) }
        let newTags = Self.tagString(Array(tags))

        run("BEGIN")
        execute("INSERT INTO items_fts (items_fts, rowid, text, tags, source_app) VALUES ('delete', ?, ?, ?, ?)", [
            .int(id), optional(oldText), .text(oldTags), optional(app),
        ])
        execute("UPDATE items SET text = ?, tags = ? WHERE id = ?", [.text(text), .text(newTags), .int(id)])
        execute("INSERT INTO items_fts (rowid, text, tags, source_app) VALUES (?, ?, ?, ?)", [
            .int(id), .text(text), .text(newTags), optional(app),
        ])
        run("COMMIT")
    }

    func touch(_ id: Int64, now: Date = Date()) {
        execute("UPDATE items SET last_used_at = ?, use_count = use_count + 1 WHERE id = ?", [.double(now.timeIntervalSince1970), .int(id)])
    }

    func togglePin(_ id: Int64) {
        execute("UPDATE items SET pinned = 1 - pinned WHERE id = ?", [.int(id)])
    }

    func remove(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        run("BEGIN")
        for id in ids {
            guard let s = statement("SELECT text, tags, source_app, image_path FROM items WHERE id = ?", [.int(id)]),
                  sqlite3_step(s) == SQLITE_ROW else { continue }
            let text = colText(s, 0)
            let tags = colText(s, 1) ?? ""
            let app = colText(s, 2)
            let path = colText(s, 3)
            sqlite3_reset(s)

            // Remove the index entry using the exact indexed values, then the row itself.
            execute("INSERT INTO items_fts (items_fts, rowid, text, tags, source_app) VALUES ('delete', ?, ?, ?, ?)", [
                .int(id), optional(text), .text(tags), optional(app),
            ])
            execute("DELETE FROM items WHERE id = ?", [.int(id)])
            // Only ever delete files we wrote ourselves.
            if let path, path.hasPrefix(imagesDir.path + "/") { try? FileManager.default.removeItem(atPath: path) }
        }
        run("COMMIT")
        run("PRAGMA incremental_vacuum")
    }

    /// Keeps the newest `keep` unpinned items; pinned items never expire.
    func prune(keep: Int) {
        remove(ids("SELECT id FROM items WHERE pinned = 0 ORDER BY last_used_at DESC LIMIT -1 OFFSET ?", [.int(Int64(keep))]))
    }

    /// Drops the oldest unpinned images until all stored images fit in `maxBytes`.
    func pruneImages(maxBytes: Int) {
        guard let total = scalarInt("SELECT COALESCE(SUM(bytes), 0) FROM items WHERE kind = 'image'"), total > maxBytes,
              let s = statement("SELECT id, bytes FROM items WHERE kind = 'image' AND pinned = 0 ORDER BY last_used_at ASC", [])
        else { return }
        var excess = total - maxBytes
        var victims: [Int64] = []
        while excess > 0, sqlite3_step(s) == SQLITE_ROW {
            victims.append(sqlite3_column_int64(s, 0))
            excess -= Int(sqlite3_column_int64(s, 1))
        }
        sqlite3_reset(s)
        remove(victims)
    }

    /// Removes unpinned values tagged `sensitive` that were last used more than `seconds` ago.
    @discardableResult
    func purgeSensitive(olderThan seconds: TimeInterval, now: Date = Date()) -> Int {
        let cutoff = now.timeIntervalSince1970 - seconds
        let expired = ids("SELECT id FROM items WHERE pinned = 0 AND tags LIKE '% sensitive %' AND last_used_at < ?", [.double(cutoff)])
        remove(expired)
        return expired.count
    }

    func clearUnpinned() {
        remove(ids("SELECT id FROM items WHERE pinned = 0", []))
    }

    // MARK: Reads

    func fetch(query: String, kind: Kind?, limit: Int) -> [Item] {
        var sql: String
        var values: [Value] = []
        let match = Self.ftsQuery(query)
        if let match {
            sql = "SELECT \(Self.columns) FROM items JOIN items_fts ON items_fts.rowid = items.id WHERE items_fts MATCH ?"
            values.append(.text(match))
        } else {
            sql = "SELECT \(Self.columns) FROM items WHERE 1 = 1"
        }
        if let kind {
            sql += " AND items.kind = ?"
            values.append(.text(kind.rawValue))
        }
        sql += match == nil
            ? " ORDER BY items.pinned DESC, items.last_used_at DESC"
            : " ORDER BY items.pinned DESC, bm25(items_fts), items.last_used_at DESC"
        sql += " LIMIT ?"
        values.append(.int(Int64(limit)))

        guard let s = statement(sql, values) else { return [] }
        var rows: [Item] = []
        while sqlite3_step(s) == SQLITE_ROW {
            rows.append(readItem(s))
        }
        sqlite3_reset(s)
        return rows
    }

    func fullText(_ id: Int64) -> String? {
        scalarText("SELECT text FROM items WHERE id = ?", [.int(id)])
    }

    /// The first 20k characters, for the preview pane. Keeps the list query light.
    func previewText(_ id: Int64) -> String? {
        scalarText("SELECT substr(text, 1, \(Self.previewLength)) FROM items WHERE id = ?", [.int(id)])
    }

    /// Full text of the given items in order, joined for a multi-item paste. Images are skipped.
    func joinedText(_ ids: [Int64], separator: String) -> String {
        ids.compactMap { id -> String? in
            guard scalarText("SELECT kind FROM items WHERE id = ?", [.int(id)]) != Kind.image.rawValue else { return nil }
            return fullText(id)
        }.joined(separator: separator)
    }

    func count() -> Int {
        scalarInt("SELECT count(*) FROM items") ?? 0
    }

    /// Turns "git hub" into `"git"* "hub"*`: every word must match as a prefix.
    static func ftsQuery(_ raw: String) -> String? {
        let terms = raw.split(whereSeparator: \.isWhitespace).map { term -> String in
            "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
        }
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }

    // MARK: Durability

    /// Folds the write-ahead log into the main file. Call before the app quits.
    func checkpoint() {
        run("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Writes a consistent copy of the database to `backups/`, at most once per `minInterval`,
    /// and keeps only the newest `keep` copies.
    func backupIfDue(now: Date = Date(), keep: Int = 3, minInterval: TimeInterval = 86_400) {
        try? FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let existing = Self.backupFiles(in: supportDir)
        if let newest = existing.first,
           let modified = (try? newest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           now.timeIntervalSince(modified) < minInterval { return }

        let destination = backupsDir.appendingPathComponent("history-\(Self.stamp(now)).sqlite3")
        guard execute("VACUUM INTO ?", [.text(destination.path)]) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        for old in existing.dropFirst(max(keep - 1, 0)) { try? FileManager.default.removeItem(at: old) }
    }

    /// Tightens permissions on files written by older builds. Newer files are created owner-only.
    func hardenFilePermissions() {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imagesDir.path)
        for suffix in ["", "-wal", "-shm"] {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbPath + suffix)
        }
        let files = (try? fm.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    }

    /// Newest first.
    static func backupFiles(in directory: URL) -> [URL] {
        let dir = directory.appendingPathComponent("backups", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("history-") && $0.pathExtension == "sqlite3" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Renames a damaged database aside (never deletes it) so a fresh one can be created.
    @discardableResult
    static func quarantineDatabase(in directory: URL = defaultDirectory) -> Bool {
        let stamp = stamp(Date())
        var moved = false
        for suffix in ["", "-wal", "-shm"] {
            let source = directory.appendingPathComponent("history.sqlite3" + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let target = directory.appendingPathComponent("history.sqlite3\(suffix).corrupt-\(stamp)")
            if (try? FileManager.default.moveItem(at: source, to: target)) != nil { moved = true }
        }
        return moved
    }

    @discardableResult
    static func restoreLatestBackup(in directory: URL = defaultDirectory) -> Bool {
        guard let newest = backupFiles(in: directory).first else { return false }
        let target = directory.appendingPathComponent("history.sqlite3")
        return (try? FileManager.default.copyItem(at: newest, to: target)) != nil
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    // MARK: Helpers

    private static func tagString(_ tags: [String]) -> String {
        tags.isEmpty ? "" : " " + tags.sorted().joined(separator: " ") + " "
    }

    private func readItem(_ s: OpaquePointer) -> Item {
        Item(
            id: sqlite3_column_int64(s, 0),
            kind: Kind(rawValue: colText(s, 1) ?? "") ?? .text,
            title: colText(s, 2) ?? "",
            text: colText(s, 3),
            imagePath: colText(s, 4),
            filePaths: (colText(s, 5) ?? "").split(separator: "\n").map(String.init),
            sourceApp: colText(s, 6),
            sourceBundle: colText(s, 7),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 8)),
            lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 9)),
            useCount: Int(sqlite3_column_int64(s, 10)),
            pinned: sqlite3_column_int64(s, 11) == 1,
            chars: Int(sqlite3_column_int64(s, 12)),
            words: Int(sqlite3_column_int64(s, 13)),
            lines: Int(sqlite3_column_int64(s, 14)),
            bytes: Int(sqlite3_column_int64(s, 15)),
            tags: (colText(s, 16) ?? "").split(separator: " ").map(String.init)
        )
    }

    private func optional(_ s: String?) -> Value {
        s.map { .text($0) } ?? .null
    }

    private func id(forHash hash: String) -> Int64? {
        guard let s = statement("SELECT id FROM items WHERE hash = ?", [.text(hash)]) else { return nil }
        defer { sqlite3_reset(s) }
        return sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_int64(s, 0) : nil
    }

    private func ids(_ sql: String, _ values: [Value]) -> [Int64] {
        guard let s = statement(sql, values) else { return [] }
        defer { sqlite3_reset(s) }
        var out: [Int64] = []
        while sqlite3_step(s) == SQLITE_ROW { out.append(sqlite3_column_int64(s, 0)) }
        return out
    }

    private func scalarText(_ sql: String, _ values: [Value]) -> String? {
        guard let s = statement(sql, values) else { return nil }
        defer { sqlite3_reset(s) }
        return sqlite3_step(s) == SQLITE_ROW ? colText(s, 0) : nil
    }

    private func scalarInt(_ sql: String) -> Int? {
        guard let s = statement(sql, []) else { return nil }
        defer { sqlite3_reset(s) }
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int64(s, 0)) : nil
    }

    private func colText(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard sqlite3_column_type(s, i) != SQLITE_NULL, let p = sqlite3_column_text(s, i) else { return nil }
        return String(cString: UnsafeRawPointer(p).assumingMemoryBound(to: CChar.self))
    }

    @discardableResult
    private func execute(_ sql: String, _ values: [Value] = []) -> Bool {
        guard let s = statement(sql, values) else { return false }
        let rc = sqlite3_step(s)
        sqlite3_reset(s)
        return rc == SQLITE_DONE || rc == SQLITE_ROW
    }

    /// Prepared statements are cached per SQL text; every call rebinds from scratch.
    private func statement(_ sql: String, _ values: [Value]) -> OpaquePointer? {
        var s = statements[sql]
        if s == nil {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK else {
                NSLog("Clipwell SQL prepare failed: %s", sqlite3_errmsg(db))
                return nil
            }
            s = prepared
            statements[sql] = prepared
        }
        guard let stmt = s else { return nil }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .null: sqlite3_bind_null(stmt, index)
            case .text(let t): sqlite3_bind_text(stmt, index, t, -1, transient)
            case .int(let n): sqlite3_bind_int64(stmt, index, n)
            case .double(let d): sqlite3_bind_double(stmt, index, d)
            }
        }
        return stmt
    }

    private func run(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql(message)
        }
    }
}
