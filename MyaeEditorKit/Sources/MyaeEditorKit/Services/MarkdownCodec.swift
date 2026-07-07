//
//  MarkdownCodec.swift
//  MyaeEditor
//
//  Encodes the document to Markdown and parses it back. Inline bold/italic are
//  preserved as **/*; block kinds map to standard Markdown constructs.
//

import AppKit

enum MarkdownCodec {

    /// Encode an inline attributed string to Markdown relative to `baseFont`,
    /// marking only the bold/italic that go *beyond* the base font (so a semibold
    /// table header isn't wrapped in ** for its inherent weight). Reused by table
    /// cells, which store their text as inline Markdown.
    static func inlineMarkdown(from attr: NSAttributedString, baseFont: NSFont) -> String {
        let base = NSFontManager.shared.traits(of: baseFont)
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
            // Inline link → [text](url), with emphasis/strike still wrapping it.
            if let url = attrs[.myaeLink] as? URL {
                out += strikeMark + emph + "[" + escape(raw) + "](" + url.absoluteString + ")" + emph + strikeMark
                return
            }
            // Order: ~~ outside, emphasis inside.
            out += strikeMark + emph + escape(raw) + emph + strikeMark
        }
        return out
    }

    /// Parse a `[text](url)` link starting at `chars[start]` (which must be `[`).
    /// Returns the visible text, the URL, and the index just past the closing `)`.
    /// Backslash-escapes inside the text are honored; nested brackets are not.
    static func parseLink(_ chars: [Character], from start: Int)
        -> (text: String, url: URL, next: Int)? {
        guard start < chars.count, chars[start] == "[" else { return nil }
        var i = start + 1
        var text = ""
        while i < chars.count, chars[i] != "]" {
            if chars[i] == "\\", i + 1 < chars.count { text.append(chars[i + 1]); i += 2; continue }
            text.append(chars[i]); i += 1
        }
        guard i < chars.count, chars[i] == "]", i + 1 < chars.count, chars[i + 1] == "(" else { return nil }
        i += 2
        var urlString = ""
        while i < chars.count, chars[i] != ")" { urlString.append(chars[i]); i += 1 }
        guard i < chars.count, chars[i] == ")", !urlString.isEmpty,
              let url = URL(string: urlString) else { return nil }
        return (text, url, i + 1)
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
    static func separatorCell(_ a: ColumnAlignment) -> String {
        switch a {
        case .left:   return ":---"
        case .center: return ":---:"
        case .right:  return "---:"
        case .none:   return "---"
        }
    }

    /// The alignment encoded by a single separator cell (`:---:` etc.).
    static func alignment(ofSeparatorCell cell: String) -> ColumnAlignment {
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
    static func isSeparatorRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") else { return false }
        let cells = parseRow(t)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return !c.isEmpty && c.allSatisfy { $0 == "-" || $0 == ":" } && c.contains("-")
        }
    }

    static func parseRow(_ line: String) -> [String] {
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

    static func normalize(_ row: [String], to count: Int) -> [String] {
        if row.count == count { return row }
        if row.count > count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }

    // MARK: Decode

    /// Compiled once and reused — NSRegularExpression compilation isn't free, and
    /// decode checks these against every line of the document.
    static let imageLineRegex = try? NSRegularExpression(pattern: #"^!\[[^\]]*\]\((.+)\)$"#)
    static let numberedPrefixRegex = try? NSRegularExpression(pattern: #"^\d+\.\s"#)

    /// Parse inline Markdown (**, *, ***, `code`, ~~, $math$) into an attributed
    /// string using an explicit base font/color. `mathKind` styles inline-math
    /// attachments. Reused by table cells (14pt base, semibold for headers).
    static func inlineAttributed(_ md: String, baseFont: NSFont, color: NSColor,
                                 mathKind: BlockKind = .paragraph) -> NSAttributedString {
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
        /// Append `text` as a link to `url` (link color + underline), honoring the
        /// current emphasis/strike toggles.
        func appendLink(_ text: String, url: URL) {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: currentFont(),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .myaeLink: url,
            ]
            if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: text, attributes: attrs))
        }

        while i < chars.count {
            let c = chars[i]
            // Inline link: [text](url)
            if c == "[", let link = Self.parseLink(chars, from: i) {
                appendLink(link.text, url: link.url)
                i = link.next
                continue
            }
            // Inline math: $...$
            if c == "$" {
                var j = i + 1
                var latex = ""
                while j < chars.count && chars[j] != "$" { latex.append(chars[j]); j += 1 }
                if j < chars.count {   // found the closing $
                    result.append(InlineMath.attributedString(latex: latex, fontSize: baseFont.pointSize, kind: mathKind))
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
