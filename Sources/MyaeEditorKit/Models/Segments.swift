//
//  Segments.swift
//  MyaeEditor
//
//  The continuous (non-block) document model. A document is an ordered list of
//  `Segment`s: runs of textual content fused into one editable text storage, with
//  rendered widgets (tables, images, mermaid, equations, dividers) between them.
//  Markdown exists only at the boundaries (file I/O, copy/paste, controller API);
//  the storage itself holds rich attributed text, WYSIWYG.
//

import AppKit
import Combine

// MARK: - Attribute keys

extension NSAttributedString.Key {
    /// Per-paragraph kind marker inside a text segment's storage. The value is a
    /// `ParagraphKind`. Applied uniformly across each paragraph (including its
    /// trailing newline) so typing at the paragraph end inherits it.
    static let paragraphKind = NSAttributedString.Key("myaeParagraphKind")
    /// An inline link. The value is a `URL`. Rendered with link color + underline;
    /// serialized back to `[visible text](url)`.
    static let myaeLink = NSAttributedString.Key("myaeLink")
}

// MARK: - ParagraphKind

/// The kind of a single paragraph inside a text segment, plus its list depth and
/// (for todos) checked state. Stored as the `.paragraphKind` attribute value.
struct ParagraphKind: Equatable, Hashable {
    var kind: BlockKind
    var depth: Int
    var checked: Bool

    init(_ kind: BlockKind = .paragraph, depth: Int = 0, checked: Bool = false) {
        self.kind = kind
        self.depth = depth
        self.checked = checked
    }

    static let paragraph = ParagraphKind(.paragraph)
}

// MARK: - Segment

/// One piece of the document: either a run of editable text or a rendered widget.
@Observable
final class Segment: Identifiable {
    let id: UUID
    var payload: Payload

    enum Payload {
        /// A run of textual paragraphs (paragraph/heading/list/todo/quote) fused
        /// into one multi-line storage. The storage IS the model — the text view
        /// attaches to it directly.
        case text(NSTextStorage)
        /// A fenced code block (including mermaid, whose language is `.mermaid`).
        /// Like text segments, code owns a shared storage object so the live text
        /// view edits the model in place instead of copying the entire attributed
        /// string after every keystroke.
        case code(language: CodeLanguage, text: NSTextStorage)
        case table(TableData)
        case image(path: String?)
        /// A centered display equation; the value is its LaTeX source.
        case equation(latex: String)
        case divider
    }

    init(id: UUID = UUID(), payload: Payload) {
        self.id = id
        self.payload = payload
    }

    /// Whether this is a text segment (the only kind that hosts an editable run).
    var isText: Bool {
        if case .text = payload { return true }
        return false
    }

    /// The backing storage of a text segment, or `nil` for widgets.
    var textStorage: NSTextStorage? {
        if case .text(let s) = payload { return s }
        return nil
    }

    /// The source text of a code segment, or `nil` otherwise.
    var codeText: NSTextStorage? {
        if case .code(_, let t) = payload { return t }
        return nil
    }

    var codeLanguage: CodeLanguage? {
        if case .code(let l, _) = payload { return l }
        return nil
    }

    /// A new empty text segment (a single blank paragraph the caret can land in).
    static func emptyText() -> Segment {
        Segment(payload: .text(SegmentStyle.makeStorage(from: NSAttributedString(
            string: "", attributes: SegmentStyle.attributes(for: .paragraph)))))
    }
}
