//
//  CenteringLayoutManager.swift
//  MyaeEditor
//
//  TextKit 1 layout manager that gives every line fragment a *fixed* height
//  derived from its paragraph kind's base font (kind.baseFont ×
//  lineHeightMultiple), and centers the glyph baseline inside that fragment.
//
//  Two things fall out of pinning the geometry here instead of via text
//  attributes:
//  - The caret is vertically centered for free: AppKit derives the insertion
//    point from the line fragment rect + baseline this class reports, so a
//    centered baseline means a centered caret.
//  - Line height is immune to fallback fonts: Myanmar/CJK runs substitute
//    taller fonts, but the height is always computed from the paragraph's
//    *base* font, so lines (and the caret) never jump between scripts.
//

import AppKit

final class CenteringLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    /// When set (table cells), every fragment uses this font with
    /// `overrideMultiple` instead of reading `.paragraphKind` — a cell has a
    /// single style and its storage carries no kind attribute.
    var overrideFont: NSFont? {
        didSet {
            guard overrideFont !== oldValue else { return }
            invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0),
                             actualCharacterRange: nil)
        }
    }
    var overrideMultiple: CGFloat = 1.5

    /// Fixed fragment height per kind — constant per kind, cached.
    private var fixedHeightCache: [BlockKind: CGFloat] = [:]

    private func fixedLineHeight(for kind: BlockKind) -> CGFloat {
        if let cached = fixedHeightCache[kind] { return cached }
        let h = ceil(BlockTextView.lineHeightMultiple(for: kind) * defaultLineHeight(for: kind.baseFont))
        fixedHeightCache[kind] = h
        return h
    }

    /// Drop cached fixed line heights (they derive from `kind.baseFont`) and force
    /// a relayout, so the next layout re-measures against the editor's new fonts.
    func invalidateFixedHeights() {
        fixedHeightCache.removeAll()
        invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0),
                         actualCharacterRange: nil)
    }

    /// The base font + fixed fragment height governing the line whose first
    /// character is at `charIndex` (nil → the typing kind / override).
    private func lineMetrics(forCharacterAt charIndex: Int?) -> (font: NSFont, fixed: CGFloat) {
        if let font = overrideFont {
            return (font, ceil(overrideMultiple * defaultLineHeight(for: font)))
        }
        let kind: BlockKind
        if let i = charIndex, let storage = textStorage, i < storage.length {
            kind = ((storage.attribute(.paragraphKind, at: i, effectiveRange: nil)
                     as? ParagraphKind) ?? .paragraph).kind
        } else {
            kind = (firstTextView?.typingAttributes[.paragraphKind] as? ParagraphKind)?.kind ?? .paragraph
        }
        return (kind.baseFont, fixedLineHeight(for: kind))
    }

    // MARK: NSLayoutManagerDelegate

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let charRange = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard charRange.location < storage.length else { return false }

        // A line carrying an attachment (inline math image) can be genuinely
        // taller than the fixed height — leave those lines to default layout
        // rather than clipping the attachment.
        if storage.containsAttachments(in: charRange) { return false }

        let (font, fixed) = lineMetrics(forCharacterAt: charRange.location)
        let fontLine = defaultLineHeight(for: font)

        // Preserve inter-paragraph spacing: paragraphSpacingBefore belongs to a
        // paragraph's first fragment, paragraphSpacing to the fragment holding
        // its trailing newline. Both live *inside* the fragment rect in TextKit 1,
        // so forcing the height must re-add them.
        let para = storage.attribute(.paragraphStyle, at: charRange.location,
                                     effectiveRange: nil) as? NSParagraphStyle
        let nsStr = storage.string as NSString
        let paraRange = nsStr.paragraphRange(for: charRange)
        var before: CGFloat = 0
        var after: CGFloat = 0
        if charRange.location == paraRange.location, paraRange.location > 0 {
            before = para?.paragraphSpacingBefore ?? 0
        }
        if NSMaxRange(charRange) == NSMaxRange(paraRange), paraRange.length > 0,
           nsStr.character(at: NSMaxRange(paraRange) - 1) == 10 {
            after = para?.paragraphSpacing ?? 0
        }

        var rect = lineFragmentRect.pointee
        rect.size.height = before + fixed + after
        lineFragmentRect.pointee = rect

        var used = lineFragmentUsedRect.pointee
        used.origin.y = rect.origin.y + before
        used.size.height = fixed
        lineFragmentUsedRect.pointee = used

        // Baseline measured from the fragment top: center the base font's
        // ascender→descender box inside the fixed slice.
        baselineOffset.pointee = before + (fixed - fontLine) / 2 + font.ascender

        return true
    }

    /// The empty last line (or an entirely empty document) has no glyphs, so the
    /// delegate above never sees it — pin its height here so the caret on a
    /// trailing empty paragraph matches its neighbors.
    override func setExtraLineFragmentRect(_ fragmentRect: NSRect, usedRect: NSRect,
                                           textContainer container: NSTextContainer) {
        let (_, fixed) = lineMetrics(forCharacterAt: nil)
        var rect = fragmentRect
        rect.size.height = fixed
        var used = usedRect
        used.size.height = fixed
        super.setExtraLineFragmentRect(rect, usedRect: used, textContainer: container)
    }
}
