//
//  SegmentCodec.swift
//  MyaeEditor
//
//  Converts between the segment document model and Markdown. Text segments walk
//  their paragraphs (reading the `.paragraphKind` attribute); widgets use the
//  same GFM/fence/image/equation forms as the old block codec. Inline styling is
//  shared with `MarkdownCodec` (bold/italic/strike/code/math/links).
//

import AppKit

enum SegmentCodec {

    private static let indentUnit = "    "   // 4 spaces per nesting level

    // MARK: Encode

    static func encode(_ segments: [Segment]) -> String {
        var lines: [String] = []
        for seg in segments {
            switch seg.payload {
            case .text(let storage):
                lines.append(contentsOf: encodeTextSegment(storage))
            case .code(let language, let text):
                let lang = language == .plain ? "" : language.rawValue
                lines.append("```\(lang)")
                lines.append(contentsOf: text.string.components(separatedBy: "\n"))
                lines.append("```")
            case .table(let t):
                lines.append(contentsOf: encodeTable(t))
            case .image(let path):
                if let path { lines.append("![](\(path))") }
            case .equation(let latex):
                lines.append("$$" + latex + "$$")
            case .divider:
                lines.append("---")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Encode one text segment's storage to Markdown lines (one per paragraph).
    private static func encodeTextSegment(_ storage: NSTextStorage) -> [String] {
        var lines: [String] = []
        let parts = storage.string.components(separatedBy: "\n")
        var offset = 0
        // Running ordinal per depth for numbered lists, matching the old block codec.
        var counters: [Int: Int] = [:]
        for part in parts {
            let partLen = (part as NSString).length
            let range = NSRange(location: offset, length: partLen)
            // A trailing empty paragraph has no character to carry its kind, so it
            // is a plain blank line. Non-final empty paragraphs read their kind from
            // their terminating newline.
            let pk: ParagraphKind = (partLen == 0 && offset >= storage.length)
                ? .paragraph
                : SegmentStyle.paragraphKind(in: storage, at: offset)
            let attr = storage.attributedSubstring(from: range)
            let depth = pk.depth
            let pad = String(repeating: indentUnit, count: depth)
            counters = counters.filter { $0.key <= depth }
            if pk.kind == .numbered {
                counters[depth] = (counters[depth] ?? 0) + 1
            } else {
                counters[depth] = nil
            }
            let md = MarkdownCodec.inlineMarkdown(from: attr, baseFont: pk.kind.baseFont)
            switch pk.kind {
            case .heading1: lines.append(pad + "# " + md)
            case .heading2: lines.append(pad + "## " + md)
            case .heading3: lines.append(pad + "### " + md)
            case .heading4: lines.append(pad + "#### " + md)
            case .heading5: lines.append(pad + "##### " + md)
            case .heading6: lines.append(pad + "###### " + md)
            case .bulleted: lines.append(pad + "- " + md)
            case .numbered: lines.append(pad + "\(counters[depth] ?? 1). " + md)
            case .todo:     lines.append(pad + "- [\(pk.checked ? "x" : " ")] " + md)
            case .quote:    lines.append(pad + "> " + md)
            default:        lines.append(pad + md)   // paragraph (and any non-textual fallback)
            }
            offset += partLen + 1   // + newline
        }
        return lines
    }

    private static func encodeTable(_ t: TableData) -> [String] {
        guard t.rowCount > 0 else { return [] }
        var lines: [String] = []
        for (idx, row) in t.cells.enumerated() {
            lines.append("| " + row.map(escapeCell).joined(separator: " | ") + " |")
            if idx == 0 {
                let seps = (0 ..< row.count).map { MarkdownCodec.separatorCell(t.alignment($0)) }
                lines.append("| " + seps.joined(separator: " | ") + " |")
            }
        }
        return lines
    }

    private static func escapeCell(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "|", with: "\\|")
    }

    // MARK: Decode

    static func decodeForPaste(_ raw: String) -> [Segment] {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")
        while s.hasSuffix("\n") { s.removeLast() }
        return decode(s)
    }

    static func decode(_ markdown: String) -> [Segment] {
        var segments: [Segment] = []
        var textRun: [(ParagraphKind, NSAttributedString)] = []

        func flushText() {
            guard !textRun.isEmpty else { return }
            segments.append(Segment(payload: .text(SegmentStyle.buildTextStorage(textRun))))
            textRun.removeAll()
        }

        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block (incl. mermaid).
            if trimmed.hasPrefix("```") {
                flushText()
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
                segments.append(Segment(payload: .code(language: language, text: text)))
                continue
            }

            // Block equation.
            if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count >= 4 {
                flushText()
                segments.append(Segment(payload: .equation(latex: String(trimmed.dropFirst(2).dropLast(2)))))
                i += 1; continue
            }

            // Divider.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushText()
                segments.append(Segment(payload: .divider))
                i += 1; continue
            }

            // Image.
            if let regex = MarkdownCodec.imageLineRegex,
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let pathRange = Range(match.range(at: 1), in: trimmed) {
                flushText()
                let path = String(trimmed[pathRange])
                segments.append(Segment(payload: .image(path: path.isEmpty ? nil : path)))
                i += 1; continue
            }

            // Table.
            if trimmed.hasPrefix("|"), i + 1 < lines.count, MarkdownCodec.isSeparatorRow(lines[i + 1]) {
                flushText()
                let header = MarkdownCodec.parseRow(trimmed)
                let alignments = MarkdownCodec.normalize(MarkdownCodec.parseRow(lines[i + 1]), to: header.count)
                    .map { MarkdownCodec.alignment(ofSeparatorCell: $0) }
                var rows: [[String]] = [header]
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|"), !MarkdownCodec.isSeparatorRow(lines[i]) else { break }
                    rows.append(MarkdownCodec.normalize(MarkdownCodec.parseRow(t), to: header.count))
                    i += 1
                }
                segments.append(Segment(payload: .table(TableData(cells: rows, alignments: alignments))))
                continue
            }

            // Textual line — accumulate into the current text segment.
            textRun.append(decodeTextLine(line))
            i += 1
        }

        flushText()
        return segments.isEmpty ? [Segment.emptyText()] : segments
    }

    /// Parse one textual Markdown line into a paragraph kind + inline attributed text.
    private static func decodeTextLine(_ line: String) -> (ParagraphKind, NSAttributedString) {
        let leadingSpaces = line.prefix { $0 == " " }.count
        let depth = leadingSpaces / 4
        var content = String(line.dropFirst(depth * 4)).drop { $0 == " " }.description

        var kind: BlockKind = .paragraph
        var checked = false

        if content.hasPrefix("###### ") { kind = .heading6; content.removeFirst(7) }
        else if content.hasPrefix("##### ") { kind = .heading5; content.removeFirst(6) }
        else if content.hasPrefix("#### ") { kind = .heading4; content.removeFirst(5) }
        else if content.hasPrefix("### ") { kind = .heading3; content.removeFirst(4) }
        else if content.hasPrefix("## ") { kind = .heading2; content.removeFirst(3) }
        else if content.hasPrefix("# ") { kind = .heading1; content.removeFirst(2) }
        else if content.hasPrefix("> ") { kind = .quote; content.removeFirst(2) }
        else if content.hasPrefix("- [ ] ") { kind = .todo; checked = false; content.removeFirst(6) }
        else if content.hasPrefix("- [x] ") || content.hasPrefix("- [X] ") { kind = .todo; checked = true; content.removeFirst(6) }
        else if content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("+ ") { kind = .bulleted; content.removeFirst(2) }
        else if let re = MarkdownCodec.numberedPrefixRegex,
                let m = re.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
                let r = Range(m.range, in: content) {
            kind = .numbered; content.removeSubrange(r)
        }

        let pk = ParagraphKind(kind, depth: depth, checked: checked)
        let inline = MarkdownCodec.inlineAttributed(
            content,
            baseFont: kind.baseFont,
            color: (kind == .quote) ? .secondaryLabelColor : .textColor,
            mathKind: kind)
        return (pk, inline)
    }
}
