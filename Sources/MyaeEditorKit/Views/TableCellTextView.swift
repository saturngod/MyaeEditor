//
//  TableCellTextView.swift
//  MyaeEditor
//
//  An NSTextView-backed editor for a single table cell. It reuses the same
//  formatting machinery as the main editor (AutoSizingTextView's bold/italic/
//  strike/inline-code toggles + the floating FormatBarController), so a cell
//  supports Cmd+B/I, Cmd+Shift+S, Cmd+E, and the selection popover exactly like a
//  paragraph block. The cell's text is stored as inline Markdown in the model, so
//  this view converts Markdown → attributed on load and attributed → Markdown on
//  every edit.
//

import SwiftUI
import AppKit

/// NSTextView subclass for cells: reports focus changes and refreshes the format
/// bar after a Cmd-key formatting shortcut. Inherits all the trait-toggle methods
/// (and auto-sizing) from `AutoSizingTextView`.
final class TableCellNSTextView: AutoSizingTextView {
    var onFocusChange: ((Bool) -> Void)?
    var cellFormatBar: FormatBarController?
    /// Up arrow on the first visual line — leave the cell upward (to the row
    /// above, or out the top of the table). Returns true if the move was handled.
    var arrowUp: (() -> Bool)?
    /// Down arrow on the last visual line — leave the cell downward (to the row
    /// below, or out the bottom of the table). Returns true if handled.
    var arrowDown: (() -> Bool)?
    /// Left arrow with the caret at the very start of the cell — move to the
    /// previous cell (or out of the table). Returns true if handled.
    var arrowLeft: (() -> Bool)?
    /// Right arrow with the caret at the very end of the cell. Returns true if handled.
    var arrowRight: (() -> Bool)?

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            if caretIsOnFirstLine(), arrowUp?() == true { return }
            super.doCommand(by: selector)
        case #selector(NSResponder.moveDown(_:)):
            if caretIsOnLastLine(), arrowDown?() == true { return }
            super.doCommand(by: selector)
        case #selector(NSResponder.moveLeft(_:)):
            if selectedRange() == NSRange(location: 0, length: 0), arrowLeft?() == true { return }
            super.doCommand(by: selector)
        case #selector(NSResponder.moveRight(_:)):
            let len = (string as NSString).length
            if selectedRange() == NSRange(location: len, length: 0), arrowRight?() == true { return }
            super.doCommand(by: selector)
        default:
            super.doCommand(by: selector)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let handled = super.performKeyEquivalent(with: event)
        // super applied the toggle (Cmd+B/I/E, Cmd+Shift+S) but has no coordinator
        // to refresh the bar's button state — do it here.
        if handled { cellFormatBar?.refreshTraits(for: self) }
        return handled
    }
}

struct TableCellTextView: NSViewRepresentable {
    /// The cell's inline-Markdown text (the model value).
    @Binding var markdown: String
    let isHeader: Bool
    let alignment: ColumnAlignment
    var formatBar: FormatBarController
    let cellID: TableCellID
    /// The table's currently-active cell; the view makes itself first responder
    /// when this equals its own id, and sets it when it gains focus by click.
    @Binding var activeCell: TableCellID?
    /// Tab / Shift+Tab: move to the next / previous cell. Arg is forward.
    var onTab: (_ forward: Bool) -> Void
    /// Up/down arrow at the cell's first/last visual line: move to the adjacent
    /// row, or step out of the table. `down` is true for the down arrow. Returns
    /// true when the caller moved focus (so the arrow shouldn't fall through).
    var onVerticalMove: (_ down: Bool) -> Bool
    /// Left/right arrow at the cell's start/end: move to the previous/next cell,
    /// or step out of the table at the first/last cell. `forward` is true for
    /// the right arrow. Returns true when focus moved.
    var onHorizontalMove: (_ forward: Bool) -> Bool

    private var baseFont: NSFont {
        EditorFont.regular(ofSize: 14, weight: isHeader ? .semibold : .regular)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TableCellNSTextView {
        let tv = TableCellNSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 8, height: 7)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        // Same fixed-height, baseline-centered lines (and centered caret) as the
        // main editor. Cells have no `.paragraphKind`, so the cell font is set as
        // an override instead.
        let cellLM = CenteringLayoutManager()
        cellLM.overrideFont = baseFont
        tv.textContainer?.replaceLayoutManager(cellLM)
        tv.font = baseFont
        tv.baseFontOverride = baseFont
        tv.alignment = alignment.nsTextAlignment
        tv.cellFormatBar = formatBar
        tv.typingAttributes = typingAttributes
        tv.textStorage?.setAttributedString(attributed(from: markdown))
        let coordinator = context.coordinator
        coordinator.lastMarkdown = markdown
        tv.onFocusChange = { [weak tv, weak coordinator] focused in
            guard let tv, let coordinator else { return }
            coordinator.focusChanged(tv, focused: focused)
        }
        // Read `parent` through the coordinator so these keep calling the latest
        // closure after SwiftUI rebuilds the representable.
        tv.arrowUp = { [weak coordinator] in coordinator?.parent.onVerticalMove(false) ?? false }
        tv.arrowDown = { [weak coordinator] in coordinator?.parent.onVerticalMove(true) ?? false }
        tv.arrowLeft = { [weak coordinator] in coordinator?.parent.onHorizontalMove(false) ?? false }
        tv.arrowRight = { [weak coordinator] in coordinator?.parent.onHorizontalMove(true) ?? false }
        // Don't intercept block-reorder drags.
        tv.unregisterDraggedTypes()
        return tv
    }

    func updateNSView(_ tv: TableCellNSTextView, context: Context) {
        context.coordinator.parent = self
        tv.cellFormatBar = formatBar

        if tv.font != baseFont {
            tv.font = baseFont
            tv.baseFontOverride = baseFont
            tv.typingAttributes = typingAttributes
            (tv.layoutManager as? CenteringLayoutManager)?.overrideFont = baseFont
            // The cell's existing characters carry the old baked-in font, so
            // reload the content to re-font it (e.g. after the editor's font
            // setting changes). `lastMarkdown` is unchanged, so this is the only
            // path that refreshes the cell's font.
            tv.textStorage?.setAttributedString(attributed(from: markdown))
        }
        if tv.alignment != alignment.nsTextAlignment {
            tv.alignment = alignment.nsTextAlignment
        }

        // Rebuild only on an *external* change to the model (open/undo/paste),
        // never from our own edit — that would clobber the caret mid-typing.
        if markdown != context.coordinator.lastMarkdown {
            context.coordinator.lastMarkdown = markdown
            let sel = tv.selectedRange()
            let attr = attributed(from: markdown)
            tv.textStorage?.setAttributedString(attr)
            tv.setSelectedRange(NSRange(location: min(sel.location, attr.length), length: 0))
            tv.invalidateIntrinsicContentSize()
        }

        // Focus management: take first responder when we're the active cell.
        if activeCell == cellID, tv.window?.firstResponder !== tv {
            DispatchQueue.main.async { [weak tv] in
                guard let tv, tv.window?.firstResponder !== tv else { return }
                tv.window?.makeFirstResponder(tv)
            }
        }
    }

    /// Carries the column alignment, since setting the attributed string would
    /// otherwise clobber the view's `alignment`. Line height/centering is not
    /// done here — `CenteringLayoutManager` (with the cell font as override)
    /// fixes the fragments, matching a wrapped paragraph in the main editor.
    private var cellParagraphStyle: NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.alignment = alignment.nsTextAlignment
        return para
    }

    private var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.textColor,
         .paragraphStyle: cellParagraphStyle]
    }

    private func attributed(from md: String) -> NSAttributedString {
        let attr = NSMutableAttributedString(
            attributedString: MarkdownCodec.inlineAttributed(md, baseFont: baseFont, color: .textColor))
        let full = NSRange(location: 0, length: attr.length)
        attr.addAttribute(.paragraphStyle, value: cellParagraphStyle, range: full)
        attr.removeAttribute(.baselineOffset, range: full)
        return attr
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TableCellTextView
        /// Last Markdown we pushed to / read from the model, so `updateNSView` can
        /// tell our own edits apart from external changes.
        var lastMarkdown: String = ""

        init(_ parent: TableCellTextView) { self.parent = parent }

        func focusChanged(_ tv: TableCellNSTextView, focused: Bool) {
            if focused {
                if parent.activeCell != parent.cellID { parent.activeCell = parent.cellID }
            } else {
                parent.formatBar.hide()
                // Drop the active-cell ring when focus leaves. AppKit resigns the
                // old responder *before* the new one becomes first responder, so if
                // focus moved to another cell it will re-set `activeCell` right
                // after — clearing only when we still own it is safe.
                if parent.activeCell == parent.cellID { parent.activeCell = nil }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? TableCellNSTextView,
                  let storage = tv.textStorage else { return }
            let md = MarkdownCodec.inlineMarkdown(from: storage, baseFont: parent.baseFont)
            // `lastMarkdown` tracks what the view currently displays, so a later
            // `updateNSView` only rebuilds (and moves the caret) on a *genuine*
            // external change — not on the model value we're pushing right now.
            lastMarkdown = md
            parent.markdown = md
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? TableCellNSTextView else { return }
            updateFormatBar(tv)
        }

        /// Tab / Shift+Tab move between cells instead of inserting a tab.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                parent.onTab(true); return true
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onTab(false); return true
            default:
                return false
            }
        }

        /// Show the floating format bar above a non-empty selection; hide otherwise.
        private func updateFormatBar(_ tv: TableCellNSTextView) {
            let range = tv.selectedRange()
            guard range.length > 0,
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
    }
}
