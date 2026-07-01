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

    @ObservationIgnored private weak var activeTextView: AutoSizingTextView?
    @ObservationIgnored private var panel: NSPanel?

    // MARK: Show / hide

    /// Show the bar centered above `rect` (in screen coordinates) for `textView`.
    func show(textView: AutoSizingTextView, atScreenRect rect: NSRect) {
        activeTextView = textView
        refreshTraits()
        let panel = ensurePanel()
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
        self.panel = panel
        return panel
    }
}

/// The toolbar UI shown inside the floating panel.
struct FloatingFormatBar: View {
    @Bindable var controller: FormatBarController

    var body: some View {
        HStack(spacing: 1) {
            button("bold", "Bold", active: controller.isBold) { controller.toggleBold() }
            button("italic", "Italic", active: controller.isItalic) { controller.toggleItalic() }
            button("strikethrough", "Strikethrough", active: controller.isStrike) { controller.toggleStrike() }
            button("chevron.left.forwardslash.chevron.right", "Code", active: controller.isCode) { controller.toggleCode() }
        }
        .padding(3)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .padding(6)   // room for the shadow inside the (clear) panel
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
