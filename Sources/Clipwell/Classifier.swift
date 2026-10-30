import Foundation

enum Kind: String, CaseIterable {
    case text, url, email, color, code, json, number, path, image, files

    var label: String {
        switch self {
        case .text: "Text"
        case .url: "URL"
        case .email: "Email"
        case .color: "Color"
        case .code: "Code"
        case .json: "JSON"
        case .number: "Number"
        case .path: "Path"
        case .image: "Image"
        case .files: "Files"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .url: "link"
        case .email: "envelope"
        case .color: "paintpalette"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .json: "curlybraces"
        case .number: "number"
        case .path: "folder"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }
}

/// Decides what a copied string is and derives searchable tags. Pure functions, no I/O.
enum Classifier {
    private static let emailPattern = try! NSRegularExpression(pattern: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#)
    private static let colorPattern = try! NSRegularExpression(
        pattern: #"^(#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})|rgba?\(\s*\d+[\s,]+\d+[\s,]+\d+.*\))$"#
    )
    /// Bare domains such as `example.com/docs`, limited to common TLDs so `notes.txt` stays text.
    private static let bareURLPattern = try! NSRegularExpression(
        pattern: #"^(www\.)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.(com|org|net|io|dev|app|ai|co|edu|gov|me|uk|de|info)(/\S*)?$"#
    )
    /// Well-known credential shapes. The lookbehind stops `task-manager…` matching `sk-`.
    private static let secretPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(sk-[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.)|-----BEGIN [A-Z ]*PRIVATE KEY-----"#
    )
    /// Tokens that almost only appear in real code. Each counts double.
    private static let strongCodeMarkers = ["=>", "};", "();", "</", "#include", "#!/", "func ", "def ", "import ", "class ", "SELECT ", "public ", "fn "]
    /// Tokens that also appear in ordinary prose. Each counts once.
    private static let weakCodeMarkers = ["const ", "let ", "var ", "return ", "{", "FROM "]

    static func entry(for text: String, sourceApp: String?, sourceBundle: String?) -> Entry {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var tags: [String] = []
        let kind = detect(trimmed, tags: &tags)

        let sensitive = isSensitive(trimmed)
        if sensitive { tags.append("sensitive") }
        // Count lines on the trimmed text so a trailing newline does not make one line "multiline".
        let lines = trimmed.isEmpty ? 0 : trimmed.split(separator: "\n", omittingEmptySubsequences: false).count
        if lines > 1 { tags.append("multiline") }
        tags.append(kind.rawValue)

        let title = sensitive
            ? "Sensitive value · \(text.count) chars"
            : title(for: trimmed, kind: kind)

        return Entry(
            kind: kind,
            title: title,
            hash: Hashing.hex(Data(text.utf8)),
            text: text,
            sourceApp: sourceApp,
            sourceBundle: sourceBundle,
            chars: text.count,
            words: text.split(whereSeparator: \.isWhitespace).count,
            lines: lines,
            bytes: text.utf8.count,
            tags: Array(Set(tags)).sorted()
        )
    }

    /// True when the text contains a well-known credential shape (API key, token, private key).
    static func isSensitive(_ s: String) -> Bool {
        matches(secretPattern, String(s.prefix(200_000)))
    }

    private static func detect(_ t: String, tags: inout [String]) -> Kind {
        guard !t.isEmpty else { return .text }
        let singleLine = !t.contains(where: \.isNewline)
        let hasSpace = t.contains(where: \.isWhitespace)
        // The single-line patterns below only ever describe short values. Skipping them for long
        // input also keeps regex work bounded no matter what is copied.
        let short = t.utf8.count <= 2_048

        if singleLine, short, !hasSpace, t.hasPrefix("http://") || t.hasPrefix("https://") {
            if let host = URL(string: t)?.host?.lowercased() { tags.append("domain:\(host)") }
            return .url
        }
        if singleLine, short, !hasSpace, matches(bareURLPattern, t) {
            let host = t.split(separator: "/").first.map { String($0).lowercased() } ?? t.lowercased()
            tags.append("domain:\(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)")
            return .url
        }
        if singleLine, short, !hasSpace, matches(emailPattern, t) {
            return .email
        }
        if singleLine, short, matches(colorPattern, t) {
            return .color
        }
        if let first = t.first, first == "{" || first == "[", t.utf8.count < 500_000,
           (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil {
            return .json
        }
        if singleLine, !hasSpace, let first = t.first, first.isNumber || "-+.".contains(first),
           Double(t.replacingOccurrences(of: ",", with: "")) != nil {
            return .number
        }
        if singleLine, t.hasPrefix("/") || t.hasPrefix("~/") {
            let ext = URL(fileURLWithPath: t).pathExtension.lowercased()
            if !ext.isEmpty { tags.append("ext:\(ext)") }
            return .path
        }
        if !singleLine, looksLikeCode(t) {
            return .code
        }
        return .text
    }

    /// Scores code-only signals so ordinary prose with the word "return" or a stray brace stays text.
    private static func looksLikeCode(_ t: String) -> Bool {
        let strong = strongCodeMarkers.filter { t.contains($0) }.count
        let weak = weakCodeMarkers.filter { t.contains($0) }.count
        let lines = t.split(separator: "\n")
        let codeEnds = lines.filter { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            return s.hasSuffix(";") || s.hasSuffix("{") || s.hasSuffix("}") || s.hasSuffix("):")
        }.count
        let indented = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
        var score = strong * 2 + weak
        if codeEnds >= 2 { score += 2 }
        if indented >= 2 { score += 1 }
        return score >= 4
    }

    private static func title(for t: String, kind: Kind) -> String {
        if kind == .url {
            let withScheme = t.hasPrefix("http") ? t : "https://" + t
            if let url = URL(string: withScheme), let host = url.host {
                return String((host + url.path).prefix(180))
            }
        }
        let collapsed = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(180))
    }

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
