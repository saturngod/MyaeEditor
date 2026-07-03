//
//  MarkdownCodec.swift
//  MyaeEditor
//
//  Encodes the document to Markdown and parses it back. Inline bold/italic are
//  preserved as **/*; block kinds map to standard Markdown constructs.
//

import AppKit

enum MarkdownCodec {

    private static let indentUnit = "    "   // 4 spaces per nesting level

    // MARK: Encode

    static func encode(_ document: EditorDocument) -> String {
        var lines: [String] = []
        // Running ordinal per depth for numbered lists. Advancing this in the
        // single encode pass replaces the per-block O(n) `document.number(for:)`
        // scan (which made encoding O(n²)). Mirrors `number(for:)` semantics:
        // deeper items are skipped (don't reset a parent run); a shallower block
        // or a non-numbered sibling ends the run at that depth (and deeper).
        var counters: [Int: Int] = [:]
        for block in document.blocks {
            let pad = String(repeating: indentUnit, count: block.depth)
            let depth = block.depth
            // Any block ends numbered runs nested deeper than itself.
            counters = counters.filter { $0.key <= depth }
            if block.kind == .numbered {
                counters[depth] = (counters[depth] ?? 0) + 1
            } else {
                // A non-numbered block at this depth also ends the run here.
                counters[depth] = nil
            }
            switch block.kind {
            case .divider:
                lines.append("---")
            case .image:
                if let path = block.imagePath { lines.append("![](\(path))") }
            case .table:
                guard let t = block.table, t.rowCount > 0 else { break }
                for (idx, row) in t.cells.enumerated() {
                    lines.append("| " + row.map(escapeCell).joined(separator: " | ") + " |")
                    if idx == 0 {
                        let seps = (0 ..< row.count).map { separatorCell(t.alignment($0)) }
                        lines.append("| " + seps.joined(separator: " | ") + " |")
                    }
                }
            case .code:
                let lang = block.language == .plain ? "" : block.language.rawValue
                lines.append("```\(lang)")
                lines.append(contentsOf: block.plainText.components(separatedBy: "\n"))
                lines.append("```")
            case .heading1:
                lines.append(pad + "# " + inline(block))
            case .heading2:
                lines.append(pad + "## " + inline(block))
            case .heading3:
                lines.append(pad + "### " + inline(block))
            case .bulleted:
                lines.append(pad + "- " + inline(block))
            case .numbered:
                lines.append(pad + "\(counters[depth] ?? 1). " + inline(block))
            case .todo:
                lines.append(pad + "- [\(block.checked ? "x" : " ")] " + inline(block))
            case .quote:
                lines.append(pad + "> " + inline(block))
            case .paragraph:
                lines.append(pad + inline(block))
            case .equation:
                lines.append("$$" + block.plainText + "$$")
            case .inlineMath:
                break   // pseudo-kind; never an actual block
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Convert a block's attributed text to inline Markdown, marking only the
    /// bold/italic that go *beyond* the block's base font (so headings aren't
    /// wrapped in ** for their inherent weight).
    private static func inline(_ block: Block) -> String {
        let attr = block.text
        let base = NSFontManager.shared.traits(of: block.kind.baseFont)
        let baseBold = base.contains(.boldFontMask)
        let baseItalic = base.contains(.italicFontMask)

        var out = ""
        let full = NSRange(location: 0, length: attr.length)
        attr.enumerateAttributes(in: full) { attrs, range, _ in
            // Inline math attachment → $latex$
            if let math = attrs[.attachment] as? MathAttachment {
                out += "$" + math.latex + "$"
                return
            }
            // Inline code → `raw` (content is literal, so no escaping).
            if (attrs[.inlineCode] as? Bool) == true {
                out += "`" + attr.attributedSubstring(from: range).string + "`"
                return
            }
            let traits = (attrs[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            let bold = traits.contains(.boldFontMask) && !baseBold
            let italic = traits.contains(.italicFontMask) && !baseItalic
            let strike = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
            let emph = bold && italic ? "***" : bold ? "**" : italic ? "*" : ""
            let strikeMark = strike ? "~~" : ""
            let raw = attr.attributedSubstring(from: range).string
            // Order: ~~ outside, emphasis inside.
            out += strikeMark + emph + escape(raw) + emph + strikeMark
        }
        return out
    }

    /// Backslash-escape Markdown metacharacters in a single pass (one scan instead
    /// of eight `replacingOccurrences` passes over the whole string).
    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\", "*", "_", "~", "`", "[", "]", "!":
                out.append("\\")
                out.append(ch)
            default:
                out.append(ch)
            }
        }
        return out
    }

    // MARK: Table helpers

    nonisolated private static func escapeCell(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "|", with: "\\|")
    }

    /// The GFM separator cell for a column alignment.
    private static func separatorCell(_ a: ColumnAlignment) -> String {
        switch a {
        case .left:   return ":---"
        case .center: return ":---:"
        case .right:  return "---:"
        case .none:   return "---"
        }
    }

    /// The alignment encoded by a single separator cell (`:---:` etc.).
    private static func alignment(ofSeparatorCell cell: String) -> ColumnAlignment {
        let c = cell.trimmingCharacters(in: .whitespaces)
        let left = c.hasPrefix(":"), right = c.hasSuffix(":")
        switch (left, right) {
        case (true, true):  return .center
        case (true, false): return .left
        case (false, true): return .right
        default:            return .none
        }
    }

    /// A GFM separator row: every cell is dashes (optionally colon-aligned).
    private static func isSeparatorRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") else { return false }
        let cells = parseRow(t)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return !c.isEmpty && c.allSatisfy { $0 == "-" || $0 == ":" } && c.contains("-")
        }
    }

    private static func parseRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        var cells: [String] = []
        var cur = ""
        let arr = Array(s)
        var i = 0
        while i < arr.count {
            if arr[i] == "\\", i + 1 < arr.count, arr[i + 1] == "|" {
                cur.append("|"); i += 2; continue
            }
            if arr[i] == "|" { cells.append(cur); cur = ""; i += 1; continue }
            cur.append(arr[i]); i += 1
        }
        cells.append(cur)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func normalize(_ row: [String], to count: Int) -> [String] {
        if row.count == count { return row }
        if row.count > count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }

    // MARK: Decode

    /// Compiled once and reused — NSRegularExpression compilation isn't free, and
    /// decode checks these against every line of the document.
    private static let imageLineRegex = try? NSRegularExpression(pattern: #"^!\[[^\]]*\]\((.+)\)$"#)
    private static let numberedPrefixRegex = try? NSRegularExpression(pattern: #"^\d+\.\s"#)

    /// Decode pasteboard text into blocks. Normalizes CRLF/CR to LF and strips
    /// trailing newlines (browser/terminal copies commonly append them; they'd
    /// otherwise decode into trailing empty paragraphs).
    static func decodeForPaste(_ raw: String) -> [Block] {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")
        while s.hasSuffix("\n") { s.removeLast() }
        return decode(s)
    }

    static func decode(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                let language = CodeLanguage.resolve(info)
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1   // skip closing fence
                let text = NSAttributedString(string: code.joined(separator: "\n"),
                                              attributes: BlockTextView.typingAttributes(for: .code))
                blocks.append(Block(kind: .code, text: text, language: language))
                continue
            }

            // Block equation: $$ ... $$ on one line.
            if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count >= 4 {
                let latex = String(trimmed.dropFirst(2).dropLast(2))
                blocks.append(Block(kind: .equation, text: NSAttributedString(string: latex)))
                i += 1; continue
            }

            // Divider.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(Block(kind: .divider))
                i += 1; continue
            }

            // Image: ![alt](path)
            if let regex = imageLineRegex,
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let pathRange = Range(match.range(at: 1), in: trimmed) {
                let path = String(trimmed[pathRange])
                blocks.append(Block(kind: .image, imagePath: path.isEmpty ? nil : path))
                i += 1; continue
            }

            // Table: a "| ... |" row followed by a separator row.
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isSeparatorRow(lines[i + 1]) {
                let header = parseRow(trimmed)
                let alignments = normalize(parseRow(lines[i + 1]), to: header.count)
                    .map { alignment(ofSeparatorCell: $0) }
                var rows: [[String]] = [header]
                i += 2   // skip header + separator
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|"), !isSeparatorRow(lines[i]) else { break }
                    rows.append(normalize(parseRow(t), to: header.count))
                    i += 1
                }
                blocks.append(Block(kind: .table, table: TableData(cells: rows, alignments: alignments)))
                continue
            }

            // Depth from leading spaces (4 per level).
            let leadingSpaces = line.prefix { $0 == " " }.count
            let depth = leadingSpaces / 4
            var content = String(line.dropFirst(depth * 4)).drop { $0 == " " }.description

            var kind: BlockKind = .paragraph
            var checked = false

            if content.hasPrefix("### ") { kind = .heading3; content.removeFirst(4) }
            else if content.hasPrefix("## ") { kind = .heading2; content.removeFirst(3) }
            else if content.hasPrefix("# ") { kind = .heading1; content.removeFirst(2) }
            else if content.hasPrefix("> ") { kind = .quote; content.removeFirst(2) }
            else if content.hasPrefix("- [ ] ") { kind = .todo; checked = false; content.removeFirst(6) }
            else if content.hasPrefix("- [x] ") || content.hasPrefix("- [X] ") { kind = .todo; checked = true; content.removeFirst(6) }
            else if content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("+ ") { kind = .bulleted; content.removeFirst(2) }
            else if let re = numberedPrefixRegex,
                    let m = re.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
                    let r = Range(m.range, in: content) {
                kind = .numbered; content.removeSubrange(r)
            }

            let block = Block(kind: kind,
                              text: parseInline(content, kind: kind),
                              checked: checked,
                              depth: depth)
            blocks.append(block)
            i += 1
        }

        return blocks.isEmpty ? [Block()] : blocks
    }

    /// Parse inline Markdown (**, *, ***) into an attributed string using the
    /// block kind's base font/color.
    private static func parseInline(_ md: String, kind: BlockKind) -> NSAttributedString {
        let baseFont = kind.baseFont
        let color: NSColor = (kind == .quote) ? .secondaryLabelColor : .textColor
        let result = NSMutableAttributedString()
        let chars = Array(md)
        var i = 0
        var bold = false, italic = false, strike = false

        func currentFont() -> NSFont {
            var f = baseFont
            if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
            if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
            return f
        }
        func append(_ s: String) {
            var attrs: [NSAttributedString.Key: Any] = [.font: currentFont(), .foregroundColor: color]
            if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: s, attributes: attrs))
        }

        while i < chars.count {
            let c = chars[i]
            // Inline math: $...$
            if c == "$" {
                var j = i + 1
                var latex = ""
                while j < chars.count && chars[j] != "$" { latex.append(chars[j]); j += 1 }
                if j < chars.count {   // found the closing $
                    result.append(InlineMath.attributedString(latex: latex, fontSize: baseFont.pointSize, kind: kind))
                    i = j + 1
                    continue
                }
            }
            if c == "\\" && i + 1 < chars.count {
                append(String(chars[i + 1])); i += 2; continue
            }
            // Inline code: `...` — content is literal (no nested markers).
            if c == "`" {
                var j = i + 1
                var code = ""
                while j < chars.count && chars[j] != "`" { code.append(chars[j]); j += 1 }
                if j < chars.count {   // found the closing `
                    result.append(NSAttributedString(
                        string: code,
                        attributes: InlineCode.attributes(size: baseFont.pointSize, color: color)))
                    i = j + 1
                    continue
                }
            }
            if c == "~" && i + 1 < chars.count && chars[i + 1] == "~" {
                strike.toggle(); i += 2; continue
            }
            if c == "*" {
                var count = 0
                while i < chars.count && chars[i] == "*" { count += 1; i += 1 }
                if count >= 3 { bold.toggle(); italic.toggle() }
                else if count == 2 { bold.toggle() }
                else { italic.toggle() }
                continue
            }
            if c == "_" {
                // _ alone toggles italic; __ toggles bold (like GitHub).
                var count = 0
                while i < chars.count && chars[i] == "_" { count += 1; i += 1 }
                if count >= 2 { bold.toggle() } else { italic.toggle() }
                continue
            }
            append(String(c)); i += 1
        }
        return result
    }
}

/// Reads and writes the document's Markdown (and bundled images) to Application Support.
enum DocumentStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MyaeEditor", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("document.md") }
    static var imagesDirectory: URL { directory.appendingPathComponent("images", isDirectory: true) }

    static func load() -> String? {
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            return nil   // first launch — no file yet
        } catch {
            NSLog("[DocumentStore] Failed to load document: %@", error.localizedDescription)
            return nil
        }
    }

    private static let titleKey = "MyaeEditor.documentTitle"
    static func loadTitle() -> String { UserDefaults.standard.string(forKey: titleKey) ?? "" }
    static func saveTitle(_ title: String) { UserDefaults.standard.set(title, forKey: titleKey) }

    static func save(_ markdown: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[DocumentStore] Failed to save document: %@", error.localizedDescription)
        }
    }

    /// The .md file currently open (set by Open / Save As). `nil` means the
    /// document is the unsaved default kept in Application Support.
    static var currentFileURL: URL?

    /// Directory that relative image paths resolve against — the open file's
    /// folder, or the Application Support store for the unsaved default.
    static var baseDirectory: URL {
        currentFileURL?.deletingLastPathComponent() ?? directory
    }

    /// Resolve a stored image path — absolute ("/Users/…") or relative to the
    /// document's directory ("./images/x.png", "../shared/x.png") — to a URL.
    static func imageURL(for path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: path, relativeTo: baseDirectory).standardized
    }

    /// The path to store for a picked image: a relative link when the file sits
    /// in the document's directory or one level up ("./…" / "../…"); otherwise
    /// the absolute path (so we never emit deep "../../.." chains). A document
    /// with no file yet (unsaved) always stores the absolute path. Nothing is
    /// copied — the original file is referenced in place.
    static func referencePath(for url: URL) -> String {
        let absolute = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard currentFileURL != nil else { return absolute }   // unsaved doc → full path
        let file = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let base = baseDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var i = 0
        while i < file.count, i < base.count, file[i] == base[i] { i += 1 }
        let ups = base.count - i
        let downs = file[i...].joined(separator: "/")
        if ups > 1 { return absolute }
        if ups == 1 { return "../" + downs }
        return "./" + downs
    }
}
