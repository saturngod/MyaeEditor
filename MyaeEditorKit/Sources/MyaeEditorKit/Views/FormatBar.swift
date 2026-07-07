//
//  FormatBar.swift
//  MyaeEditor
//
//  A floating format toolbar (bold / italic / strikethrough) that appears above
//  a non-empty text selection. It lives in a borderless,
//  non-activating NSPanel so clicking its buttons never steals first responder
//  from the text view — the selection stays put while you format it.
//

import SwiftUI
import AppKit

@Observable
final class FormatBarController {
    // Active trait state, read by the toolbar to highlight its buttons.
    var isBold = false
    var isItalic = false
    var isStrike = false
    var isCode = false
    var isLink = false
    /// The caret paragraph's kind when the active view supports kind changes
    /// (the main editor); `nil` hides the heading selector (table cells).
    var currentKind: BlockKind?

    @ObservationIgnored private weak var activeTextView: AutoSizingTextView?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var hosting: NSHostingView<FloatingFormatBar>?

    // MARK: Show / hide

    /// Show the bar centered above `rect` (in screen coordinates) for `textView`.
    func show(textView: AutoSizingTextView, atScreenRect rect: NSRect) {
        activeTextView = textView
        refreshTraits()
        let panel = ensurePanel()
        // Re-measure: the heading selector appears/disappears per context.
        if let hosting { panel.setContentSize(hosting.fittingSize) }
        let size = panel.frame.size
        let x = rect.midX - size.width / 2
        let y = rect.maxY + 8            // 8pt above the selection
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func hide() { panel?.orderOut(nil) }

    // MARK: Formatting actions (called by the toolbar buttons)

    func toggleBold()   { activeTextView?.toggleFontTrait(.boldFontMask);   refreshTraits() }
    func toggleItalic() { activeTextView?.toggleFontTrait(.italicFontMask); refreshTraits() }
    func toggleStrike() { activeTextView?.toggleStrikethrough();            refreshTraits() }
    func toggleCode()   { activeTextView?.toggleInlineCode();               refreshTraits() }

    /// Change the selection's paragraph kind (Text / Heading 1–6).
    func setKind(_ kind: BlockKind) {
        (activeTextView as? SegmentNSTextView)?.applyKindToSelection(kind)
        refreshTraits()
        // The kind change moves the selection's rect (font size changed) —
        // reposition on the next selection change; keep the bar where it is.
    }

    /// Open the link editor for the selection (create or edit).
    func editLink() {
        (activeTextView as? SegmentNSTextView)?.requestLinkEdit()
        hide()   // the link popup takes over
    }

    /// Re-read trait state after a change made directly on `tv` (e.g. Cmd+B key).
    func refreshTraits(for tv: AutoSizingTextView) {
        activeTextView = tv
        refreshTraits()
    }

    private func refreshTraits() {
        guard let tv = activeTextView else { return }
        let range = tv.selectedRange()
        isBold = tv.rangeHasTrait(.boldFontMask, in: range)
        isItalic = tv.rangeHasTrait(.italicFontMask, in: range)
        isStrike = tv.rangeHasStrikethrough(range)
        isCode = tv.rangeHasInlineCode(range)
        if let seg = tv as? SegmentNSTextView, let storage = seg.textStorage {
            currentKind = SegmentStyle.paragraphKind(in: storage, at: range.location).kind
            isLink = storage.length > 0
                && seg.linkInfo(at: min(range.location, storage.length - 1)) != nil
        } else {
            currentKind = nil
            isLink = false
        }
    }

    // MARK: Panel

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = true
        panel.isMovable = false
        let hosting = NSHostingView(rootView: FloatingFormatBar(controller: self))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        panel.setContentSize(hosting.fittingSize)
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
        return panel
    }
}

/// The toolbar UI shown inside the floating panel.
struct FloatingFormatBar: View {
    @Bindable var controller: FormatBarController

    /// The kinds offered by the heading selector, in menu order.
    private static let kindChoices: [BlockKind] = [
        .paragraph, .heading1, .heading2, .heading3, .heading4, .heading5, .heading6,
    ]

    var body: some View {
        HStack(spacing: 1) {
            if controller.currentKind != nil {
                kindMenu
                Divider().frame(height: 18).padding(.horizontal, 2)
            }
            button("bold", "Bold", active: controller.isBold) { controller.toggleBold() }
            button("italic", "Italic", active: controller.isItalic) { controller.toggleItalic() }
            button("strikethrough", "Strikethrough", active: controller.isStrike) { controller.toggleStrike() }
            button("chevron.left.forwardslash.chevron.right", "Code", active: controller.isCode) { controller.toggleCode() }
            if controller.currentKind != nil {
                button("link", "Link", active: controller.isLink) { controller.editLink() }
            }
        }
        .padding(3)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .padding(6)   // room for the shadow inside the (clear) panel
    }

    /// Text / Heading 1–6 selector (like Octarine's H-chip).
    private var kindMenu: some View {
        Menu {
            ForEach(Self.kindChoices) { kind in
                Button {
                    controller.setKind(kind)
                } label: {
                    if controller.currentKind == kind {
                        Label(kindTitle(kind), systemImage: "checkmark")
                    } else {
                        Text(kindTitle(kind))
                    }
                }
            }
        } label: {
            Text(kindChip(controller.currentKind ?? .paragraph))
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Text style")
    }

    private func kindTitle(_ kind: BlockKind) -> String {
        kind == .paragraph ? "Text" : kind.title
    }

    /// The compact chip label for the current kind.
    private func kindChip(_ kind: BlockKind) -> String {
        switch kind {
        case .heading1: "H1"
        case .heading2: "H2"
        case .heading3: "H3"
        case .heading4: "H4"
        case .heading5: "H5"
        case .heading6: "H6"
        default: "Aa"
        }
    }

    private func button(_ symbol: String, _ help: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(active ? Color.accentColor : .primary)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(active ? Color.accentColor.opacity(0.15) : .clear))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
