import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            search
            Divider()
            HStack(spacing: 0) {
                list
                    .frame(width: 320)
                Divider()
                PreviewPane(
                    item: model.selectedItem,
                    text: model.previewText,
                    image: model.previewImage,
                    markedCount: model.marked.count,
                    revealed: model.revealed,
                    onToggleReveal: { model.revealed.toggle() },
                    onCopy: { model.commit(plain: false, delivery: .copyOnly) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        // The window supplies its own rounded corners; the content just has to fill it.
        .background(.ultraThinMaterial)
        .ignoresSafeArea()
        .onChange(of: model.focusTick) { _, _ in searchFocused = true }
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search text, links, apps, tags…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($searchFocused)
                Text("\(model.items.count) of \(model.total)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(nil, "All")
                    ForEach(Kind.allCases, id: \.self) { chip($0, $0.label) }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func chip(_ kind: Kind?, _ title: String) -> some View {
        let active = model.kind == kind
        return Button { model.setKind(kind) } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(active ? Color.accentColor : Color.primary.opacity(0.08)))
                .foregroundStyle(active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.items.isEmpty {
                        Text(model.query.isEmpty ? "Nothing copied yet" : "No matches")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        RowView(
                            item: item,
                            selected: index == model.selected,
                            markNumber: model.marked.firstIndex(of: item.id).map { $0 + 1 }
                        )
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.commit(at: index, plain: false, delivery: .paste) }
                            .onTapGesture { model.selected = index }
                            .contextMenu {
                                Button("Paste") { model.commit(at: index, plain: false, delivery: .paste) }
                                Button("Copy") { model.commit(at: index, plain: false, delivery: .copyOnly) }
                                if item.kind != .image && item.kind != .files {
                                    Button("Copy as Plain Text") { model.commit(at: index, plain: true, delivery: .copyOnly) }
                                }
                                Divider()
                                Button(item.pinned ? "Unpin" : "Pin") {
                                    model.selected = index
                                    model.togglePinSelected()
                                }
                                Button("Delete") {
                                    model.selected = index
                                    model.deleteSelected()
                                }
                            }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selected) { _, new in
                if model.items.indices.contains(new) {
                    proxy.scrollTo(model.items[new].id, anchor: .center)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↩", "Paste")
            hint("⌘C", "Copy")
            hint("⇧", "Plain text")
            hint("⌘M", "Mark")
            hint("⌥↩", "Join marked")
            hint("⌘P", "Pin")
            hint("⌘⌫", "Delete")
            hint("⌘1–9", "Quick")
            hint("⇥", "Filter")
            Spacer()
            hint("esc", "Close")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(label)
        }
    }
}

struct RowView: View {
    let item: Item
    let selected: Bool
    /// 1-based position among the items marked for a multi-item paste.
    let markNumber: Int?

    var body: some View {
        HStack(spacing: 10) {
            if let markNumber {
                Text("\(markNumber)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(selected ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.2)))
            } else {
                Image(systemName: item.isSensitive ? "lock.fill" : item.kind.symbol)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if item.pinned { Image(systemName: "pin.fill") }
                    Text(item.sourceApp ?? "Unknown app")
                    Text("·")
                    Text(Fmt.ago(item.lastUsedAt))
                }
                .font(.system(size: 11))
                .lineLimit(1)
                .opacity(0.85)
            }
            Spacer(minLength: 0)
            if item.useCount > 1 {
                Text("×\(item.useCount)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .opacity(0.7)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.accentColor : .clear))
    }
}

struct PreviewPane: View {
    let item: Item?
    let text: String?
    let image: NSImage?
    let markedCount: Int
    let revealed: Bool
    let onToggleReveal: () -> Void
    let onCopy: () -> Void

    /// Long values are cut for display; paste always uses the full text.
    private static let displayLimit = Store.previewLength

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 12) {
                header(item)
                if markedCount > 0 {
                    Label("\(markedCount) marked — ↩ pastes them together, ⌥↩ joins with spaces", systemImage: "checklist")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                content(item)
                Divider()
                metadata(item)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("Select an item to preview")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ item: Item) -> some View {
        HStack {
            Label(item.kind.label, systemImage: item.kind.symbol)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if item.isSensitive {
                Button(revealed ? "Hide" : "Reveal", action: onToggleReveal)
                    .controlSize(.small)
            }
            Button {
                onCopy()
            } label: {
                Label(markedCount > 0 ? "Copy \(markedCount)" : "Copy", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            .help("Put on the clipboard without pasting (⌘C)")
        }
    }

    @ViewBuilder
    private func content(_ item: Item) -> some View {
        switch item.kind {
        case .image:
            if item.isSensitive && !revealed {
                Label("Image hidden — it appears to contain a secret", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.filePaths, id: \.self) { path in
                        Text(path)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            ScrollView {
                Text(displayText(item))
                    .font(.system(size: 13, design: item.kind == .text ? .default : .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func displayText(_ item: Item) -> String {
        if item.isSensitive && !revealed {
            return String(repeating: "•", count: min(item.chars, 32))
        }
        let shown = text ?? item.text ?? item.title
        if item.chars > Self.displayLimit {
            return shown + "\n\n… \(item.chars - Self.displayLimit) more characters (paste to get all)"
        }
        return shown
    }

    private func metadata(_ item: Item) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            row("Source", item.sourceApp ?? "Unknown")
            row("Copied", Fmt.when(item.createdAt))
            row("Last used", Fmt.ago(item.lastUsedAt))
            row("Times copied", "\(item.useCount)")
            if item.kind != .image && item.kind != .files {
                row("Size", [Fmt.count(item.chars, "char"), Fmt.count(item.words, "word"), Fmt.count(item.lines, "line")].joined(separator: " · "))
            }
            row("Bytes", Fmt.bytes(item.bytes))
            if !item.tags.isEmpty {
                row("Tags", item.tags.filter { $0 != "sensitive" }.joined(separator: ", "))
            }
        }
        .font(.system(size: 11))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}
