import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: Store!
    private let monitor = ClipboardMonitor()
    private var panel: HistoryWindowController!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var maintenance: DispatchSourceTimer?
    /// Items behind the "Copy Again" submenu, keyed by id, refreshed whenever the menu opens.
    private var recentItems: [Int64: Item] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        Store.migrateLegacyDirectory()
        Settings.migrateLegacySettings()
        Settings.registerDefaults()
        guard let opened = openStore() else {
            NSApp.terminate(nil)
            return
        }
        store = opened

        panel = HistoryWindowController(store: store)
        panel.onWrite = { [weak self] item, plain in self?.writePasteboard(item, plain: plain) }
        panel.onWriteMany = { [weak self] ids, joiner in self?.writePasteboardMany(ids, joiner: joiner) }
        panel.onCopied = { [weak self] in self?.flashCopied() }

        monitor.onCapture = { [weak self] capture in self?.ingest(capture) }
        monitor.start()

        // Control + Option + V opens the history from anywhere.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.panel.toggle()
        }

        if !Paster.isTrusted { Paster.requestTrust() }
        setupStatusItem()
        startMaintenance()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Fold the write-ahead log into the main file so the database is complete on disk.
        store?.queue.sync { store.checkpoint() }
    }

    // MARK: Startup and upkeep

    /// Opens the database. A damaged file is renamed aside (never deleted) and the newest
    /// daily backup, if any, takes its place.
    private func openStore() -> Store? {
        do {
            return try Store()
        } catch StoreError.corrupt {
            Store.quarantineDatabase()
            let restored = Store.restoreLatestBackup()
            let alert = NSAlert()
            alert.messageText = "Clipwell found a damaged database"
            alert.informativeText = "The damaged files were renamed next to the original (nothing was deleted). "
                + (restored ? "The most recent daily backup was restored." : "A new, empty history was started.")
            alert.runModal()
            return try? Store()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Clipwell could not open its database"
            alert.informativeText = "\(error)"
            alert.runModal()
            return nil
        }
    }

    /// Every five minutes, off the main thread: expire secrets, enforce size limits, take the daily backup.
    private func startMaintenance() {
        let store = self.store!
        store.queue.async { store.hardenFilePermissions() }

        let timer = DispatchSource.makeTimerSource(queue: store.queue)
        timer.schedule(deadline: .now() + 5, repeating: 300, leeway: .seconds(30))
        timer.setEventHandler {
            let ttl = Settings.sensitiveTTLMinutes
            if ttl > 0 { store.purgeSensitive(olderThan: TimeInterval(ttl * 60)) }
            store.pruneImages(maxBytes: Settings.maxImageMB * 1_048_576)
            store.prune(keep: Settings.historyLimit)
            store.backupIfDue()
        }
        timer.resume()
        maintenance = timer
    }

    // MARK: Capture

    /// Classification, hashing and image encoding all run on the store queue, never the main thread.
    private func ingest(_ capture: Capture) {
        let store = self.store!
        store.queue.async {
            guard let entry = Self.makeEntry(capture), let result = store.save(entry) else { return }
            store.prune(keep: Settings.historyLimit)
            if result.inserted, entry.kind == .image {
                Self.recognizeText(in: entry, id: result.id, store: store)
            }
        }
    }

    private static func makeEntry(_ capture: Capture) -> Entry? {
        switch capture.payload {
        case .text(let text):
            return Classifier.entry(for: text, sourceApp: capture.sourceApp, sourceBundle: capture.sourceBundle)

        case .image(let raw):
            guard let encoded = ImageCodec.encode(raw) else { return nil }
            let title = "Image · \(encoded.width)×\(encoded.height)"
            return Entry(
                kind: .image,
                title: title,
                hash: encoded.hash,
                text: title,
                imageData: encoded.data,
                sourceApp: capture.sourceApp,
                sourceBundle: capture.sourceBundle,
                bytes: encoded.data.count,
                tags: ["image"],
                imageExtension: encoded.ext
            )

        case .files(let paths):
            let joined = paths.joined(separator: "\n")
            let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
            return Entry(
                kind: .files,
                title: String(names.prefix(180)),
                hash: Hashing.hex(Data(joined.utf8)),
                text: joined,
                filePaths: paths,
                sourceApp: capture.sourceApp,
                sourceBundle: capture.sourceBundle,
                chars: joined.count,
                bytes: joined.utf8.count,
                tags: ["files"]
            )
        }
    }

    /// Makes screenshots searchable by their text, and flags ones that show a secret.
    private static func recognizeText(in entry: Entry, id: Int64, store: Store) {
        let path = store.imagesDir.appendingPathComponent(entry.hash + "." + entry.imageExtension).path
        OCR.recognize(imageAt: path) { text in
            guard let text else { return }
            var tags = ["ocr"]
            if Classifier.isSensitive(text) { tags.append("sensitive") }
            store.queue.async {
                store.setImageText(id, text: entry.title + "\n" + text, addTags: tags)
            }
        }
    }

    // MARK: Paste

    private func writePasteboard(_ item: Item, plain: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .image where !plain:
            if let path = item.imagePath, let png = ImageCodec.pngData(fromFile: path) {
                pb.setData(png, forType: .png)
            }
        case .files where !plain:
            pb.writeObjects(item.filePaths.map { URL(fileURLWithPath: $0) as NSURL })
        default:
            let store = self.store!
            let full = store.queue.sync { store.fullText(item.id) }
            pb.setString(full ?? item.text ?? item.title, forType: .string)
        }
        monitor.ignoreCurrentChange()

        let store = self.store!
        store.queue.async { store.touch(item.id) }
    }

    private func writePasteboardMany(_ ids: [Int64], joiner: String) {
        let store = self.store!
        let text = store.queue.sync { store.joinedText(ids, separator: joiner) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        monitor.ignoreCurrentChange()
        store.queue.async { ids.forEach { store.touch($0) } }
    }

    // MARK: Menu bar

    private static let menuBarSymbol = "doc.on.clipboard"
    private static let recentMenuCount = 10

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: Self.menuBarSymbol, accessibilityDescription: "Clipwell")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Briefly swaps the menu-bar icon for a check mark after an item was copied.
    private func flashCopied() {
        statusItem.button?.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.statusItem.button?.image = NSImage(systemSymbolName: Self.menuBarSymbol, accessibilityDescription: "Clipwell")
        }
    }

    /// The menu is rebuilt each time it opens so it always shows current settings and the last app.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(menuItem("Show History  ⌃⌥V", #selector(showHistory)))
        menu.addItem(recentMenu())
        menu.addItem(.separator())

        menu.addItem(menuItem(monitor.isPaused ? "Resume Capturing" : "Pause Capturing", #selector(togglePause)))

        if let app = panel.lastExternalApp, let bundle = app.bundleIdentifier,
           !Settings.excludedBundles.contains(bundle) {
            let item = menuItem("Stop Recording Copies From \(app.localizedName ?? bundle)", #selector(excludeApp(_:)))
            item.representedObject = bundle
            menu.addItem(item)
        }
        let excluded = Settings.excludedBundles
        if !excluded.isEmpty {
            let sub = NSMenu()
            for bundle in excluded {
                let item = menuItem(Self.appName(for: bundle), #selector(includeApp(_:)))
                item.representedObject = bundle
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: "Excluded Apps (click to record again)", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        menu.addItem(.separator())

        menu.addItem(choiceMenu("History Size", Settings.historyLimitChoices, current: Settings.historyLimit,
                                label: { "\($0) items" }, action: #selector(setHistoryLimit(_:))))
        menu.addItem(choiceMenu("Delete Secrets After", Settings.sensitiveTTLChoices, current: Settings.sensitiveTTLMinutes,
                                label: Self.ttlLabel, action: #selector(setSensitiveTTL(_:))))
        menu.addItem(choiceMenu("Image Storage Limit", Settings.imageLimitChoices, current: Settings.maxImageMB,
                                label: { $0 >= 1_000 ? "\($0 / 1_000) GB" : "\($0) MB" }, action: #selector(setImageLimit(_:))))
        menu.addItem(.separator())

        menu.addItem(menuItem("Clear Unpinned History…", #selector(clearHistory)))
        menu.addItem(menuItem("Open Data Folder", #selector(openDataFolder)))
        let login = menuItem("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Clipwell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// The latest copies, one click each to put them back on the clipboard.
    private func recentMenu() -> NSMenuItem {
        let store = self.store!
        let recent = store.queue.sync { store.fetch(query: "", kind: nil, limit: Self.recentMenuCount) }
        recentItems = Dictionary(uniqueKeysWithValues: recent.map { ($0.id, $0) })

        let sub = NSMenu()
        for item in recent {
            let title = item.title.count > 60 ? String(item.title.prefix(60)) + "…" : item.title
            let entry = menuItem(title.isEmpty ? "(empty)" : title, #selector(copyRecent(_:)))
            entry.image = NSImage(systemSymbolName: item.isSensitive ? "lock.fill" : item.kind.symbol, accessibilityDescription: item.kind.label)
            entry.representedObject = item.id
            sub.addItem(entry)
        }
        if recent.isEmpty { sub.addItem(NSMenuItem(title: "Nothing copied yet", action: nil, keyEquivalent: "")) }

        let parent = NSMenuItem(title: "Copy Again", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func choiceMenu(_ title: String, _ choices: [Int], current: Int, label: (Int) -> String, action: Selector) -> NSMenuItem {
        let sub = NSMenu()
        for choice in choices {
            let item = menuItem(label(choice), action)
            item.representedObject = choice
            item.state = choice == current ? .on : .off
            sub.addItem(item)
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    private static func ttlLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Never"
        case 60: "1 hour"
        case 1_440: "24 hours"
        default: "\(minutes) minutes"
        }
    }

    private static func appName(for bundle: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return bundle }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    @objc private func showHistory() {
        panel.show()
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64, let item = recentItems[id] else { return }
        writePasteboard(item, plain: false)
        flashCopied()
    }

    @objc private func togglePause() {
        monitor.isPaused.toggle()
    }

    @objc private func excludeApp(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        Settings.excludedBundles = Settings.excludedBundles + [bundle]
    }

    @objc private func includeApp(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        Settings.excludedBundles = Settings.excludedBundles.filter { $0 != bundle }
    }

    @objc private func setHistoryLimit(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        Settings.historyLimit = value
        let store = self.store!
        store.queue.async { store.prune(keep: value) }
    }

    @objc private func setSensitiveTTL(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        Settings.sensitiveTTLMinutes = value
    }

    @objc private func setImageLimit(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        Settings.maxImageMB = value
        let store = self.store!
        store.queue.async { store.pruneImages(maxBytes: value * 1_048_576) }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.open(store.supportDir)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all unpinned clipboard items?"
        alert.informativeText = "Pinned items are kept."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let store = self.store!
        store.queue.async { store.clearUnpinned() }
    }
}
