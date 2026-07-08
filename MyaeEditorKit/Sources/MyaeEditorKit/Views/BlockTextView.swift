//
//  BlockTextView.swift
//  MyaeEditor
//
//  Shared text-editing foundation: the per-kind typing attributes, the inline-
//  code styling constants, and `AutoSizingTextView` — the NSTextView base class
//  (auto-height, placeholder, bold/italic/strike/inline-code toggles) that the
//  segment editor, code blocks, and table cells all build on.
//

import SwiftUI
import AppKit

extension NSAttributedString.Key {
    /// Marks a run as inline code (`` `like this` ``). Carried alongside a
    /// monospaced font + background so encode/decode and the toggle all agree.
    static let inlineCode = NSAttributedString.Key("inlineCode")
}

/// Shared styling for inline code so the text view, encoder, and decoder produce
/// identical runs.
enum InlineCode {
    /// Fill and hairline stroke behind an inline-code run. Drawn as a rounded
    /// "pill" by `AutoSizingTextView` — NOT a flat `.backgroundColor` attribute,
    /// which paints a tight, edge-to-edge highlight that reads as unprofessional.
    static var fill: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.06) }
    static var stroke: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.10) }
    /// Padding drawn on each side of the run's glyphs, and the corner radius. The
    /// pill hugs the code glyphs; the natural spaces around inline code supply the
    /// gap to neighboring words, so no layout space is reserved in the model.
    static let hPadding: CGFloat = 2
    static let cornerRadius: CGFloat = 4
    static func font(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }

    static func attributes(size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.inlineCode: true, .font: font(size: size), .foregroundColor: color]
    }
}

/// Namespace for the per-kind typing attributes (font, color, paragraph style).
/// Kept under the historical name because call sites throughout the package use
/// `BlockTextView.typingAttributes(for:)`.
enum BlockTextView {
    /// Line spacing shared by every paragraph kind that isn't a heading/code (which
    /// use `lineHeightMultiple` instead) — the default case below, and table cells
    /// (`TableCellTextView.cellParagraphStyle`), which have no `BlockKind` of their
    /// own but should read the same as a wrapped paragraph.
    static let paragraphLineSpacing: CGFloat = 10

    /// Cache of the per-kind typing attributes — constant per kind; rebuilt
    /// paragraph styles on every call would be wasted work. Main-thread only.
    private static var typingAttributesCache: [BlockKind: [NSAttributedString.Key: Any]] = [:]
    /// Cache of `centeringShift(for:)`, keyed separately from `typingAttributesCache`
    /// since it's read once per drawn marker/pill and shouldn't re-cast the
    /// paragraph style out of the attributes dictionary every time.
    private static var centeringShiftCache: [BlockKind: CGFloat] = [:]

    static func typingAttributes(for kind: BlockKind) -> [NSAttributedString.Key: Any] {
        if let cached = typingAttributesCache[kind] { return cached }
        let para = NSMutableParagraphStyle()
        switch kind {
        case .heading1:
            para.lineHeightMultiple = 1.2
            para.paragraphSpacingBefore = 16
            para.paragraphSpacing = 4
        case .heading2:
            para.lineHeightMultiple = 1.25
            para.paragraphSpacingBefore = 12
            para.paragraphSpacing = 4
        case .heading3:
            para.lineHeightMultiple = 1.3
            para.paragraphSpacingBefore = 8
            para.paragraphSpacing = 2
        case .heading4, .heading5, .heading6:
            para.lineHeightMultiple = 1.3
            para.paragraphSpacingBefore = 6
            para.paragraphSpacing = 2
        case .code:
            para.lineHeightMultiple = 1.45
        case .quote:
            // Space wrapped lines apart without pushing the first line down —
            // keeps the quote bar aligned with the first line's top.
            para.lineSpacing = 6
            para.paragraphSpacingBefore = 2
            para.paragraphSpacing = 2
        default:
            // lineSpacing (gap *between* lines) instead of lineHeightMultiple
            // (which adds leading *above* the first line and would drop the text
            // below its list bullet / checkbox). This keeps markers aligned.
            para.lineSpacing = paragraphLineSpacing
            para.paragraphSpacing = 2
        }
        var color: NSColor = .textColor
        if kind == .quote { color = .secondaryLabelColor }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: kind.baseFont,
            .foregroundColor: color,
            .paragraphStyle: para,
        ]
        typingAttributesCache[kind] = attrs
        return attrs
    }

    /// Half of a paragraph's `lineSpacing` — the amount its glyphs are nudged down
    /// so they sit centered in the (taller) line instead of pinned to the top.
    /// Marker/pill drawing adds this back because they measure from the unshifted
    /// layout rects. Zero for kinds that don't use `lineSpacing` (headings/code).
    static func centeringShift(for kind: BlockKind) -> CGFloat {
        if let cached = centeringShiftCache[kind] { return cached }
        let para = typingAttributes(for: kind)[.paragraphStyle] as? NSParagraphStyle
        let shift = (para?.lineSpacing ?? 0) / 2
        centeringShiftCache[kind] = shift
        return shift
    }
}

// MARK: - Auto-sizing NSTextView with placeholder + inline-format toggles

class AutoSizingTextView: NSTextView, NSLayoutManagerDelegate {
    var placeholder: String = ""
    /// When set, this is the font inline-code removal restores to (instead of
    /// `restoreBaseFont()`'s default). Table cells set it because they have no
    /// paragraph kind.
    var baseFontOverride: NSFont?

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 24)
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).size
        let height = ceil(used.height) + textContainerInset.height * 2
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 24))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    /// Width at the last intrinsic-size invalidation. Height depends only on the
    /// wrapping width, so re-measure only when the width moves.
    private var lastLaidOutWidth: CGFloat = -1

    override func layout() {
        super.layout()
        let width = bounds.width
        if width != lastLaidOutWidth {
            lastLaidOutWidth = width
            invalidateIntrinsicContentSize()
        }
    }

    // MARK: Inline-code background

    /// Draw rounded "pill" backgrounds behind every `.inlineCode` run, before the
    /// glyphs are drawn. This replaces the flat `.backgroundColor` attribute so
    /// inline code reads like GitHub's: padded, softly filled, hairline border.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawInlineCodeBackgrounds(in: rect)
    }

    private func drawInlineCodeBackgrounds(in clip: NSRect) {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage,
              storage.length > 0 else { return }
        // Only scan the characters actually on screen — a caret blink or a scroll
        // frame repaints a tiny region, so enumerating the whole storage would be
        // wasted work in a large segment.
        let visibleGlyphs = lm.glyphRange(forBoundingRect: clip, in: tc)
        guard visibleGlyphs.length > 0 else { return }
        let visibleChars = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let origin = textContainerOrigin
        let inset = InlineCode.hPadding
        let radius = InlineCode.cornerRadius

        storage.enumerateAttribute(.inlineCode, in: visibleChars) { value, range, _ in
            guard (value as? Bool) == true, range.length > 0 else { return }
            let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
                        ?? InlineCode.font(size: 16)
            // Pill hugs the text height (ascender→descender + 1pt), NOT the full
            // line-fragment height — otherwise stacked lines' pills overlap.
            let textHeight = ceil(font.ascender - font.descender) + 2
            // Left edge of the paragraph's text block. On a wrapped line a run can
            // start here, and the pill's left padding must not spill into the list
            // indent — clamp it to this edge.
            let para = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let blockLeft = origin.x + tc.lineFragmentPadding + (para?.headIndent ?? 0)
            // Glyphs are nudged down by half the line spacing to center them (see the
            // layout-manager delegate); the pill measures from the unshifted used
            // rect, so add the same shift to stay glued to the code.
            let centeringShift = (para?.lineSpacing ?? 0) / 2
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            // One rounded rect per line fragment the run spans. Walk line fragments
            // (not `enumerateEnclosingRects`, whose selection-style rects include the
            // paragraph's trailing `lineSpacing` and would drag the pill off-glyph as
            // line spacing grows) and take each fragment's tight `usedRect` for the
            // vertical extent, with the run's own glyphs for the horizontal extent.
            // The text's real line height, WITHOUT the paragraph's trailing
            // `lineSpacing` — the used rect includes that spacing below the glyphs,
            // so centering in it would push the pill down as line spacing grows.
            let lineHeight = lm.defaultLineHeight(for: font)
            lm.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, effectiveGlyphRange, _ in
                let lineGlyphRange = NSIntersectionRange(effectiveGlyphRange, glyphRange)
                guard lineGlyphRange.length > 0 else { return }
                let horizontal = lm.boundingRect(forGlyphRange: lineGlyphRange, in: tc)
                var box = NSRect(x: horizontal.minX, y: usedRect.minY, width: horizontal.width, height: lineHeight)
                box = box.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -inset, dy: 0)
                // Keep the fill within the paragraph's text block.
                if box.minX < blockLeft {
                    box.size.width -= (blockLeft - box.minX)
                    box.origin.x = blockLeft
                }
                // Center a text-height pill within the glyphs' line height, then drop
                // it to match the centered glyphs.
                box.origin.y += (box.height - textHeight) / 2 + centeringShift
                box.size.height = textHeight
                guard box.intersects(clip) else { return }
                let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
                InlineCode.fill.setFill()
                path.fill()
                InlineCode.stroke.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    func caretIsOnFirstLine() -> Bool {
        guard let lm = layoutManager, let tc = textContainer else { return true }
        let loc = selectedRange().location
        if loc == 0 { return true }
        let caretRect = lm.boundingRect(forGlyphRange: NSRange(location: loc, length: 0), in: tc)
        let firstRect = lm.boundingRect(forGlyphRange: NSRange(location: 0, length: 0), in: tc)
        return abs(caretRect.minY - firstRect.minY) < 1
    }

    func caretIsOnLastLine() -> Bool {
        guard let lm = layoutManager, let tc = textContainer else { return true }
        // Down-arrow collapses a selection to its END, so test that edge (not the
        // selection's start) — otherwise a multi-line selection reports the wrong line.
        let sel = selectedRange()
        let loc = sel.location + sel.length
        let len = (string as NSString).length
        if loc >= len { return true }
        let caretRect = lm.boundingRect(forGlyphRange: NSRange(location: loc, length: 0), in: tc)
        let lastRect = lm.boundingRect(forGlyphRange: NSRange(location: max(len - 1, 0), length: 0), in: tc)
        return abs(caretRect.minY - lastRect.minY) < 1
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true   // show placeholder on focus
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        needsDisplay = true   // hide placeholder on blur
        return ok
    }

    // MARK: Vertical centering within line spacing

    /// `SegmentTextView`/`TableCellTextView` (the SwiftUI-representable-backed
    /// views) wire `layoutManager?.delegate` up front in `makeNSView`, before the
    /// first layout pass — the `lm.delegate !== self` guard below then makes this a
    /// no-op for them. This is the fallback for any other `AutoSizingTextView`
    /// subclass (e.g. `CodeNSTextView`) that doesn't set it explicitly at creation.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let lm = layoutManager, lm.delegate !== self else { return }
        lm.delegate = self
        lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0),
                            actualCharacterRange: nil)
    }

    /// Drop each glyph line by half its paragraph's `lineSpacing`. AppKit piles that
    /// spacing *below* the glyphs, pinning text to the top of the (tall) line and
    /// making it read as top-aligned against the full-height caret. Nudging only the
    /// baseline centers the drawn text within the line — and within the caret —
    /// while leaving every layout metric (so the caret keeps its width, height, and
    /// top position, with no erase artifacts). List markers and inline-code pills
    /// compensate with the same shift when they draw. Only lines that set
    /// `lineSpacing` are touched; headings/code use `lineHeightMultiple`.
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = layoutManager.textStorage, storage.length > 0,
              glyphRange.location != NSNotFound else { return false }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        guard charIndex != NSNotFound else { return false }
        let idx = min(max(charIndex, 0), storage.length - 1)
        guard let para = storage.attribute(.paragraphStyle, at: idx, effectiveRange: nil) as? NSParagraphStyle,
              para.lineSpacing > 0 else { return false }
        baselineOffset.pointee += para.lineSpacing / 2
        return true
    }

    // MARK: Paste

    /// Default paste is the literal pasteboard string (newlines normalized);
    /// subclasses with a markdown model override `paste` for richer behavior.
    override func paste(_ sender: Any?) { pasteLiteral() }
    override func pasteAsPlainText(_ sender: Any?) { pasteLiteral() }

    /// The pasteboard string inserted verbatim (newlines normalized), no parsing.
    func pasteLiteral() {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let s = raw.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")
        insertText(NSAttributedString(string: s, attributes: typingAttributes),
                   replacementRange: selectedRange())
    }

    // MARK: Inline formatting (bold / italic / strikethrough / code)

    /// Hook called after a Cmd-key formatting toggle so subclasses can refresh
    /// their format bar's button state.
    func formatDidChange() {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Cmd+Shift+V: paste as plain literal text. Not gated on a selection so
        // it works with a collapsed caret too.
        if mods == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "v" {
            pasteLiteral()
            return true
        }
        if selectedRange().length > 0, let chars = event.charactersIgnoringModifiers?.lowercased() {
            if mods == .command {
                switch chars {
                case "b": toggleFontTrait(.boldFontMask); formatDidChange(); return true
                case "i": toggleFontTrait(.italicFontMask); formatDidChange(); return true
                case "e": toggleInlineCode(); formatDidChange(); return true
                default: break
                }
            } else if mods == [.command, .shift], chars == "s" {
                toggleStrikethrough(); formatDidChange(); return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Toggle a font trait across the selection. Adds the trait unless every run
    /// already has it, in which case it removes it.
    func toggleFontTrait(_ trait: NSFontTraitMask) {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return }
        let adding = !rangeHasTrait(trait, in: range)
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let f = (value as? NSFont) ?? self.font ?? NSFont.systemFont(ofSize: 16)
            let nf = adding ? NSFontManager.shared.convert(f, toHaveTrait: trait)
                            : NSFontManager.shared.convert(f, toNotHaveTrait: trait)
            storage.addAttribute(.font, value: nf, range: sub)
        }
        storage.endEditing()
        didChangeText()
        setSelectedRange(range)
    }

    func toggleStrikethrough() {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return }
        let adding = !rangeHasStrikethrough(range)
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        if adding {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        } else {
            storage.removeAttribute(.strikethroughStyle, range: range)
        }
        storage.endEditing()
        didChangeText()
        setSelectedRange(range)
    }

    func rangeHasTrait(_ trait: NSFontTraitMask, in range: NSRange) -> Bool {
        guard range.length > 0, let storage = textStorage else { return false }
        var all = true
        storage.enumerateAttribute(.font, in: range) { value, _, stop in
            let traits = (value as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            if !traits.contains(trait) { all = false; stop.pointee = true }
        }
        return all
    }

    func rangeHasStrikethrough(_ range: NSRange) -> Bool {
        guard range.length > 0, let storage = textStorage else { return false }
        var all = true
        storage.enumerateAttribute(.strikethroughStyle, in: range) { value, _, stop in
            if (value as? Int ?? 0) == 0 { all = false; stop.pointee = true }
        }
        return all
    }

    /// The font that removing inline code restores. Subclasses with a paragraph
    /// model override this to answer from the caret's paragraph kind.
    func inlineCodeRestoreFont() -> NSFont {
        baseFontOverride ?? font ?? NSFont.systemFont(ofSize: 16)
    }

    /// Toggle inline code over the selection: monospaced font + subtle background,
    /// tagged with `.inlineCode`. Removing it restores the base font.
    func toggleInlineCode() {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return }
        let adding = !rangeHasInlineCode(range)
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        let base = inlineCodeRestoreFont()
        storage.beginEditing()
        if adding {
            storage.addAttribute(.inlineCode, value: true, range: range)
            storage.addAttribute(.font, value: InlineCode.font(size: base.pointSize), range: range)
        } else {
            storage.removeAttribute(.inlineCode, range: range)
            storage.addAttribute(.font, value: base, range: range)
        }
        storage.endEditing()
        didChangeText()
        setSelectedRange(range)
    }

    func rangeHasInlineCode(_ range: NSRange) -> Bool {
        guard range.length > 0, let storage = textStorage else { return false }
        var all = true
        storage.enumerateAttribute(.inlineCode, in: range) { value, _, stop in
            if (value as? Bool) != true { all = false; stop.pointee = true }
        }
        return all
    }

    // Draw the placeholder only on the focused empty view.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty,
              window?.firstResponder === self else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let point = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                            y: textContainerInset.height)
        placeholder.draw(at: point, withAttributes: attrs)
    }
}
