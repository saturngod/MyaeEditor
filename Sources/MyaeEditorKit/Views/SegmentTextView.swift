//
//  SegmentTextView.swift
//  MyaeEditor
//
//  Hosts one text segment's storage in an editable, auto-sizing NSTextView. The
//  storage IS the model (shared by reference), so typing mutates it directly with
//  no per-keystroke copy. Reuses `AutoSizingTextView` (with the block coordinator
//  left nil, like table cells) for its sizing, placeholder, and inline-format
//  toggles; a lightweight coordinator drives edit signals and the format bar.
//

import SwiftUI
import AppKit

/// Shared state for the "/" command menu of one text segment. The text view
/// opens/anchors it and installs the commit closure; the SwiftUI popover reads it.
@Observable
@MainActor
final class SlashMenuState {
    var active = false
    /// Anchor rect (text-view coordinates) of the typed "/".
    var anchorRect = CGRect.zero
    var query = ""
    var selection = 0
    /// Installed by the text view when the menu opens; removes the "/" and
    /// applies the chosen kind.
    @ObservationIgnored var commit: ((BlockKind) -> Void)?
}

struct SegmentTextView: NSViewRepresentable {
    /// The segment's shared text storage.
    let storage: NSTextStorage

    var isFocused: Bool
    var focusAtStart: Bool
    var pendingCaretLocation: Int?
    var formatBar: FormatBarController
    var isEditable: Bool = true
    var showsFormatBar: Bool = true

    /// Content changed — drives dirty tracking / autosave.
    var onEdited: () -> Void
    /// This segment became first responder.
    var onFocused: () -> Void = {}
    /// The focus request was applied (clears the document's one-shot flag).
    var onFocusApplied: () -> Void = {}
    /// The pending caret location was applied.
    var onCaretApplied: () -> Void = {}
    /// A ``` fence line + Enter — split this text segment and insert a code block.
    var onCreateCodeBlock: (_ paragraphRange: NSRange, _ language: CodeLanguage) -> Void = { _, _ in }
    /// Pasted Markdown decoded to widgets (tables/code/images/…) — splice them in
    /// at the caret. Args: caret location, decoded segments.
    var onPasteSegments: (_ caret: Int, _ segments: [Segment]) -> Void = { _, _ in }
    /// Backspace at the very start of this text segment — delete a preceding
    /// widget if there is one. Returns true if consumed.
    var onBackspaceAtStart: () -> Bool = { false }
    /// Up arrow on the first line — move to the previous segment. Returns true if consumed.
    var onArrowUp: () -> Bool = { false }
    /// Down arrow on the last line — move to the next segment. Returns true if consumed.
    var onArrowDown: () -> Bool = { false }
    /// Cmd+A pressed while this run's text is already fully selected (or empty):
    /// escalate to selecting the whole document (all segments incl. widgets).
    var onSelectAllSegments: () -> Void = {}
    /// Whether typing "/" opens the command menu (config flag).
    var showsSlashMenu: Bool = true
    /// The slash-menu state owned by the enclosing container view.
    var slashState: SlashMenuState? = nil
    /// A slash-menu widget command (table/image/equation/divider/code) was chosen.
    var onSlashWidget: (_ kind: BlockKind, _ caret: Int) -> Void = { _, _ in }
    /// The slash-menu inline-math command was chosen at `caret`.
    var onSlashMath: (_ caret: Int) -> Void = { _ in }
    /// Double-click landed on an inline math attachment: (its range, its LaTeX).
    var onEditMath: (_ range: NSRange, _ latex: String) -> Void = { _, _ in }
    /// Open the link editor for `range` (existing url may be nil when creating
    /// from a plain-text selection). `anchor` is the range's rect in view coords.
    var onEditLink: (_ range: NSRange, _ text: String, _ url: URL?, _ anchor: CGRect) -> Void = { _, _, _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SegmentNSTextView {
        let tv = SegmentNSTextView()
        tv.segmentCoordinator = context.coordinator
        tv.formatBarRef = formatBar
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
        tv.placeholder = "Type '/' for commands"
        // Fixed-height, baseline-centered line fragments (and a centered caret) —
        // see CenteringLayoutManager. Must be installed before the storage swap.
        tv.textContainer?.replaceLayoutManager(CenteringLayoutManager())
        // Attach the shared storage: edits land straight in the segment's model.
        tv.layoutManager?.replaceTextStorage(storage)
        tv.typingAttributes = SegmentStyle.attributes(for: .paragraph)
        tv.unregisterDraggedTypes()
        return tv
    }

    func updateNSView(_ tv: SegmentNSTextView, context: Context) {
        context.coordinator.parent = self
        if tv.isEditable != isEditable { tv.isEditable = isEditable }
        // Storage is shared by reference — nothing to sync.
        if isFocused, tv.window?.firstResponder !== tv {
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
                    tv.setSelectedRange(NSRange(location: length, length: 0))
                }
                onFocus()
            }
            context.coordinator.pendingFocusWork = work
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SegmentTextView
        fileprivate var pendingFocusWork: DispatchWorkItem?
        /// Guards re-entrancy while an input rule edits the storage.
        fileprivate var applyingRule = false
        /// True only while the pending edit inserts a "/" by typing (not paste),
        /// so the slash menu opens on a keystroke only.
        private var typedSlash = false
        /// True while a paste inserts text (suppresses the slash heuristic).
        var isPasting = false
        init(_ parent: SegmentTextView) { self.parent = parent }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            if !applyingRule {
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
            guard let tv = notification.object as? SegmentNSTextView else { return }
            guard !applyingRule else { return }
            if !applyLinePrefixRule(tv) { applyInlineRule(tv) }
            tv.fixEditedParagraphs()
            tv.invalidateIntrinsicContentSize()
            tv.needsDisplay = true   // redraw list markers / checkboxes
            parent.onEdited()
            if typedSlash, parent.showsSlashMenu { openSlashMenu(tv) }
            typedSlash = false
        }

        // MARK: Slash menu

        /// Open the "/" command menu anchored at the just-typed slash.
        private func openSlashMenu(_ tv: SegmentNSTextView) {
            guard let state = parent.slashState, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let sel = tv.selectedRange()
            let ns = tv.string as NSString
            guard sel.length == 0, sel.location > 0, sel.location <= ns.length,
                  ns.substring(with: NSRange(location: sel.location - 1, length: 1)) == "/" else { return }
            let slashLoc = sel.location - 1

            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: slashLoc, length: 1),
                                       actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            rect.origin.x += tv.textContainerOrigin.x
            rect.origin.y += tv.textContainerOrigin.y

            state.anchorRect = rect
            state.query = ""
            state.selection = 0
            state.commit = { [weak tv, weak self] kind in
                guard let tv, let self else { return }
                self.commitSlash(tv, kind: kind, slashLoc: slashLoc)
            }
            state.active = true
        }

        /// Remove the typed "/" and apply the chosen command.
        private func commitSlash(_ tv: SegmentNSTextView, kind: BlockKind, slashLoc: Int) {
            parent.slashState?.active = false
            guard let storage = tv.textStorage, slashLoc < storage.length else { return }
            let slashRange = NSRange(location: slashLoc, length: 1)
            applyingRule = true
            if tv.shouldChangeText(in: slashRange, replacementString: "") {
                storage.replaceCharacters(in: slashRange, with: "")
                tv.didChangeText()
            }
            applyingRule = false
            tv.setSelectedRange(NSRange(location: slashLoc, length: 0))
            tv.window?.makeFirstResponder(tv)

            switch kind {
            case _ where kind.isTextual && kind != .code:
                let depth = SegmentStyle.paragraphKind(in: storage, at: slashLoc).depth
                tv.setParagraphKind(ParagraphKind(kind, depth: depth), atParagraph: slashLoc, restyleFonts: true)
            case .inlineMath:
                parent.onSlashMath(slashLoc)
            default:   // code, divider, table, image, equation
                parent.onSlashWidget(kind, slashLoc)
            }
            parent.onEdited()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let tv = textView as? SegmentNSTextView else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                return tv.handleEnter()
            case #selector(NSResponder.deleteBackward(_:)):
                return tv.handleBackspace()
            case #selector(NSResponder.insertTab(_:)):
                return tv.handleTab(shift: false)
            case #selector(NSResponder.insertBacktab(_:)):
                return tv.handleTab(shift: true)
            case #selector(NSResponder.moveUp(_:)):
                if tv.caretIsOnFirstLine() { return parent.onArrowUp() }
                return false
            case #selector(NSResponder.moveDown(_:)):
                if tv.caretIsOnLastLine() { return parent.onArrowDown() }
                return false
            default:
                return false
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? SegmentNSTextView else { return }
            updateFormatBar(tv)
            syncTypingAttributes(tv)
            tv.needsDisplay = true   // an empty list/todo marker follows the caret
        }

        // MARK: Input rules

        /// A whole-line prefix (`# `, `- `, `1. `, `> `, `[] `) just completed on a
        /// plain paragraph → convert the paragraph's kind and drop the prefix.
        /// Returns true if it fired.
        private func applyLinePrefixRule(_ tv: SegmentNSTextView) -> Bool {
            guard let storage = tv.textStorage else { return false }
            let sel = tv.selectedRange()
            guard sel.length == 0, sel.location > 0 else { return false }
            let pr = tv.paragraphRange(at: sel.location)
            let pk = SegmentStyle.paragraphKind(in: storage, at: pr.location)
            guard pk.kind == .paragraph else { return false }
            let ns = tv.string as NSString
            let prefixLen = sel.location - pr.location
            guard prefixLen > 0, prefixLen <= 8 else { return false }
            let typed = ns.substring(with: NSRange(location: pr.location, length: prefixLen))
            guard typed.hasSuffix(" ") else { return false }

            let target: BlockKind?
            switch typed {
            case "# ":      target = .heading1
            case "## ":     target = .heading2
            case "### ":    target = .heading3
            case "#### ":   target = .heading4
            case "##### ":  target = .heading5
            case "###### ": target = .heading6
            case "- ", "* ", "+ ": target = .bulleted
            case "> ":      target = .quote
            case "[] ", "[ ] ": target = .todo
            default:
                // Numbered: "<digits>. "
                if typed.dropLast().allSatisfy({ $0.isNumber || $0 == "." }),
                   typed.hasSuffix(". "), typed.dropLast(2).allSatisfy({ $0.isNumber }),
                   !typed.dropLast(2).isEmpty {
                    target = .numbered
                } else {
                    target = nil
                }
            }
            guard let kind = target else { return false }

            let prefixRange = NSRange(location: pr.location, length: prefixLen)
            applyingRule = true
            defer { applyingRule = false }
            guard tv.shouldChangeText(in: prefixRange, replacementString: "") else { return true }
            storage.replaceCharacters(in: prefixRange, with: "")
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: pr.location, length: 0))
            tv.setParagraphKind(ParagraphKind(kind, depth: pk.depth), atParagraph: pr.location, restyleFonts: true)
            return true
        }

        /// A closing inline delimiter (`` ` ``, `*`, `**`, `~~`, `$`) just typed →
        /// convert the enclosed span to the corresponding inline style.
        private func applyInlineRule(_ tv: SegmentNSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            guard sel.length == 0, sel.location >= 2 else { return }
            let closeEnd = sel.location
            let line = ns.lineRange(for: NSRange(location: closeEnd, length: 0))
            // A fence line being typed (``` …) must not trigger inline code.
            let lineText = ns.substring(with: line)
            if lineText.hasPrefix("```") { return }
            let last = ns.character(at: closeEnd - 1)

            // Typed ")" — maybe closing a [text](url) link.
            if last == 41 {
                applyLinkRule(tv, closeEnd: closeEnd, line: line)
                return
            }

            // Determine the delimiter kind + length.
            enum Kind { case code, math, bold, italic, strike }
            let kind: Kind
            let delimLen: Int
            switch last {
            case 96:  kind = .code;  delimLen = 1                                   // `
            case 36:  kind = .math;  delimLen = 1                                   // $
            case 126:                                                              // ~
                guard closeEnd >= 2, ns.character(at: closeEnd - 2) == 126 else { return }
                kind = .strike; delimLen = 2
            case 42:                                                               // *
                if closeEnd >= 2, ns.character(at: closeEnd - 2) == 42 {
                    kind = .bold; delimLen = 2
                } else {
                    // Lone '*': ignore if it's actually the second star of a '**'
                    // still being typed (handled above) — here it's italic.
                    kind = .italic; delimLen = 1
                }
            default: return
            }

            let delimChar = last
            let openerScanEnd = closeEnd - delimLen
            guard openerScanEnd > line.location else { return }

            // Find the opener: nearest matching delimiter run on the same line.
            var openerLoc = -1
            var i = openerScanEnd - delimLen
            while i >= line.location {
                if matchesDelim(ns, at: i, char: delimChar, len: delimLen) {
                    // For lone '*' avoid matching a star that is part of '**'.
                    if kind == .italic {
                        let prevStar = i > line.location && ns.character(at: i - 1) == 42
                        let nextStar = i + 1 < ns.length && ns.character(at: i + 1) == 42
                        if prevStar || nextStar { i -= 1; continue }
                    }
                    if openerScanEnd - (i + delimLen) >= 1 { openerLoc = i; break }
                }
                i -= 1
            }
            guard openerLoc >= 0 else { return }

            let innerLoc = openerLoc + delimLen
            let innerLen = openerScanEnd - innerLoc
            let fullSpan = NSRange(location: openerLoc, length: closeEnd - openerLoc)
            let paraKind = SegmentStyle.paragraphKind(in: storage, at: openerLoc)
            let baseFont = paraKind.kind.baseFont
            let baseColor: NSColor = (paraKind.kind == .quote) ? .secondaryLabelColor : .textColor

            let replacement: NSAttributedString
            switch kind {
            case .code:
                let content = ns.substring(with: NSRange(location: innerLoc, length: innerLen))
                replacement = NSAttributedString(string: content,
                    attributes: InlineCode.attributes(size: baseFont.pointSize, color: baseColor))
            case .math:
                let latex = ns.substring(with: NSRange(location: innerLoc, length: innerLen))
                replacement = InlineMath.attributedString(latex: latex, fontSize: baseFont.pointSize, kind: paraKind.kind)
            case .bold, .italic, .strike:
                let inner = NSMutableAttributedString(
                    attributedString: storage.attributedSubstring(from: NSRange(location: innerLoc, length: innerLen)))
                let full = NSRange(location: 0, length: inner.length)
                if kind == .strike {
                    inner.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: full)
                } else {
                    let trait: NSFontTraitMask = (kind == .bold) ? .boldFontMask : .italicFontMask
                    inner.enumerateAttribute(.font, in: full) { value, sub, _ in
                        let f = (value as? NSFont) ?? baseFont
                        inner.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: trait), range: sub)
                    }
                }
                replacement = inner
            }

            applyingRule = true
            defer { applyingRule = false }
            guard tv.shouldChangeText(in: fullSpan, replacementString: replacement.string) else { return }
            storage.replaceCharacters(in: fullSpan, with: replacement)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: openerLoc + replacement.length, length: 0))
            tv.typingAttributes = SegmentStyle.attributes(for: paraKind)
        }

        /// Matches a `[text](url)` whose `)` was just typed at the search-range end.
        /// The search-range bounds act as anchors, so `$` matches exactly at the caret.
        private static let linkRuleRegex = try? NSRegularExpression(pattern: #"\[([^\[\]]*)\]\(([^()]+)\)$"#)

        /// `[text](url)` just closed with `)` → convert to a styled link.
        private func applyLinkRule(_ tv: SegmentNSTextView, closeEnd: Int, line: NSRange) {
            guard let storage = tv.textStorage, let re = Self.linkRuleRegex else { return }
            let searchRange = NSRange(location: line.location, length: closeEnd - line.location)
            guard let m = re.firstMatch(in: tv.string, options: [], range: searchRange) else { return }
            let ns = tv.string as NSString
            let text = ns.substring(with: m.range(at: 1))
            let urlString = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let url = URL(string: urlString), !urlString.isEmpty else { return }

            let full = m.range
            let pk = SegmentStyle.paragraphKind(in: storage, at: full.location)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: pk.kind.baseFont,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .myaeLink: url,
            ]
            let replacement = NSAttributedString(string: text, attributes: attrs)
            applyingRule = true
            defer { applyingRule = false }
            guard tv.shouldChangeText(in: full, replacementString: text) else { return }
            storage.replaceCharacters(in: full, with: replacement)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: full.location + replacement.length, length: 0))
            tv.typingAttributes = SegmentStyle.attributes(for: pk)   // don't continue typing in link style
        }

        private func matchesDelim(_ ns: NSString, at loc: Int, char: unichar, len: Int) -> Bool {
            guard loc >= 0, loc + len <= ns.length else { return false }
            for k in 0..<len where ns.character(at: loc + k) != char { return false }
            return true
        }

        /// Keep typing attributes matched to the caret's paragraph kind so newly
        /// typed text continues in the right style.
        private func syncTypingAttributes(_ tv: SegmentNSTextView) {
            guard let storage = tv.textStorage, storage.length > 0 else { return }
            let pk = SegmentStyle.paragraphKind(in: storage, at: tv.selectedRange().location)
            tv.typingAttributes = SegmentStyle.attributes(for: pk)
        }

        /// Show the floating format bar above a non-empty selection; hide otherwise.
        func updateFormatBar(_ tv: SegmentNSTextView) {
            guard parent.showsFormatBar else { parent.formatBar.hide(); return }
            let range = tv.selectedRange()
            guard range.length > 0, tv.window?.firstResponder === tv,
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
    }
}

// MARK: - The text view

/// A text view for one segment. Subclasses `AutoSizingTextView` to inherit its
/// intrinsic-size/placeholder/format-toggle machinery, but leaves the block-world
/// `coordinator` nil (so its block-selection mouse loop stays off) and routes
/// focus/paste to its own segment coordinator.
final class SegmentNSTextView: AutoSizingTextView {
    weak var segmentCoordinator: SegmentTextView.Coordinator?
    weak var formatBarRef: FormatBarController?

    /// Hit rects for todo checkboxes, rebuilt on each draw (marker frame → the
    /// paragraph's start location), used to toggle on click.
    private var checkboxHits: [(rect: NSRect, location: Int)] = []

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { segmentCoordinator?.parent.onFocused() }
        needsDisplay = true
        return ok
    }

    // Cmd+A: first press selects this run's text; a second press (text already
    // fully selected, or the run is empty) escalates to selecting the whole
    // document — every segment including code blocks and tables.
    override func selectAll(_ sender: Any?) {
        let length = (string as NSString).length
        let allSelected = selectedRange() == NSRange(location: 0, length: length)
        if length == 0 || allSelected {
            segmentCoordinator?.parent.onSelectAllSegments()
            formatBarRef?.hide()
            window?.makeFirstResponder(nil)   // drop caret so the tint shows alone
        } else {
            setSelectedRange(NSRange(location: 0, length: length))
        }
    }

    // MARK: Copy / cut / paste (markdown at the boundary)

    /// Copy the selection as Markdown (so it round-trips into other apps and back).
    override func copy(_ sender: Any?) {
        let r = selectedRange()
        guard r.length > 0, let storage = textStorage else { return }
        let sub = NSTextStorage(attributedString: storage.attributedSubstring(from: r))
        let md = SegmentCodec.encode([Segment(payload: .text(sub))])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    override func cut(_ sender: Any?) {
        let r = selectedRange()
        guard r.length > 0 else { return }
        copy(sender)
        if shouldChangeText(in: r, replacementString: "") {
            textStorage?.replaceCharacters(in: r, with: "")
            didChangeText()
        }
    }

    /// Paste Markdown so it renders. A single text run splices in inline; content
    /// containing widgets (tables/code/images/…) is spliced into the document at
    /// the caret via the surface.
    override func paste(_ sender: Any?) {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        segmentCoordinator?.isPasting = true
        defer { segmentCoordinator?.isPasting = false }
        let segs = SegmentCodec.decodeForPaste(raw)
        if segs.count == 1, let st = segs.first?.textStorage {
            insertText(st, replacementRange: selectedRange())
            return
        }
        // Widgets present — hand the splice to the surface.
        let sel = selectedRange()
        if sel.length > 0, shouldChangeText(in: sel, replacementString: "") {
            textStorage?.replaceCharacters(in: sel, with: "")
            didChangeText()
        }
        segmentCoordinator?.parent.onPasteSegments(selectedRange().location, segs)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        segmentCoordinator?.isPasting = true
        defer { segmentCoordinator?.isPasting = false }
        let s = raw.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")
        insertText(NSAttributedString(string: s, attributes: typingAttributes),
                   replacementRange: selectedRange())
    }

    // MARK: Paragraph model helpers

    private var ns: NSString { string as NSString }

    /// The full paragraph range (including its trailing newline) around `loc`.
    func paragraphRange(at loc: Int) -> NSRange {
        let clamped = min(max(loc, 0), ns.length)
        return ns.paragraphRange(for: NSRange(location: clamped, length: 0))
    }

    /// Content length of a paragraph (excluding a trailing newline).
    private func contentLength(of pr: NSRange) -> Int {
        guard pr.length > 0 else { return 0 }
        let last = pr.location + pr.length - 1
        return ns.character(at: last) == 10 ? pr.length - 1 : pr.length   // 10 = \n
    }

    func currentParagraphKind() -> ParagraphKind {
        guard let storage = textStorage else { return .paragraph }
        return SegmentStyle.paragraphKind(in: storage, at: selectedRange().location)
    }

    /// Apply a paragraph kind (style + `.paragraphKind` attribute, optionally
    /// re-fonting base runs) to the paragraph containing `loc`.
    func setParagraphKind(_ pk: ParagraphKind, atParagraph loc: Int, restyleFonts: Bool) {
        guard let storage = textStorage else { return }
        let pr = paragraphRange(at: loc)
        guard shouldChangeText(in: pr, replacementString: nil) else { return }
        storage.beginEditing()
        let attrs = SegmentStyle.attributes(for: pk)
        if let para = attrs[.paragraphStyle] { storage.addAttribute(.paragraphStyle, value: para, range: pr) }
        SegmentStyle.applyBaselineOffset(from: attrs, to: storage, range: pr)
        if pr.length > 0 { storage.addAttribute(.paragraphKind, value: pk, range: pr) }
        if restyleFonts, pr.length > 0 {
            let base = pk.kind.baseFont
            let color: NSColor = (pk.kind == .quote) ? .secondaryLabelColor : .textColor
            storage.enumerateAttribute(.font, in: pr) { value, sub, _ in
                // Inline code keeps its monospace face but must still track the new
                // base size — otherwise turning a paragraph into a heading leaves the
                // code run at the old (smaller) size beside the scaled-up text.
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
                storage.addAttribute(.foregroundColor, value: color, range: sub)
            }
        }
        storage.endEditing()
        didChangeText()
        typingAttributes = attrs
        needsDisplay = true
    }

    /// Re-assert paragraph style + kind attribute over every paragraph touched by
    /// the last edit, so indentation/markers stay consistent after typing/merging.
    func fixEditedParagraphs() {
        guard let storage = textStorage else { return }
        let edited = storage.editedRange
        guard edited.location != NSNotFound else { return }
        let startPara = paragraphRange(at: edited.location)
        let endPara = paragraphRange(at: min(edited.location + max(edited.length, 0), ns.length))
        let scanLoc = startPara.location
        let scanLen = (endPara.location + endPara.length) - scanLoc
        guard scanLen > 0 else { return }
        storage.beginEditing()
        ns.enumerateSubstrings(in: NSRange(location: scanLoc, length: scanLen),
                               options: .byParagraphs) { _, _, enclosing, _ in
            guard enclosing.length > 0 else { return }
            let pk = SegmentStyle.paragraphKind(in: storage, at: enclosing.location)
            let attrs = SegmentStyle.attributes(for: pk)
            if let para = attrs[.paragraphStyle] {
                storage.addAttribute(.paragraphStyle, value: para, range: enclosing)
            }
            SegmentStyle.applyBaselineOffset(from: attrs, to: storage, range: enclosing)
            storage.addAttribute(.paragraphKind, value: pk, range: enclosing)
        }
        storage.endEditing()
    }

    // MARK: Key handlers (Enter / Backspace / Tab kind semantics)

    /// Returns true if consumed.
    func handleEnter() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        let pr = paragraphRange(at: sel.location)
        let pk = currentParagraphKind()
        let cLen = contentLength(of: pr)
        let empty = cLen == 0

        // A ``` fence line → convert to an editable code block.
        if pk.kind == .paragraph, cLen >= 3 {
            let text = ns.substring(with: NSRange(location: pr.location, length: cLen))
            if text.hasPrefix("```") {
                let info = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                segmentCoordinator?.parent.onCreateCodeBlock(pr, CodeLanguage.resolve(info))
                return true
            }
        }

        // Empty list/todo item + Enter → exit the list (outdent, then to paragraph).
        if pk.kind.continuesOnEnter, empty {
            if pk.depth > 0 {
                setParagraphKind(ParagraphKind(pk.kind, depth: pk.depth - 1), atParagraph: sel.location, restyleFonts: false)
            } else {
                setParagraphKind(.paragraph, atParagraph: sel.location, restyleFonts: true)
            }
            return true
        }

        // Continue a list/todo (new item, unchecked); headings/quotes drop to plain.
        let newKind: ParagraphKind?
        switch pk.kind {
        case .bulleted, .numbered: newKind = ParagraphKind(pk.kind, depth: pk.depth)
        case .todo:                newKind = ParagraphKind(.todo, depth: pk.depth, checked: false)
        case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6, .quote:
            newKind = .paragraph
        default:                   newKind = nil   // plain paragraph → native newline
        }
        guard let target = newKind else { return false }
        insertText(NSAttributedString(string: "\n", attributes: SegmentStyle.attributes(for: target)),
                   replacementRange: sel)
        setParagraphKind(target, atParagraph: selectedRange().location, restyleFonts: false)
        return true
    }

    func handleBackspace() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        let pr = paragraphRange(at: sel.location)
        // Only at the very start of the paragraph.
        guard sel.location == pr.location else { return false }
        let pk = currentParagraphKind()
        if pk.depth > 0 {
            setParagraphKind(ParagraphKind(pk.kind, depth: pk.depth - 1), atParagraph: sel.location, restyleFonts: false)
            return true
        }
        if pk.kind != .paragraph {
            setParagraphKind(.paragraph, atParagraph: sel.location, restyleFonts: true)
            return true
        }
        // Plain paragraph at the very start of the segment → delete a preceding widget.
        if sel.location == 0 {
            return segmentCoordinator?.parent.onBackspaceAtStart() ?? false
        }
        return false   // native merge with the previous paragraph in this segment
    }

    func handleTab(shift: Bool) -> Bool {
        let pk = currentParagraphKind()
        guard pk.kind == .bulleted || pk.kind == .numbered || pk.kind == .todo else { return false }
        if shift {
            guard pk.depth > 0 else { return true }
            setParagraphKind(ParagraphKind(pk.kind, depth: pk.depth - 1), atParagraph: selectedRange().location, restyleFonts: false)
        } else {
            // Don't indent deeper than one past the previous list item.
            let pr = paragraphRange(at: selectedRange().location)
            let maxDepth: Int
            if pr.location > 0, let storage = textStorage {
                maxDepth = SegmentStyle.paragraphKind(in: storage, at: pr.location - 1).depth + 1
            } else {
                maxDepth = 0
            }
            guard pk.depth < max(maxDepth, 0) else { return true }
            setParagraphKind(ParagraphKind(pk.kind, depth: pk.depth + 1), atParagraph: selectedRange().location, restyleFonts: false)
        }
        return true
    }

    // MARK: Checkbox click

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = checkboxHits.first(where: { $0.rect.contains(point) }), let storage = textStorage {
            var pk = SegmentStyle.paragraphKind(in: storage, at: hit.location)
            pk.checked.toggle()
            setParagraphKind(pk, atParagraph: hit.location, restyleFonts: false)
            segmentCoordinator?.parent.onEdited()
            return
        }
        // Double-click on an inline math attachment opens its editor.
        if event.clickCount == 2, let lm = layoutManager, let tc = textContainer, let storage = textStorage {
            let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            let idx = lm.characterIndex(for: p, in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
            if idx < storage.length,
               let math = storage.attribute(.attachment, at: idx, effectiveRange: nil) as? MathAttachment {
                segmentCoordinator?.parent.onEditMath(NSRange(location: idx, length: 1), math.latex)
                return
            }
        }
        // Click on a link: Cmd+click follows it, a plain click opens the editor.
        if event.clickCount == 1, let lm = layoutManager, let tc = textContainer,
           let storage = textStorage, storage.length > 0 {
            let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            let idx = lm.characterIndex(for: p, in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
            if idx < storage.length, let info = linkInfo(at: idx) {
                let r = rect(for: info.range)
                if r.insetBy(dx: -2, dy: -2).contains(point) {
                    if event.modifierFlags.contains(.command) {
                        NSWorkspace.shared.open(info.url)
                    } else {
                        let text = storage.attributedSubstring(from: info.range).string
                        segmentCoordinator?.parent.onEditLink(info.range, text, info.url, r)
                    }
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: Links

    /// The full link run (and URL) covering character `idx`, if any.
    func linkInfo(at idx: Int) -> (range: NSRange, url: URL)? {
        guard let storage = textStorage, idx < storage.length else { return nil }
        var eff = NSRange()
        guard let url = storage.attribute(.myaeLink, at: idx, longestEffectiveRange: &eff,
                                          in: NSRange(location: 0, length: storage.length)) as? URL else { return nil }
        return (eff, url)
    }

    /// A range's bounding rect in view coordinates (popover anchor).
    func rect(for range: NSRange) -> CGRect {
        guard let lm = layoutManager, let tc = textContainer else { return .zero }
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        r.origin.x += textContainerOrigin.x
        r.origin.y += textContainerOrigin.y
        return r
    }

    /// Open the link editor for the selection: edit the existing link at the
    /// caret, or create one from the selected text. Called by the format bar.
    func requestLinkEdit() {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        if storage.length > 0 {
            let probe = min(sel.location, storage.length - 1)
            if let info = linkInfo(at: probe) {
                let text = storage.attributedSubstring(from: info.range).string
                segmentCoordinator?.parent.onEditLink(info.range, text, info.url, rect(for: info.range))
                return
            }
        }
        guard sel.length > 0 else { return }
        let text = storage.attributedSubstring(from: sel).string
        segmentCoordinator?.parent.onEditLink(sel, text, nil, rect(for: sel))
    }

    /// Refresh the format-bar button state after a Cmd-key formatting toggle.
    override func formatDidChange() {
        formatBarRef?.refreshTraits(for: self)
    }

    /// Removing inline code restores the caret paragraph's base font.
    override func inlineCodeRestoreFont() -> NSFont {
        guard let storage = textStorage else { return super.inlineCodeRestoreFont() }
        return SegmentStyle.paragraphKind(in: storage, at: selectedRange().location).kind.baseFont
    }

    /// Apply a paragraph kind (Text / Heading 1–6) to every paragraph the current
    /// selection touches. Used by the format bar's heading selector.
    func applyKindToSelection(_ kind: BlockKind) {
        let sel = selectedRange()
        let ns = self.string as NSString
        var loc = paragraphRange(at: sel.location).location
        let end = min(sel.location + sel.length, ns.length)
        while true {
            setParagraphKind(ParagraphKind(kind), atParagraph: loc, restyleFonts: true)
            let pr = paragraphRange(at: loc)
            let next = pr.location + pr.length
            if next <= loc || next > end { break }   // no progress or past the selection
            loc = next
        }
        setSelectedRange(sel)
        needsDisplay = true
        segmentCoordinator?.parent.onEdited()
    }

    // MARK: Marker drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawMarkers()
    }

    private func computeNumbering(_ storage: NSTextStorage) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var counters: [Int: Int] = [:]
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: .byParagraphs) { _, _, enclosing, _ in
            let pk = SegmentStyle.paragraphKind(in: storage, at: enclosing.location)
            let d = pk.depth
            counters = counters.filter { $0.key <= d }
            if pk.kind == .numbered {
                let n = (counters[d] ?? 0) + 1
                counters[d] = n
                result[enclosing.location] = n
            } else {
                counters[d] = nil
            }
        }
        return result
    }

    /// The kind that applies to the paragraph starting at `pStart`. For a
    /// non-empty paragraph the kind is stored on its first character; an empty
    /// paragraph has no character to carry it, so the caret paragraph falls back
    /// to the live typing attributes (this is what lets an empty `- ` / `[] `
    /// still draw its marker).
    private func paragraphKind(forParagraphAt pStart: Int, contentLen: Int, storage: NSTextStorage) -> ParagraphKind {
        if contentLen > 0 { return SegmentStyle.paragraphKind(in: storage, at: pStart) }
        let caretPara = paragraphRange(at: selectedRange().location)
        if window?.firstResponder === self, caretPara.location == pStart,
           let pk = typingAttributes[.paragraphKind] as? ParagraphKind {
            return pk
        }
        return .paragraph
    }

    /// The first line's used rect for the paragraph starting at `pStart`, in view
    /// coordinates. Handles the empty final line via the extra line fragment.
    private func firstLineUsedRect(forParagraphAt pStart: Int, lm: NSLayoutManager) -> NSRect {
        let origin = textContainerOrigin
        var r: NSRect
        if pStart < ns.length {
            let glyph = lm.glyphIndexForCharacter(at: pStart)
            r = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            r = lm.extraLineFragmentUsedRect
            if r == .zero { r = lm.extraLineFragmentRect }
        }
        r.origin.x += origin.x
        r.origin.y += origin.y
        return r
    }

    private func drawMarkers() {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return }
        checkboxHits.removeAll()
        let numbering = computeNumbering(storage)
        let origin = textContainerOrigin
        let len = ns.length

        // Iterate every paragraph, including a trailing/only empty one.
        var starts: [Int] = []
        if len == 0 {
            starts = [0]
        } else {
            var loc = 0
            while loc < len {
                let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
                starts.append(pr.location)
                loc = pr.location + pr.length
            }
            if ns.character(at: len - 1) == 10 { starts.append(len) }   // trailing empty line
        }

        for pStart in starts {
            let pr = (pStart < len) ? ns.paragraphRange(for: NSRange(location: pStart, length: 0))
                                    : NSRange(location: len, length: 0)
            let cLen = contentLength(of: pr)
            let pk = paragraphKind(forParagraphAt: pStart, contentLen: cLen, storage: storage)
            switch pk.kind {
            case .bulleted, .numbered, .todo, .quote: break
            default: continue
            }
            let lineRect = firstLineUsedRect(forParagraphAt: pStart, lm: lm)
            // Under `CenteringLayoutManager` the used rect is the full fixed-height
            // fragment with the glyphs centered inside it — the glyphs' visual top
            // sits `shift` below the used rect's top. Markers drawn from the top
            // must add it; anything centered (strikethrough) uses midY directly.
            let shift = BlockTextView.centeringShift(for: pk.kind)
            let indentX = origin.x + CGFloat(pk.depth) * SegmentStyle.indentPerLevel
            let font = pk.kind.baseFont

            switch pk.kind {
            case .quote:
                var barRect = lineRect
                if cLen > 0 {
                    let full = lm.glyphRange(forCharacterRange: NSRange(location: pStart, length: cLen),
                                             actualCharacterRange: nil)
                    barRect = lm.boundingRect(forGlyphRange: full, in: tc)
                    barRect.origin.x += origin.x
                    barRect.origin.y += origin.y
                }
                let bar = NSRect(x: indentX + 2, y: barRect.minY, width: 3, height: max(barRect.height, lineRect.height))
                NSColor.separatorColor.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            case .bulleted:
                let glyphs = ["•", "◦", "▪"]
                let g = glyphs[min(pk.depth, glyphs.count - 1)]
                drawMarkerText(g, at: NSPoint(x: indentX + 2, y: lineRect.minY + shift), font: font)
            case .numbered:
                let n = numbering[pStart] ?? 1
                drawMarkerText("\(n).", at: NSPoint(x: indentX + 2, y: lineRect.minY + shift), font: font)
            case .todo:
                let symbol = pk.checked ? "checkmark.square.fill" : "square"
                let box = NSRect(x: indentX + 2, y: lineRect.minY + shift + 1, width: 15, height: 15)
                if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                    let tint = pk.checked ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
                    img.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))?
                        .tinted(tint)?.draw(in: box)
                }
                checkboxHits.append((box.insetBy(dx: -3, dy: -3), pStart))
                if pk.checked, cLen > 0 {
                    // Strikethrough over the text of each line (never stored, so the
                    // codec never emits ~~ for it).
                    let gr = lm.glyphRange(forCharacterRange: NSRange(location: pStart, length: cLen),
                                           actualCharacterRange: nil)
                    NSColor.secondaryLabelColor.setStroke()
                    lm.enumerateLineFragments(forGlyphRange: gr) { _, usedRect, _, _, _ in
                        var ur = usedRect
                        ur.origin.x += origin.x
                        ur.origin.y += origin.y
                        let p = NSBezierPath()
                        p.move(to: NSPoint(x: ur.minX, y: ur.midY))
                        p.line(to: NSPoint(x: ur.maxX, y: ur.midY))
                        p.lineWidth = 1
                        p.stroke()
                    }
                }
            default: break
            }
        }
    }

    private func drawMarkerText(_ s: String, at point: NSPoint, font: NSFont) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        s.draw(at: point, withAttributes: attrs)
    }
}

private extension NSImage {
    /// A copy tinted with `color` (for template symbol images).
    func tinted(_ color: NSColor) -> NSImage? {
        guard let copy = self.copy() as? NSImage else { return nil }
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
    }
}
