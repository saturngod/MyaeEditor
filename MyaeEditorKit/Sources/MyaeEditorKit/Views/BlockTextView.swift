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

extension NSAttributedString {
    /// Re-target this text to `kind`'s base font, preserving bold/italic traits,
    /// strikethrough, inline-code runs (kept monospaced at the new point size),
    /// and inline-math attachments. Applies the kind's foreground color and
    /// paragraph style. Used when pasting a paragraph into a block of another
    /// kind (`parseInline` produces paragraph-styled text with no paragraph
    /// style attribute, which would otherwise render with inconsistent spacing).
    func restyled(to kind: BlockKind) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: self)
        let full = NSRange(location: 0, length: mutable.length)
        let base = kind.baseFont
        let color: NSColor = (kind == .quote) ? .secondaryLabelColor : .textColor
        mutable.enumerateAttributes(in: full) { attrs, range, _ in
            // Inline-code runs keep the monospaced font at the new point size.
            if (attrs[.inlineCode] as? Bool) == true {
                mutable.addAttribute(.font, value: InlineCode.font(size: base.pointSize), range: range)
                mutable.addAttribute(.foregroundColor, value: color, range: range)
                return
            }
            // Inline-math attachments carry their own rendering; leave untouched.
            if attrs[.attachment] is MathAttachment { return }
            let traits = (attrs[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            var newFont = base
            if traits.contains(.boldFontMask) {
                newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .boldFontMask)
            }
            if traits.contains(.italicFontMask) {
                newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .italicFontMask)
            }
            mutable.addAttribute(.font, value: newFont, range: range)
            mutable.addAttribute(.foregroundColor, value: color, range: range)
        }
        if let para = BlockTextView.typingAttributes(for: kind)[.paragraphStyle] {
            mutable.addAttribute(.paragraphStyle, value: para, range: full)
        }
        return mutable
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

    /// Whether the text is editable (read-only viewer when false).
    var isEditable: Bool = true
    /// Whether the floating format bar may appear on selection.
    var showsFormatBar: Bool = true

    // Callbacks. Each returns `true` if it consumed the event.
    /// Enter pressed. Args: text before the caret, text after the caret (any
    /// selection excluded). The row splits the block: `before` stays, `after`
    /// moves to the new block.
    var onEnter: (_ before: NSAttributedString, _ after: NSAttributedString) -> Bool
    var onShiftEnter: () -> Bool
    var onBackspaceAtStart: () -> Bool
    var onArrowUpAtTop: () -> Bool
    var onArrowDownAtBottom: () -> Bool
    /// Shift+Up on the first line / Shift+Down on the last line: escalate to a
    /// block-level selection that includes the neighbour block. Return true to
    /// consume the key (else the text view extends its own text selection).
    var onExtendSelectionUp: () -> Bool = { false }
    var onExtendSelectionDown: () -> Bool = { false }
    var onTab: () -> Bool
    var onShiftTab: () -> Bool
    /// Pasted markdown decoded to multiple blocks (or one non-paragraph block):
    /// the row splits the current block and inserts them. Args: pasted blocks,
    /// text before the caret, text after the caret.
    var onPasteBlocks: (_ pasted: [Block], _ before: NSAttributedString, _ after: NSAttributedString) -> Void = { _, _, _ in }
    /// A "/" was just typed. The argument is its character index, so the row
    /// can anchor the slash command there.
    var onSlash: (Int) -> Void
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
    /// A text-selection drag began inside this block (first drag event). Lets
    /// EditorView arm row-frame collection before the pointer crosses a boundary.
    var onSelectionDragBegan: () -> Void = {}
    /// The selection drag escalated to whole-block selection and the pointer moved.
    /// `localY` is the pointer's Y in the text view's (flipped) coords — negative
    /// above the top, greater than `textHeight` below the bottom.
    var onSelectionDragChanged: (_ localY: CGFloat, _ textHeight: CGFloat) -> Void = { _, _ in }
    /// The selection drag ended (mouse up), whether or not it escalated.
    var onSelectionDragEnded: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> AutoSizingTextView {
        let tv = AutoSizingTextView()
        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isEditable = isEditable
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
        if tv.isEditable != isEditable { tv.isEditable = isEditable }

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
        // A kind change swaps the base font, so the line height (and an empty
        // block's height) changes even when the text is byte-identical — e.g.
        // Backspace demoting an empty heading to a paragraph. Re-measure, since
        // `layout()` only re-measures on a width change.
        if kindChanged { tv.invalidateIntrinsicContentSize() }

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
                    } else if tv.selectedRange().length == 0 {
                        // Default placement only when there's no selection to keep —
                        // a hover re-render can bounce focus and land here while the
                        // user has an active selection (format bar showing); stomping
                        // it to a caret would clear the selection under their mouse.
                        tv.setSelectedRange(NSRange(location: length, length: 0))
                    }
                    onFocus()
                }
                context.coordinator.pendingFocusWork = work
                DispatchQueue.main.async(execute: work)
            }
        }
    }

    /// Cache of the per-kind typing attributes. These are constant per kind, but
    /// `updateNSView` reassigns them on every SwiftUI pass (once per visible block
    /// on any focus/selection change), so rebuilding the paragraph style + dict
    /// each time is wasted work. Main-thread only, matching the text editing path.
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

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BlockTextView
        var lastLanguage: CodeLanguage?
        var lastKind: BlockKind?
        fileprivate var pendingFocusWork: DispatchWorkItem?
        /// Guards re-entrancy while the inline-code transform edits the storage.
        private var applyingInlineCode = false
        /// True only while the pending edit inserts a "/", so the slash menu
        /// opens on a keystroke — not when a deletion leaves a "/" before the
        /// caret (e.g. erasing "hello" from "/hello" back down to "/").
        private var typedSlash = false
        /// True while a paste is inserting text, so the slash heuristic is skipped
        /// (a pasted string ending in "/" must not open the slash menu).
        private var isPasting = false
        init(_ parent: BlockTextView) { self.parent = parent }

        func beginPaste() { isPasting = true }
        func endPaste() { isPasting = false }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            // Ignore our own programmatic edits (e.g. the inline-code transform),
            // which also route through this delegate. hasSuffix (rather than ==)
            // so a "/" ending a short IME composition commit still opens the menu,
            // but bound the length so pasting a URL that ends in "/" does not.
            if !applyingInlineCode {
                if isPasting {
                    typedSlash = false
                } else {
                    typedSlash = (replacementString?.hasSuffix("/") ?? false)
                        && (replacementString?.count ?? 0) <= 2
                }
            }
            return true
        }

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
            // MUST be a copy: attributedString() returns the live text storage, and
            // sharing that mutable object with the binding makes onChange(of:) see
            // "no change" on every keystroke (breaking markdown shortcuts + autosave).
            parent.text = NSAttributedString(attributedString: tv.attributedString())
            tv.invalidateIntrinsicContentSize()

            // Slash command: opens when a "/" was just typed at the caret — works
            // mid-line (e.g. "Hello/") so inline math can be inserted anywhere.
            let sel = tv.selectedRange()
            let ns = tv.string as NSString
            if typedSlash, parent.kind != .code, sel.length == 0, sel.location > 0, sel.location <= ns.length,
               ns.substring(with: NSRange(location: sel.location - 1, length: 1)) == "/" {
                parent.onSlash(sel.location - 1)
            }
            typedSlash = false
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
            // Hold the guard across shouldChangeText/didChangeText too, so the
            // delegate doesn't mistake this programmatic replacement for a typed
            // "/" (which would spuriously open the slash menu for "`/`").
            applyingInlineCode = true
            defer { applyingInlineCode = false }
            guard tv.shouldChangeText(in: fullSpan, replacementString: content) else { return }

            let color: NSColor = parent.kind == .quote ? .secondaryLabelColor : .textColor
            let size = (tv.font ?? NSFont.systemFont(ofSize: 16)).pointSize
            let styled = NSAttributedString(string: content,
                                            attributes: InlineCode.attributes(size: size, color: color))
            storage.replaceCharacters(in: fullSpan, with: styled)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: openIdx + styled.length, length: 0))
            // Stop the code styling from continuing as the user keeps typing.
            tv.typingAttributes = BlockTextView.typingAttributes(for: parent.kind)
        }

        /// Show the floating format bar above a non-empty selection; hide otherwise.
        func updateFormatBar(_ tv: AutoSizingTextView) {
            guard parent.showsFormatBar else { parent.formatBar.hide(); return }
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
                // Split at the caret: hand the row the text on each side so the
                // part after the caret moves into the new block.
                let sel = textView.selectedRange()
                let storage = textView.textStorage
                let length = storage?.length ?? 0
                let before = storage?.attributedSubstring(
                    from: NSRange(location: 0, length: sel.location)) ?? NSAttributedString()
                let afterLoc = sel.location + sel.length
                let after = storage?.attributedSubstring(
                    from: NSRange(location: afterLoc, length: length - afterLoc)) ?? NSAttributedString()
                return parent.onEnter(before, after)

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

            // Escalate to block selection only from a collapsed caret at the
            // boundary. With a text selection already present, selectedRange()
            // .location is the fixed anchor (not the moving end), so testing it
            // would misfire — let the text view extend/shrink its own selection.
            case #selector(NSResponder.moveUpAndModifySelection(_:)):
                if textView.selectedRange().length == 0,
                   (textView as? AutoSizingTextView)?.caretIsOnFirstLine() == true,
                   parent.onExtendSelectionUp() {
                    textView.window?.makeFirstResponder(nil)
                    return true
                }
                return false

            case #selector(NSResponder.moveDownAndModifySelection(_:)):
                if textView.selectedRange().length == 0,
                   (textView as? AutoSizingTextView)?.caretIsOnLastLine() == true,
                   parent.onExtendSelectionDown() {
                    textView.window?.makeFirstResponder(nil)
                    return true
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

    /// Width at the last intrinsic-size invalidation. Height depends only on the
    /// wrapping width, so re-measuring when the width is unchanged just triggers
    /// another layout for the same answer — invalidate only when the width moves.
    private var lastLaidOutWidth: CGFloat = -1

    override func layout() {
        super.layout()
        let width = bounds.width
        if width != lastLaidOutWidth {
            lastLaidOutWidth = width
            invalidateIntrinsicContentSize()
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
        let loc = selectedRange().location
        let len = (string as NSString).length
        if loc >= len { return true }
        let caretRect = lm.boundingRect(forGlyphRange: NSRange(location: loc, length: 0), in: tc)
        let lastRect = lm.boundingRect(forGlyphRange: NSRange(location: max(len - 1, 0), length: 0), in: tc)
        return abs(caretRect.minY - lastRect.minY) < 1
    }

    // Double-click on an inline math attachment opens its editor. Otherwise a plain
    // selection drag runs our own tracking loop so it can escalate to whole-block
    // selection when the pointer leaves this block (SwiftUI/monitors never see the
    // native NSTextView modal loop). Modified clicks fall back to the native path.
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

        // Shift-extend / discontiguous / context-menu clicks keep native behavior.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let window, isSelectable,
              mods.isDisjoint(with: [.shift, .command, .control]) else {
            super.mouseDown(with: event)
            return
        }

        window.makeFirstResponder(self)   // focuses -> onFocused clears any block selection

        // Anchor selection: character / word / paragraph by click count.
        let granularity: NSSelectionGranularity =
            event.clickCount >= 3 ? .selectByParagraph
          : event.clickCount == 2 ? .selectByWord
          : .selectByCharacter
        let p0 = convert(event.locationInWindow, from: nil)
        let anchorIdx = characterIndexForInsertion(at: p0)
        let anchorRange = selectionRange(
            forProposedRange: NSRange(location: anchorIdx, length: 0), granularity: granularity)
        setSelectedRange(anchorRange)

        var escalated = false
        var dragStarted = false
        let slop: CGFloat = 8

        trackingLoop: while true {
            guard let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                                           until: .distantFuture,
                                           inMode: .eventTracking, dequeue: true) else { break }
            switch e.type {
            case .leftMouseUp:
                break trackingLoop
            case .keyDown:
                // Escape cancels the whole drag; other keys are swallowed while dragging.
                if e.keyCode == 53 {
                    if dragStarted { coordinator?.parent.onSelectionDragEnded() }   // disarm frames
                    setSelectedRange(NSRange(location: anchorRange.location, length: 0))
                    coordinator?.parent.onFocused()   // clears block selection, refocuses caret
                    // Drain to the mouse up so we don't leave the button "down".
                    while let up = window.nextEvent(matching: [.leftMouseUp],
                                                    until: .distantFuture,
                                                    inMode: .eventTracking, dequeue: true),
                          up.type != .leftMouseUp {}
                    return
                }
                continue
            default:
                break
            }

            if !dragStarted {
                dragStarted = true
                coordinator?.parent.onSelectionDragBegan()
            }

            let p = convert(e.locationInWindow, from: nil)   // flipped: y grows downward from top
            let inside = p.y >= -slop && p.y <= bounds.height + slop

            if inside {
                if escalated {
                    escalated = false
                    window.makeFirstResponder(self)   // onFocused clears selectedBlockIDs
                }
                autoscroll(with: e)
                let idx = characterIndexForInsertion(at: p)
                let lo = min(anchorRange.location, idx)
                let hi = max(anchorRange.location + anchorRange.length, idx)
                let sel = selectionRange(forProposedRange: NSRange(location: lo, length: hi - lo),
                                         granularity: granularity)
                setSelectedRange(sel,
                                 affinity: idx < anchorRange.location ? .upstream : .downstream,
                                 stillSelecting: true)
            } else {
                if !escalated {
                    escalated = true
                    setSelectedRange(NSRange(location: anchorRange.location, length: 0),
                                     affinity: .downstream, stillSelecting: true)
                    coordinator?.parent.formatBar.hide()   // block selection replaces the text selection
                    window.makeFirstResponder(nil)   // drop caret so block tint shows alone
                }
                coordinator?.parent.onSelectionDragChanged(p.y, bounds.height)
            }
        }

        if escalated {
            coordinator?.parent.onSelectionDragEnded()
        } else {
            if dragStarted { coordinator?.parent.onSelectionDragEnded() }
            // Finalize the selection, then show the format bar directly —
            // setSelectedRange with an unchanged range doesn't reliably post
            // textViewDidChangeSelection, so don't depend on the delegate.
            setSelectedRange(selectedRange(), affinity: .downstream, stillSelecting: false)
            // Deferred: we're still inside the .eventTracking runloop mode here,
            // where ordering a panel front doesn't reliably take effect.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.coordinator?.updateFormatBar(self)
            }
        }
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
            coordinator?.parent.formatBar.hide()   // block selection replaces the text selection
            window?.makeFirstResponder(nil)   // drop text caret so block selection shows alone
        } else {
            super.selectAll(sender)
        }
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        needsDisplay = true   // hide placeholder on blur
        // Don't hide the format bar here: a hover-driven SwiftUI re-render can
        // resign/reacquire first responder on this view spuriously (no real
        // focus change), and hiding on that would drop the bar out from under
        // the user while they're moving the mouse toward it. Real focus loss
        // (switching blocks, clicking away, collapsing the selection) already
        // hides it via textViewDidChangeSelection's empty-selection check, and
        // app-deactivate is handled by the panel's own hidesOnDeactivate.
        return ok
    }

    // MARK: Paste (markdown-aware)

    /// Cmd+V / Edit ▸ Paste. Reads ONLY the plain-string flavor (the editor has no
    /// color/font model, and markdown round-trips every block kind). Inside a code
    /// block paste is always literal. Markdown that decodes to a single paragraph
    /// is inserted inline at the caret; anything structural (multiple blocks or a
    /// single table/code/quote/heading/list/divider) splits the block and hands the
    /// surgery to the row via `onPasteBlocks`.
    override func paste(_ sender: Any?) {
        guard let parent = coordinator?.parent else { return }
        if parent.kind == .code { pasteLiteral(); return }
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let pasted = MarkdownCodec.decodeForPaste(raw)
        if pasted.count == 1, pasted[0].kind == .paragraph {
            insertPasted(pasted[0].text.restyled(to: parent.kind))
            return
        }
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        let before = storage.attributedSubstring(from: NSRange(location: 0, length: sel.location))
        let afterLoc = sel.location + sel.length
        let after = storage.attributedSubstring(
            from: NSRange(location: afterLoc, length: storage.length - afterLoc))
        parent.onPasteBlocks(pasted, before, after)
    }

    /// Cmd+Shift+V, "Paste and Match Style", and every paste inside a code block:
    /// the pasteboard string inserted verbatim (newlines normalized), no parsing.
    func pasteLiteral() {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let s = raw.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")
        insertPasted(NSAttributedString(string: s, attributes: typingAttributes))
    }

    override func pasteAsPlainText(_ sender: Any?) { pasteLiteral() }

    /// Insert pasted text at the caret/selection through `insertText`, so NSTextView
    /// undo works and the block's typing attributes apply, with the slash-menu
    /// heuristic suppressed for the duration.
    private func insertPasted(_ attr: NSAttributedString) {
        coordinator?.beginPaste()
        defer { coordinator?.endPaste() }
        insertText(attr, replacementRange: selectedRange())
    }

    // MARK: Inline formatting (bold / italic / strikethrough over the selection)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Cmd+Shift+V: paste as plain literal text (no markdown parsing). Handled
        // here — not gated on a selection — so it works with a collapsed caret too.
        if mods == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "v" {
            pasteLiteral()
            return true
        }
        if selectedRange().length > 0, let chars = event.charactersIgnoringModifiers?.lowercased() {
            if mods == .command {
                switch chars {
                case "b": toggleFontTrait(.boldFontMask); coordinator?.parent.formatBar.refreshTraits(for: self); return true
                case "i": toggleFontTrait(.italicFontMask); coordinator?.parent.formatBar.refreshTraits(for: self); return true
                case "e": toggleInlineCode(); coordinator?.parent.formatBar.refreshTraits(for: self); return true
                default: break
                }
            } else if mods == [.command, .shift], chars == "s" {
                toggleStrikethrough(); coordinator?.parent.formatBar.refreshTraits(for: self); return true
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
        // The block kind's base font, NOT `self.font` — the latter reflects the
        // selection, which is already monospaced when removing inline code, so
        // "restoring" it would just re-apply the code font.
        let base = coordinator?.parent.kind.baseFont ?? font ?? NSFont.systemFont(ofSize: 16)
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
