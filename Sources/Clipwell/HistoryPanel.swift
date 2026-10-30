import AppKit
import SwiftUI

/// What to do with a chosen item: type it into the app you came from, or only put it back
/// on the clipboard so you can paste it yourself later.
enum Delivery {
    case paste
    case copyOnly
}

/// Borderless-looking panels refuse key focus by default; the search field needs it.
final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// View state for the history window. Mutated on the main thread only.
final class HistoryModel: ObservableObject {
    @Published var query = "" { didSet { scheduleReload() } }
    @Published private(set) var kind: Kind?
    @Published private(set) var items: [Item] = []
    @Published private(set) var total = 0
    @Published var selected = 0 {
        didSet {
            guard selected != oldValue else { return }
            revealed = false
            loadPreview()
        }
    }
    @Published var revealed = false
    /// Items marked for a multi-item paste, in the order they were marked.
    @Published private(set) var marked: [Int64] = []
    /// Preview content for the selected item, loaded off the main thread on selection.
    @Published private(set) var previewText: String?
    @Published private(set) var previewImage: NSImage?
    @Published var focusTick = 0

    let store: Store
    var onCommit: ((Item, Bool, Delivery) -> Void)?
    var onCommitMany: (([Int64], String, Delivery) -> Void)?
    var onDismiss: (() -> Void)?

    private var pending: DispatchWorkItem?
    private let previewQueue = DispatchQueue(label: "clipboard.preview", qos: .userInitiated)

    init(store: Store) {
        self.store = store
    }

    var selectedItem: Item? {
        items.indices.contains(selected) ? items[selected] : nil
    }

    /// Coalesces keystrokes so typing never queues a query per character.
    func scheduleReload() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func reload() {
        let query = self.query
        let kind = self.kind
        let store = self.store
        store.queue.async { [weak self] in
            let rows = store.fetch(query: query, kind: kind, limit: 400)
            let total = store.count()
            DispatchQueue.main.async {
                guard let self else { return }
                self.items = rows
                self.total = total
                if self.selected >= rows.count { self.selected = max(0, rows.count - 1) }
                self.loadPreview()
            }
        }
    }

    func loadPreview() {
        previewText = nil
        previewImage = nil
        guard let item = selectedItem else { return }
        let id = item.id
        let store = self.store

        switch item.kind {
        case .files:
            return
        case .image:
            guard let path = item.imagePath else { return }
            previewQueue.async { [weak self] in
                let image = ImageCache.preview(at: path)
                DispatchQueue.main.async {
                    guard let self, self.selectedItem?.id == id else { return }
                    self.previewImage = image
                }
            }
        default:
            store.queue.async { [weak self] in
                let text = store.previewText(id)
                DispatchQueue.main.async {
                    guard let self, self.selectedItem?.id == id else { return }
                    self.previewText = text
                }
            }
        }
    }

    func setKind(_ kind: Kind?) {
        self.kind = kind
        selected = 0
        reload()
    }

    func cycleKind() {
        let all: [Kind?] = [nil] + Kind.allCases.map { $0 }
        let index = all.firstIndex(of: kind) ?? 0
        setKind(all[(index + 1) % all.count])
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = min(max(selected + delta, 0), items.count - 1)
    }

    /// Marks or unmarks the selected item for a multi-item paste, then moves down.
    func toggleMark() {
        guard let id = selectedItem?.id else { return }
        if let index = marked.firstIndex(of: id) {
            marked.remove(at: index)
        } else {
            marked.append(id)
        }
        move(1)
    }

    func clearMarks() {
        marked = []
    }

    /// Delivers the marked items joined by `joiner`, or just the selected item when none are marked.
    func commit(plain: Bool, joiner: String = "\n", delivery: Delivery = .paste) {
        if !marked.isEmpty {
            let ids = marked
            marked = []
            onCommitMany?(ids, joiner, delivery)
            return
        }
        guard let item = selectedItem else { return }
        onCommit?(item, plain, delivery)
    }

    /// Context-menu helper: act on a specific row regardless of the current selection.
    func commit(at index: Int, plain: Bool, delivery: Delivery) {
        guard items.indices.contains(index) else { return }
        marked = []
        selected = index
        commit(plain: plain, delivery: delivery)
    }

    func quickPaste(_ index: Int, plain: Bool) {
        commit(at: index, plain: plain, delivery: .paste)
    }

    func escape() {
        if !query.isEmpty {
            query = ""
        } else if !marked.isEmpty {
            marked = []
        } else {
            onDismiss?()
        }
    }

    func togglePinSelected() {
        guard let id = selectedItem?.id else { return }
        let store = self.store
        store.queue.async { [weak self] in
            store.togglePin(id)
            DispatchQueue.main.async { self?.reload() }
        }
    }

    func deleteSelected() {
        guard let id = selectedItem?.id else { return }
        marked.removeAll { $0 == id }
        let store = self.store
        store.queue.async { [weak self] in
            store.remove([id])
            DispatchQueue.main.async { self?.reload() }
        }
    }
}

/// Owns the floating panel, its keyboard handling and the paste-back sequence.
final class HistoryWindowController {
    let model: HistoryModel
    /// Put the item (plain: text only) or the joined items on the clipboard.
    var onWrite: ((Item, Bool) -> Void)?
    var onWriteMany: (([Int64], String) -> Void)?
    /// Called after a copy-only action, for feedback in the menu bar.
    var onCopied: (() -> Void)?

    /// The last app the user was working in, so paste-back and "exclude this app" target it.
    private(set) var lastExternalApp: NSRunningApplication?

    private let panel: HistoryPanel
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    init(store: Store) {
        model = HistoryModel(store: store)

        panel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.minSize = NSSize(width: 640, height: 360)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameAutosaveName("ClipwellPanel") // remembers the size you drag it to
        panel.contentView = NSHostingView(rootView: HistoryView(model: model))

        model.onCommit = { [weak self] item, plain, delivery in
            self?.onWrite?(item, plain)
            self?.finish(delivery)
        }
        model.onCommitMany = { [weak self] ids, joiner, delivery in
            self?.onWriteMany?(ids, joiner)
            self?.finish(delivery)
        }
        model.onDismiss = { [weak self] in self?.hide() }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            self?.lastExternalApp = app
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        // Read the caret before activating ourselves, while the other app still has focus.
        let caret = Caret.rect()

        model.query = ""
        model.clearMarks()
        model.setKind(nil)
        model.selected = 0
        model.reload()

        place(near: caret)

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        model.focusTick += 1
        installKeyMonitor()
    }

    func hide() {
        panel.orderOut(nil)
        removeKeyMonitor()
    }

    /// Next to the text caret when the focused app exposes it, otherwise top-centre of the screen
    /// under the mouse. Always kept fully on screen.
    private func place(near caret: NSRect?) {
        let size = panel.frame.size

        if let caret, let screen = NSScreen.screens.first(where: { NSPointInRect(caret.origin, $0.frame) }) {
            let visible = screen.visibleFrame
            var x = caret.minX
            var y = caret.minY - 8 - size.height // below the caret
            if y < visible.minY { y = caret.maxY + 8 } // no room below: go above
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
            y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - frame.height * 0.16
            ))
        }
    }

    /// Closes the panel, returns to the previous app and, for a paste, types ⌘V into it.
    private func finish(_ delivery: Delivery) {
        hide()
        let target = lastExternalApp
        target?.activate()
        guard delivery == .paste else {
            onCopied?()
            return
        }
        guard Paster.isTrusted else { return }
        // Remote-desktop and VM apps would paste on the wrong side of the connection.
        if let bundle = target?.bundleIdentifier, Settings.noAutoPasteBundles.contains(bundle) { return }
        // Give the target app a moment to become key before posting the keystroke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Paster.sendCommandV()
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the key was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)

        switch event.keyCode {
        case 125: model.move(1); return true // down
        case 126: model.move(-1); return true // up
        case 36, 76: // return, keypad enter
            model.commit(plain: shift, joiner: option ? " " : "\n")
            return true
        case 53: model.escape(); return true // escape
        case 48: model.cycleKind(); return true // tab
        case 51 where cmd: model.deleteSelected(); return true
        case 35 where cmd: model.togglePinSelected(); return true // ⌘P
        case 46 where cmd: model.toggleMark(); return true // ⌘M
        case 8 where cmd: // ⌘C copies the item without pasting; ⇧⌘C copies plain text
            // Leave ordinary copy alone when text is selected in the search field.
            if let field = panel.firstResponder as? NSTextView, field.selectedRange().length > 0 { return false }
            model.commit(plain: shift, joiner: option ? " " : "\n", delivery: .copyOnly)
            return true
        default: break
        }

        if cmd, let key = event.charactersIgnoringModifiers, let n = Int(key), (1...9).contains(n) {
            model.quickPaste(n - 1, plain: shift)
            return true
        }
        return false
    }
}
