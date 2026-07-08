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
    /// Cache of the per-kind typing attributes — constant per kind; rebuilt
    /// paragraph styles on every call would be wasted work. Main-thread only.
    private static var typingAttributesCache: [BlockKind: [NSAttributedString.Key: Any]] = [:]

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
            para.lineSpacing = 6
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
}

// MARK: - Auto-sizing NSTextView with placeholder + inline-format toggles

class AutoSizingTextView: NSTextView {
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
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            // One rounded rect per line fragment the run spans.
            lm.enumerateEnclosingRects(forGlyphRange: glyphRange,
                                       withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: tc) { r, _ in
                var box = r.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -inset, dy: 0)
                // Keep the fill within the paragraph's text block.
                if box.minX < blockLeft {
                    box.size.width -= (blockLeft - box.minX)
                    box.origin.x = blockLeft
                }
                // Center a text-height pill within the line fragment.
                box.origin.y += (box.height - textHeight) / 2
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
