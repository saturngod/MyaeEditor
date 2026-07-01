//
//  BlockTextView.swift
//  MyaeEditor
//
//  An NSTextView wrapper that gives us the key handling SwiftUI's TextEditor
//  cannot: backspace-at-start, caret-position awareness, arrow navigation
//  between blocks, auto-sizing height, and inline rich text (Cmd+B / Cmd+I).
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
    static var background: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.12) }
    static func font(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }

    static func attributes(size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.inlineCode: true, .font: font(size: size), .backgroundColor: background, .foregroundColor: color]
    }
}

struct BlockTextView: NSViewRepresentable {
    @Binding var text: NSAttributedString
    let kind: BlockKind
    var language: CodeLanguage = .swift

    var isFocused: Bool
    var focusAtStart: Bool
    /// One-shot caret location to apply when this view gains focus (e.g. after a merge).
    var pendingCaretLocation: Int?
    /// Shared controller for the floating format toolbar.
    var formatBar: FormatBarController

    // Callbacks. Each returns `true` if it consumed the event.
    var onEnter: () -> Bool
    var onShiftEnter: () -> Bool
    var onBackspaceAtStart: () -> Bool
    var onArrowUpAtTop: () -> Bool
    var onArrowDownAtBottom: () -> Bool
    var onTab: () -> Bool
    var onShiftTab: () -> Bool
    var onSlash: () -> Void
    var onFocused: () -> Void
    /// Cmd+A pressed while the block's text is already fully selected (or empty):
    /// escalate to selecting all blocks.
    var onSelectAllBlocks: () -> Void
    var onCaretApplied: () -> Void
    /// Called once the focus request has been applied, so the document can clear
    /// its one-shot `focusAtStart` flag.
    var onFocusApplied: () -> Void
    /// Double-click landed on an inline math attachment: (its range, its LaTeX).
    var onEditMath: (NSRange, String) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> AutoSizingTextView {
        let tv = AutoSizingTextView()
        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.font = kind.baseFont
        tv.typingAttributes = Self.typingAttributes(for: kind)
        tv.coordinator = context.coordinator
        tv.placeholder = kind.placeholder
        tv.textStorage?.setAttributedString(text)
        if kind == .code, let storage = tv.textStorage {
            SyntaxHighlighter.highlight(storage, language: language, font: kind.baseFont)
            context.coordinator.lastLanguage = language
        }
        // Stop the text view from intercepting block-reorder drags so they fall
        // through to SwiftUI's drop targets behind it.
        tv.unregisterDraggedTypes()
        return tv
    }

    func updateNSView(_ tv: AutoSizingTextView, context: Context) {
        context.coordinator.parent = self

        // Sync text only when it differs, to avoid clobbering the caret while typing.
        let textChanged = !tv.textStorage!.isEqual(to: text)
        if textChanged {
            let sel = tv.selectedRange()
            tv.textStorage?.setAttributedString(text)
            tv.setSelectedRange(NSRange(location: min(sel.location, text.length), length: 0))
            tv.invalidateIntrinsicContentSize()
        }
        tv.typingAttributes = Self.typingAttributes(for: kind)
        tv.placeholder = kind.placeholder
        let kindChanged = context.coordinator.lastKind != kind
        context.coordinator.lastKind = kind
        if textChanged || kindChanged { tv.needsDisplay = true }

        // Highlight code blocks after any external text sync or language change.
        // (The text binding may still hold the un-colored string, so re-applying
        //  here is what makes the very first paint show colors.)
        if kind == .code, let storage = tv.textStorage {
            let languageChanged = context.coordinator.lastLanguage != language
            if textChanged || languageChanged {
                context.coordinator.lastLanguage = language
                SyntaxHighlighter.highlight(storage, language: language, font: kind.baseFont)
                let highlighted = NSAttributedString(attributedString: storage)
                if !highlighted.isEqual(to: text) {
                    DispatchQueue.main.async { [weak tv] in
                        // Only push the highlighted copy back if the user hasn't
                        // edited since this was scheduled — otherwise this stale
                        // snapshot would clobber the newer text they just typed.
                        guard let tv, tv.textStorage?.isEqual(to: highlighted) == true else { return }
                        text = highlighted
                    }
                }
            }
        }

        // Focus management. NSRange is in UTF-16 units, so use NSString.length —
        // not String.count (graphemes) — or the caret misplaces around emoji.
        if isFocused {
            if tv.window?.firstResponder !== tv {
                context.coordinator.pendingFocusWork?.cancel()
                let caret = pendingCaretLocation
                let atStart = focusAtStart
                let onCaret = onCaretApplied
                let onFocus = onFocusApplied
                let work = DispatchWorkItem { [weak tv] in
                    guard let tv else { return }
                    tv.window?.makeFirstResponder(tv)
                    let length = (tv.string as NSString).length
                    if let loc = caret {
                        tv.setSelectedRange(NSRange(location: min(loc, length), length: 0))
                        onCaret()
                    } else if atStart {
                        tv.setSelectedRange(NSRange(location: 0, length: 0))
                    } else {
                        tv.setSelectedRange(NSRange(location: length, length: 0))
                    }
                    onFocus()
                }
                context.coordinator.pendingFocusWork = work
                DispatchQueue.main.async(execute: work)
            }
        }
    }

    static func typingAttributes(for kind: BlockKind) -> [NSAttributedString.Key: Any] {
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
        return [
            .font: kind.baseFont,
            .foregroundColor: color,
            .paragraphStyle: para,
        ]
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BlockTextView
        var lastLanguage: CodeLanguage?
        var lastKind: BlockKind?
        fileprivate var pendingFocusWork: DispatchWorkItem?
        /// Guards re-entrancy while the inline-code transform edits the storage.
        private var applyingInlineCode = false
        init(_ parent: BlockTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? AutoSizingTextView else { return }
            // Recolor only the edited line(s) — O(line) per keystroke instead of
            // rescanning the whole storage. `editedRange` reflects the just-applied
            // edit; SyntaxHighlighter falls back to a full pass when the change
            // could affect coloring elsewhere (e.g. a block-comment delimiter).
            if parent.kind == .code, let storage = tv.textStorage {
                SyntaxHighlighter.highlight(storage, language: parent.language,
                                            font: parent.kind.baseFont, editedRange: storage.editedRange)
            } else {
                applyInlineCodeIfClosed(tv)   // `code` typed → style it
            }
            // attributedString() already returns an immutable snapshot copy of the
            // storage; no need to wrap it in another NSAttributedString copy.
            parent.text = tv.attributedString()
            tv.invalidateIntrinsicContentSize()

            // Slash command: opens when a "/" was just typed at the caret — works
            // mid-line (e.g. "Hello/") so inline math can be inserted anywhere.
            let sel = tv.selectedRange()
            let ns = tv.string as NSString
            if parent.kind != .code, sel.length == 0, sel.location > 0, sel.location <= ns.length,
               ns.substring(with: NSRange(location: sel.location - 1, length: 1)) == "/" {
                parent.onSlash()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? AutoSizingTextView else { return }
            updateFormatBar(tv)
        }

        /// When the user just typed a closing backtick and there's an opener earlier
        /// on the same line, turn the enclosed text into inline code and drop both
        /// backticks — the `` `type this` `` inline-code shortcut.
        private func applyInlineCodeIfClosed(_ tv: AutoSizingTextView) {
            guard !applyingInlineCode, let storage = tv.textStorage else { return }
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            guard sel.length == 0, sel.location >= 2, sel.location <= ns.length,
                  ns.character(at: sel.location - 1) == 96 else { return }   // 96 = `
            let closeIdx = sel.location - 1

            // Nearest earlier backtick on the same line is the opener.
            let line = ns.lineRange(for: NSRange(location: closeIdx, length: 0))
            var openIdx = -1
            var k = closeIdx - 1
            while k >= line.location {
                if ns.character(at: k) == 96 { openIdx = k; break }
                k -= 1
            }
            guard openIdx >= 0, closeIdx - openIdx >= 2 else { return }   // need ≥1 char between

            let content = ns.substring(with: NSRange(location: openIdx + 1, length: closeIdx - openIdx - 1))
            let fullSpan = NSRange(location: openIdx, length: closeIdx - openIdx + 1)
            guard tv.shouldChangeText(in: fullSpan, replacementString: content) else { return }

            let color: NSColor = parent.kind == .quote ? .secondaryLabelColor : .textColor
            let size = (tv.font ?? NSFont.systemFont(ofSize: 16)).pointSize
            let styled = NSAttributedString(string: content,
                                            attributes: InlineCode.attributes(size: size, color: color))
            applyingInlineCode = true
            storage.replaceCharacters(in: fullSpan, with: styled)
            tv.didChangeText()
            applyingInlineCode = false
            tv.setSelectedRange(NSRange(location: openIdx + styled.length, length: 0))
            // Stop the code styling from continuing as the user keeps typing.
            tv.typingAttributes = BlockTextView.typingAttributes(for: parent.kind)
        }

        /// Show the floating format bar above a non-empty selection; hide otherwise.
        func updateFormatBar(_ tv: AutoSizingTextView) {
            let range = tv.selectedRange()
            // Only for real selections in formattable text, while this view is focused.
            guard range.length > 0, parent.kind != .code,
                  tv.window?.firstResponder === tv,
                  let lm = tv.layoutManager, let tc = tv.textContainer else {
                parent.formatBar.hide()
                return
            }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            let origin = tv.textContainerOrigin
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            let windowRect = tv.convert(rect, to: nil)
            guard let screenRect = tv.window?.convertToScreen(windowRect) else {
                parent.formatBar.hide()
                return
            }
            parent.formatBar.show(textView: tv, atScreenRect: screenRect)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false

            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if shift { return parent.onShiftEnter() }
                return parent.onEnter()

            case #selector(NSResponder.deleteBackward(_:)):
                let r = textView.selectedRange()
                if r.location == 0 && r.length == 0 {
                    return parent.onBackspaceAtStart()
                }
                return false

            case #selector(NSResponder.moveUp(_:)):
                if (textView as? AutoSizingTextView)?.caretIsOnFirstLine() == true {
                    return parent.onArrowUpAtTop()
                }
                return false

            case #selector(NSResponder.moveDown(_:)):
                if (textView as? AutoSizingTextView)?.caretIsOnLastLine() == true {
                    return parent.onArrowDownAtBottom()
                }
                return false

            case #selector(NSResponder.insertTab(_:)):
                // In code, Tab inserts spaces at the caret instead of re-parenting.
                if parent.kind == .code {
                    textView.insertText("    ", replacementRange: textView.selectedRange())
                    return true
                }
                return parent.onTab()

            case #selector(NSResponder.insertBacktab(_:)):
                if parent.kind == .code {
                    return dedentCodeLine(textView)
                }
                return parent.onShiftTab()

            default:
                return false
            }
        }

        /// Remove up to 4 leading spaces (or one tab) from the caret's line.
        private func dedentCodeLine(_ tv: NSTextView) -> Bool {
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            var remove = 0
            var idx = lineRange.location
            while remove < 4 && idx < ns.length {
                let c = ns.character(at: idx)
                if c == 32 { remove += 1; idx += 1 }                // space
                else if c == 9 && remove == 0 { remove = 1; break } // a single tab
                else { break }
            }
            guard remove > 0 else { return true }
            let delRange = NSRange(location: lineRange.location, length: remove)
            if tv.shouldChangeText(in: delRange, replacementString: "") {
                tv.textStorage?.replaceCharacters(in: delRange, with: "")
                tv.didChangeText()
                let newCaret = max(lineRange.location, sel.location - remove)
                tv.setSelectedRange(NSRange(location: newCaret, length: 0))
            }
            return true
        }
    }
}

// MARK: - Auto-sizing NSTextView with placeholder

final class AutoSizingTextView: NSTextView {
    weak var coordinator: BlockTextView.Coordinator?
    var placeholder: String = ""

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

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
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
        let loc = selectedRange().location
        let len = (string as NSString).length
        if loc >= len { return true }
        let caretRect = lm.boundingRect(forGlyphRange: NSRange(location: loc, length: 0), in: tc)
        let lastRect = lm.boundingRect(forGlyphRange: NSRange(location: max(len - 1, 0), length: 0), in: tc)
        return abs(caretRect.minY - lastRect.minY) < 1
    }

    // Double-click on an inline math attachment opens its editor.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2,
           let lm = layoutManager, let tc = textContainer, let storage = textStorage {
            let point = convert(event.locationInWindow, from: nil)
            let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            let idx = lm.characterIndex(for: p, in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
            if idx < storage.length,
               let math = storage.attribute(.attachment, at: idx, effectiveRange: nil) as? MathAttachment {
                coordinator?.parent.onEditMath(NSRange(location: idx, length: 1), math.latex)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { coordinator?.parent.onFocused() }
        needsDisplay = true   // show placeholder on focus
        return ok
    }

    // Cmd+A: first press selects the block's text (default). A second press —
    // i.e. the text is already fully selected, or the block is empty — escalates
    // to a whole-document, block-level selection.
    override func selectAll(_ sender: Any?) {
        let length = (string as NSString).length
        let allSelected = selectedRange() == NSRange(location: 0, length: length)
        if length == 0 || allSelected {
            coordinator?.parent.onSelectAllBlocks()
            window?.makeFirstResponder(nil)   // drop text caret so block selection shows alone
        } else {
            super.selectAll(sender)
        }
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        needsDisplay = true   // hide placeholder on blur
        coordinator?.parent.formatBar.hide()
        return ok
    }

    // MARK: Inline formatting (bold / italic / strikethrough over the selection)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           selectedRange().length > 0,
           let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "b": toggleFontTrait(.boldFontMask); coordinator?.parent.formatBar.refreshTraits(for: self); return true
            case "i": toggleFontTrait(.italicFontMask); coordinator?.parent.formatBar.refreshTraits(for: self); return true
            case "e": toggleInlineCode(); coordinator?.parent.formatBar.refreshTraits(for: self); return true
            default: break
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

    /// Toggle inline code over the selection: monospaced font + subtle background,
    /// tagged with `.inlineCode`. Removing it restores the block's base font.
    func toggleInlineCode() {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return }
        let adding = !rangeHasInlineCode(range)
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        let base = font ?? NSFont.systemFont(ofSize: 16)
        storage.beginEditing()
        if adding {
            storage.addAttribute(.inlineCode, value: true, range: range)
            storage.addAttribute(.font, value: InlineCode.font(size: base.pointSize), range: range)
            storage.addAttribute(.backgroundColor, value: InlineCode.background, range: range)
        } else {
            storage.removeAttribute(.inlineCode, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
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

    // Draw the placeholder only on the focused empty block.
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
