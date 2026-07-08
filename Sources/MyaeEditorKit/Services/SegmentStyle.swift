//
//  SegmentStyle.swift
//  MyaeEditor
//
//  Centralizes the per-paragraph visual styling of a text segment: font, color,
//  paragraph style (list/quote indents), and the `.paragraphKind` attribute that
//  records each paragraph's kind. Used by the codec (to build display-ready
//  storage), the paragraph fixer, and the text view.
//

import AppKit

enum SegmentStyle {
    /// Horizontal room reserved for a list bullet / number / checkbox, drawn in
    /// the head-indent gutter (markers are decorations, never text).
    static let listGutter: CGFloat = 24
    /// Room for the quote bar.
    static let quoteGutter: CGFloat = 16
    /// Extra indent per nesting level for lists.
    static let indentPerLevel: CGFloat = 24

    /// The gutter width a kind reserves at the head of its paragraph.
    static func markerGutter(for kind: BlockKind) -> CGFloat {
        switch kind {
        case .bulleted, .numbered, .todo: return listGutter
        case .quote: return quoteGutter
        default: return 0
        }
    }

    /// Typing / paragraph attributes for a paragraph of the given kind, including
    /// list-depth indentation and the `.paragraphKind` marker.
    static func attributes(for pk: ParagraphKind) -> [NSAttributedString.Key: Any] {
        var attrs = BlockTextView.typingAttributes(for: pk.kind)
        let base = (attrs[.paragraphStyle] as? NSParagraphStyle) ?? NSParagraphStyle()
        // swiftlint:disable:next force_cast
        let para = base.mutableCopy() as! NSMutableParagraphStyle
        let indent = CGFloat(pk.depth) * indentPerLevel + markerGutter(for: pk.kind)
        para.firstLineHeadIndent = indent
        para.headIndent = indent
        attrs[.paragraphStyle] = para
        attrs[.paragraphKind] = pk
        return attrs
    }

    /// Convenience overload.
    static func attributes(for kind: BlockKind, depth: Int = 0, checked: Bool = false) -> [NSAttributedString.Key: Any] {
        attributes(for: ParagraphKind(kind, depth: depth, checked: checked))
    }

    /// Build one styled paragraph from a kind + already-inline-styled content
    /// (no trailing newline). Applies the paragraph style, the `.paragraphKind`
    /// marker, and (for checked todos) strikethrough + dim across the content.
    static func paragraph(_ pk: ParagraphKind, content: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: content)
        let full = NSRange(location: 0, length: m.length)
        let attrs = attributes(for: pk)
        if let para = attrs[.paragraphStyle] {
            m.addAttribute(.paragraphStyle, value: para, range: full)
        }
        applyBaselineOffset(from: attrs, to: m, range: full)
        if m.length > 0 {
            m.addAttribute(.paragraphKind, value: pk, range: full)
            // Note: a checked todo's strikethrough/dim is a display-only decoration
            // applied by the text view — it is not baked into the stored content, so
            // the codec never mistakes it for a `~~strike~~` inline mark.
        }
        return m
    }

    /// Assemble a full text-segment storage from an ordered list of paragraphs,
    /// applying each paragraph's kind to its trailing newline too so that empty
    /// paragraphs still carry their kind.
    static func buildTextStorage(_ paragraphs: [(ParagraphKind, NSAttributedString)]) -> NSTextStorage {
        let joined = NSMutableAttributedString()
        let items = paragraphs.isEmpty ? [(ParagraphKind.paragraph, NSAttributedString(string: ""))] : paragraphs
        for (i, item) in items.enumerated() {
            joined.append(paragraph(item.0, content: item.1))
            if i < items.count - 1 {
                joined.append(NSAttributedString(string: "\n", attributes: attributes(for: item.0)))
            }
        }
        return NSTextStorage(attributedString: joined)
    }

    static func makeStorage(from attr: NSAttributedString) -> NSTextStorage {
        NSTextStorage(attributedString: attr)
    }

    /// Apply (or clear) the vertical-centering `.baselineOffset` implied by
    /// `attrs` over `range` of `storage`. `.baselineOffset` is a per-character
    /// attribute, not part of `NSParagraphStyle`, so re-assigning a paragraph's
    /// kind must reset it just as reliably as it sets it — converting a heading
    /// (no shift) back to a body paragraph needs the old shift cleared, not just
    /// the new one skipped.
    static func applyBaselineOffset(from attrs: [NSAttributedString.Key: Any],
                                    to storage: NSMutableAttributedString, range: NSRange) {
        if let shift = attrs[.baselineOffset] {
            storage.addAttribute(.baselineOffset, value: shift, range: range)
        } else {
            storage.removeAttribute(.baselineOffset, range: range)
        }
    }

    /// Re-derive every run's `.font` in `storage` from its paragraph kind's
    /// current base font, in place — used when the editor's font setting changes
    /// while a document is open. Mirrors `SegmentNSTextView.setParagraphKind`'s
    /// re-font pass: inline code keeps its monospace face but tracks the base
    /// size, math attachments are left untouched, and bold/italic traits are
    /// re-applied. Only `.font` is touched, so the caret, selection, undo stack,
    /// colors, and links all survive.
    static func restyleFonts(in storage: NSTextStorage) {
        guard storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: full, options: []) { value, sub, _ in
            let base = paragraphKind(in: storage, at: sub.location).kind.baseFont
            if (storage.attribute(.inlineCode, at: sub.location, effectiveRange: nil) as? Bool) == true {
                storage.addAttribute(.font, value: InlineCode.font(size: base.pointSize), range: sub)
                return
            }
            if storage.attribute(.attachment, at: sub.location, effectiveRange: nil) != nil { return }
            let traits = (value as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            var f = base
            if traits.contains(.boldFontMask) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
            if traits.contains(.italicFontMask) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
            storage.addAttribute(.font, value: f, range: sub)
        }
        storage.endEditing()
    }

    /// Read the paragraph kind recorded at a location, defaulting to `.paragraph`.
    static func paragraphKind(in storage: NSTextStorage, at location: Int) -> ParagraphKind {
        guard storage.length > 0 else { return .paragraph }
        let loc = min(max(location, 0), storage.length - 1)
        return (storage.attribute(.paragraphKind, at: loc, effectiveRange: nil) as? ParagraphKind) ?? .paragraph
    }
}
