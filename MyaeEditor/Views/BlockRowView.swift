//
//  BlockRowView.swift
//  MyaeEditor
//
//  Renders one block: drag handle + add button on hover, the type-specific
//  leading decoration (bullet / number / checkbox / quote bar), and the
//  editable text. Handles markdown shortcuts and the slash menu.
//

import SwiftUI
import AppKit
import CoreText

struct BlockRowView: View {
    @Bindable var document: EditorDocument
    @Bindable var block: Block
    /// Precomputed 1-based ordinal for a numbered block (see
    /// `EditorDocument.numberedOrdinals`), so the row doesn't scan the whole list.
    var number: Int? = nil
    @Binding var draggingID: UUID?
    var formatBar: FormatBarController
    /// Called continuously during a handle drag with the pointer Y in editor space.
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: () -> Void
    /// Text-selection drag began inside this block (arms row-frame collection).
    var onSelectionDragBegan: () -> Void = {}
    /// Selection drag escalated to whole-block selection: (localY, textHeight).
    var onSelectionDragChanged: (CGFloat, CGFloat) -> Void = { _, _ in }
    /// Selection drag ended.
    var onSelectionDragEnded: () -> Void = {}

    @State private var hovering = false
    @State private var showBlockMenu = false
    @State private var showSlashMenu = false
    @State private var slashQuery = ""
    /// Character index of the "/" that opened the menu, so the query and the
    /// removal target that exact command — not the last "/" in the block (which
    /// may be leftover text the user kept by pressing Esc).
    @State private var slashStart: Int?
    @State private var justCopied = false

    // Inline math editing.
    @State private var mathEditing = false
    @State private var mathLatex = ""
    @State private var mathEditRange: NSRange?

    private var isFocused: Bool { document.focusedBlockID == block.id }
    private var isSelected: Bool { document.selectedBlockIDs.contains(block.id) }

    private var rowBackground: Color {
        if isSelected { return Color(nsColor: .controlAccentColor).opacity(0.12) }
        return .clear   // no hover tint on any block
    }
    private var pendingCaret: Int? {
        document.pendingCaretLocation?.id == block.id ? document.pendingCaretLocation?.location : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            controls
                .padding(.top, controlsTop)
                .opacity(hovering || draggingID == block.id ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: hovering)
            content
                .padding(.leading, CGFloat(block.depth) * 24)
                .animation(.easeOut(duration: 0.12), value: block.depth)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, blockVerticalPadding)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5).fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private var blockVerticalPadding: CGFloat {
        switch block.kind {
        case .divider:  return 10
        case .heading1: return 6
        case .heading2: return 4
        case .heading3: return 3
        case .code:     return 3
        case .table:    return 3
        case .image:    return 3
        default:        return 2
        }
    }

    // MARK: Hover controls (add + drag handle)

    private var controls: some View {
        HStack(spacing: 0) {
            Button {
                let new = document.insertBlock(after: block, kind: .paragraph)
                document.focusedBlockID = new.id
            } label: {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Add a block below")

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12))
                .frame(width: 18, height: 24)
                .foregroundStyle(draggingID == block.id ? Color.accentColor : .secondary)
                .contentShape(Rectangle())
                .help("Click for options, drag to move")
                .accessibilityLabel("Block options")
                // A plain click opens the action menu; a drag reorders.
                .onTapGesture { showBlockMenu = true }
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("editor"))
                        .onChanged { value in
                            if draggingID != block.id {
                                draggingID = block.id
                                // Reordering invalidates any block-range selection
                                // (its anchor/lead positions shift), so drop it.
                                document.clearSelection()
                            }
                            onDragChanged(value.location.y)
                        }
                        .onEnded { _ in onDragEnded() }
                )
                .popover(isPresented: $showBlockMenu, arrowEdge: .leading) {
                    BlockActionMenu(document: document, block: block) {
                        showBlockMenu = false
                    }
                }
        }
    }

    // MARK: Block content

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .divider:
            // An explicit horizontal rule: a bare Divider() inside the row's
            // HStack would infer a vertical orientation and render as "|".
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                .padding(.vertical, 6)
                .layoutPriority(1)   // span the row width instead of yielding to the trailing spacer
        case .table:
            TableBlockView(document: document, block: block)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)   // fill the row width instead of yielding to the trailing spacer
        case .image:
            ImageBlockView(document: document, block: block)
                .padding(.vertical, 4)
        case .equation:
            EquationBlockView(document: document, block: block)
                .frame(maxWidth: .infinity, alignment: .center)
                .layoutPriority(1)
        case .code:
            if block.language == .mermaid && !isFocused && !block.isEmpty {
                MermaidBlockView(document: document, block: block)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)   // fill the row width, showing the diagram
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    codeHeader
                    textEditor
                }
                .padding(12)
                .background(codeBackground)
            }
        case .quote:
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 4)
                textEditor
            }
            .padding(.leading, 4)
            .fixedSize(horizontal: false, vertical: true)
        default:
            HStack(alignment: .top, spacing: 6) {
                leadingDecoration
                textEditor
            }
        }
    }

    // Language picker + copy button for code blocks.
    private var codeHeader: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(CodeLanguage.allCases) { lang in
                    Button(lang.displayName) { block.language = lang; document.markEdited() }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(block.language.displayName)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(block.plainText, forType: .string)
                withAnimation(.easeInOut(duration: 0.15)) { justCopied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeInOut(duration: 0.2)) { justCopied = false }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    if justCopied { Text("Copied") }
                }
                .foregroundStyle(justCopied ? Color.green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Copy code")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    /// Shared width for every list marker (bullet / number / checkbox). Using one
    /// width with trailing alignment makes the markers line up with each other and
    /// keeps every list's text column at the same left edge.
    private let markerWidth: CGFloat = 24
    /// Fixed box for the todo checkbox, so its vertical centering is exact rather
    /// than dependent on the SF Symbol's implicit rendered size.
    private let checkboxSize: CGFloat = 16

    /// Memo for `typographic`, keyed by font name+size and the probe text. Marker
    /// alignment measures the same few (font, probe) pairs on every row render, and
    /// a focus/selection change re-renders every visible row — so caching turns the
    /// repeated CTLine builds into dictionary lookups. Main-thread only.
    private struct TypographicKey: Hashable { let font: String; let size: CGFloat; let text: String }
    private static var typographicCache: [TypographicKey: (ascent: CGFloat, height: CGFloat)] = [:]

    /// Typographic ascent + full height of `text` in `font`, via CoreText.
    private func typographic(_ font: NSFont, _ text: String) -> (ascent: CGFloat, height: CGFloat) {
        let key = TypographicKey(font: font.fontName, size: font.pointSize, text: text)
        if let cached = Self.typographicCache[key] { return cached }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let result = (ascent, ascent + descent + leading)
        // The probe text varies with content (a line's first 20 chars), so bound
        // the cache; clearing wholesale is fine — it just re-measures on demand.
        if Self.typographicCache.count > 256 { Self.typographicCache.removeAll(keepingCapacity: true) }
        Self.typographicCache[key] = result
        return result
    }

    /// Distance from the top of the text view down to the first line's baseline.
    /// Burmese and other complex scripts have a much larger ascent than Latin, so
    /// their baseline sits far lower; measuring the block's own text lets us drop
    /// each marker to that baseline instead of leaving it pinned near the top.
    private var textBaseline: CGFloat {
        // An empty block renders its line at the font's natural (Latin) height, so
        // probe with Latin here. Using a Burmese glyph would overstate the ascent and
        // drop the marker below the empty line until the first character is typed.
        let probe = block.plainText.isEmpty ? "Ag" : String(block.plainText.prefix(20))
        return 2 + typographic(block.kind.baseFont, probe).ascent   // 2 = textContainerInset.height
    }

    /// Top padding that drops a marker so its bottom lands on the text baseline.
    /// Right for a round bullet dot, whose visual center sits near mid x-height.
    private func markerTop(font: NSFont, glyph: String) -> CGFloat {
        max(0, textBaseline - typographic(font, glyph).height)
    }

    /// Top padding that drops a marker so its own baseline lands on the text
    /// baseline. Use for numbers, whose baseline (not bottom) must match the text.
    private func markerBaselineTop(font: NSFont, glyph: String) -> CGFloat {
        max(0, textBaseline - typographic(font, glyph).ascent)
    }

    /// Top padding that drops the hover controls so their center lands on the
    /// first line's visual middle. The controls sit in a fixed 24pt-tall box
    /// pinned to the row top; for tall lines (H1/H2) that leaves the "+" near the
    /// top of the line instead of centered, so nudge it down to match the text.
    private var controlsTop: CGFloat {
        let lineCenter = textBaseline - block.kind.baseFont.capHeight / 2
        return max(0, lineCenter - 12)   // 12 = half the controls' 24pt height
    }

    @ViewBuilder
    private var leadingDecoration: some View {
        switch block.kind {
        case .bulleted:
            Text(bulletGlyph)
                .font(.system(size: bulletFontSize))
                .frame(width: markerWidth, alignment: .trailing)
                .padding(.top, markerTop(font: .systemFont(ofSize: bulletFontSize), glyph: bulletGlyph))
        case .numbered:
            Text("\(number ?? document.number(for: block)).")
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: markerWidth, alignment: .trailing)
                .padding(.top, markerBaselineTop(font: .systemFont(ofSize: 15), glyph: "0"))
        case .todo:
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) { block.checked.toggle() }
                document.markEdited()
            } label: {
                Image(systemName: block.checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .frame(width: checkboxSize, height: checkboxSize)   // known box, so centering is exact
                    .foregroundStyle(block.checked ? Color.accentColor : Color.secondary.opacity(0.55))
                    .symbolEffect(.bounce, value: block.checked)
            }
            .buttonStyle(.plain)
            .frame(width: markerWidth, alignment: .trailing)
            // Put the checkbox's center half a cap-height above the baseline (the
            // text's visual middle, roughly constant across scripts), then lift it
            // by half its own height so its center — not its box top — lands there.
            .padding(.top, max(0, textBaseline - block.kind.baseFont.capHeight / 2 - checkboxSize / 2))
        default:
            EmptyView()
        }
    }

    private var textEditor: some View {
        BlockTextView(
            text: $block.text,
            kind: block.kind,
            language: block.language,
            isFocused: isFocused,
            focusAtStart: isFocused && document.focusAtStart,
            pendingCaretLocation: pendingCaret,
            formatBar: formatBar,
            onEnter: handleEnter,
            onShiftEnter: { false },          // let NSTextView insert a soft newline
            onBackspaceAtStart: handleBackspaceAtStart,
            onArrowUpAtTop: { moveFocus(up: true) },
            onArrowDownAtBottom: { moveFocus(up: false) },
            onExtendSelectionUp: { document.extendBlockSelection(up: true, from: block.id); return true },
            onExtendSelectionDown: { document.extendBlockSelection(up: false, from: block.id); return true },
            onTab: { document.indent(block); return true },          // always consume Tab
            onShiftTab: { document.outdent(block); return true },     // always consume Shift-Tab
            onSlash: { loc in showSlashMenu = true; slashQuery = ""; slashStart = loc },
            onFocused: {
                document.clearSelection()   // editing a block ends any block selection
                if document.focusedBlockID != block.id { document.focusedBlockID = block.id }
            },
            onSelectAllBlocks: { document.selectAllBlocks() },
            onCaretApplied: { document.pendingCaretLocation = nil },
            onFocusApplied: { document.focusAtStart = false },
            onEditMath: { range, latex in
                mathEditRange = range
                mathLatex = latex
                mathEditing = true
            },
            onSelectionDragBegan: onSelectionDragBegan,
            onSelectionDragChanged: onSelectionDragChanged,
            onSelectionDragEnded: onSelectionDragEnded
        )
        .strikethrough(block.kind == .todo && block.checked)
        .opacity(block.kind == .todo && block.checked ? 0.55 : 1)
        .onChange(of: block.text) { _, _ in
            document.markEdited()
            if showSlashMenu { syncSlashMenuQuery() } else { applyMarkdownShortcut() }
        }
        .popover(isPresented: $showSlashMenu, arrowEdge: .bottom) {
            SlashMenu(query: $slashQuery) { kind in
                selectSlashKind(kind)
            } onDismiss: {
                // Esc just closes the menu; leave the typed "/" (and any query)
                // in place so the user can keep editing it.
                showSlashMenu = false
                slashStart = nil
                document.focusedBlockID = block.id
            }
        }
        .popover(isPresented: $mathEditing, arrowEdge: .bottom) {
            MathEditor(latex: $mathLatex, fontSize: block.kind.baseFont.pointSize) { latex in
                commitMath(latex)
            }
        }
    }

    @ViewBuilder
    private var codeBackground: some View {
        if block.kind == .code {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
        }
    }

    // Bullet style cycles by depth: ● ○ ◇
    private var bulletGlyph: String {
        switch block.depth % 3 {
        case 1:  return "○"
        case 2:  return "◇"
        default: return "●"
        }
    }

    private var bulletFontSize: CGFloat {
        switch block.depth % 3 {
        case 0: return 12
        case 1: return 14
        case 2: return 12
        default: return 12
        }
    }

    // MARK: Key handling

    private func handleEnter() -> Bool {
        // In an empty list/todo item, Enter outdents one level, then exits to a paragraph.
        if block.kind.continuesOnEnter && block.isEmpty {
            if block.depth > 0 {
                block.depth -= 1
                document.markEdited()
                return true
            }
            block.kind = .paragraph
            document.markEdited()
            return true
        }
        let nextKind: BlockKind = block.kind.continuesOnEnter ? block.kind : .paragraph
        let new = document.insertBlock(after: block, kind: nextKind)
        document.focusedBlockID = new.id
        return true
    }

    private func handleBackspaceAtStart() -> Bool {
        // Outdent first if the block is nested.
        if block.depth > 0 {
            block.depth -= 1
            document.markEdited()
            return true
        }
        // Then demote a styled block back to paragraph.
        if block.kind != .paragraph {
            block.kind = .paragraph
            document.markEdited()
            return true
        }
        if block.isEmpty {
            document.deleteAndFocusPrevious(block)
            return true
        }
        return document.mergeIntoPrevious(block)
    }

    private func moveFocus(up: Bool) -> Bool {
        let target = up ? document.block(before: block) : document.block(after: block)
        guard let target else { return false }
        document.focusAtStart = !up   // entering from top => caret at start
        document.focusedBlockID = target.id
        return true
    }

    /// The "/command" range anchored at `slashStart`: the "/" plus everything up
    /// to the next "/" (or end). Returns nil if the recorded "/" is gone (user
    /// deleted or edited past it), which means the menu should close.
    private func slashCommandRange() -> NSRange? {
        guard let start = slashStart else { return nil }
        let ns = block.plainText as NSString
        guard start >= 0, start < ns.length, ns.character(at: start) == 47 else { return nil }  // 47 = "/"
        var end = start + 1
        while end < ns.length, ns.character(at: end) != 47 { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// While the slash menu is open, the text after the anchored "/" drives the
    /// menu filter. If that "/" is gone, close the menu.
    private func syncSlashMenuQuery() {
        guard let r = slashCommandRange() else { showSlashMenu = false; return }
        let ns = block.plainText as NSString
        slashQuery = ns.substring(with: NSRange(location: r.location + 1, length: r.length - 1))
    }

    /// Delete the "/query" the user typed to open the menu (anchored at
    /// `slashStart`, up to the next "/"), leaving surrounding text intact.
    private func removeSlashCommand() {
        guard let del = slashCommandRange() else { return }
        let m = NSMutableAttributedString(attributedString: block.text)
        m.deleteCharacters(in: del)
        block.text = m
    }

    private func selectSlashKind(_ kind: BlockKind) {
        showSlashMenu = false
        removeSlashCommand()
        slashStart = nil
        switch kind {
        case .inlineMath:
            mathEditRange = nil
            mathLatex = ""
            mathEditing = true
        case .divider:
            block.kind = .divider
            let new = document.insertBlock(after: block, kind: .paragraph)
            document.focusedBlockID = new.id
        case .table:
            block.kind = .table
            block.text = NSAttributedString(string: "")
            if block.table == nil { block.table = TableData() }
            let new = document.insertBlock(after: block, kind: .paragraph)
            document.focusedBlockID = new.id
        case .image:
            block.kind = .image
            block.text = NSAttributedString(string: "")
            let new = document.insertBlock(after: block, kind: .paragraph)
            document.focusedBlockID = new.id
        case .equation:
            block.kind = .equation
            block.text = NSAttributedString(string: "")   // EquationBlockView auto-opens its editor
            document.insertBlock(after: block, kind: .paragraph)
        default:
            restyle(to: kind)
            document.focusedBlockID = block.id
        }
    }

    /// Insert a new math attachment (or replace the one being edited) and close.
    private func commitMath(_ latex: String) {
        mathEditing = false
        let trimmed = latex.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { mathEditRange = nil; return }
        let math = InlineMath.attributedString(latex: trimmed,
                                               fontSize: block.kind.baseFont.pointSize,
                                               kind: block.kind)
        let m = NSMutableAttributedString(attributedString: block.text)
        if let range = mathEditRange, range.location + range.length <= m.length {
            m.replaceCharacters(in: range, with: math)
        } else {
            m.append(math)
        }
        block.text = m
        mathEditRange = nil
        document.focusedBlockID = block.id
    }

    // MARK: Markdown shortcuts ("# ", "- ", "[] ", etc.)

    // NOTE: fires on EVERY change to block.text — including programmatic
    // mutations (e.g. syntax highlighting writing back). The `kind == .paragraph`
    // guard keeps it safe; keep detection cheap and side-effect-free here.
    private static let markdownShortcuts: [(String, BlockKind)] = [
        ("# ", .heading1), ("## ", .heading2), ("### ", .heading3),
        ("- ", .bulleted), ("* ", .bulleted), ("1. ", .numbered),
        ("[] ", .todo), ("[ ] ", .todo), ("> ", .quote), ("```", .code),
    ]

    private func applyMarkdownShortcut() {
        guard block.kind == .paragraph else { return }
        let s = block.plainText
        for (prefix, kind) in Self.markdownShortcuts where s == prefix {
            block.text = NSAttributedString(string: "")
            restyle(to: kind)
            document.focusedBlockID = block.id
            return
        }
    }

    /// Change the block's kind and re-apply the base font to its existing text,
    /// preserving bold/italic traits.
    private func restyle(to kind: BlockKind) {
        block.kind = kind
        let mutable = NSMutableAttributedString(attributedString: block.text)
        let full = NSRange(location: 0, length: mutable.length)
        let base = kind.baseFont
        mutable.enumerateAttribute(.font, in: full) { value, range, _ in
            let traits = (value as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            var newFont = base
            if traits.contains(.boldFontMask) {
                newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .boldFontMask)
            }
            if traits.contains(.italicFontMask) {
                newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .italicFontMask)
            }
            mutable.addAttribute(.font, value: newFont, range: range)
        }
        // Reset any syntax-highlight colors when this isn't a code block; the
        // highlighter re-applies colors for code blocks itself.
        if kind != .code {
            let color: NSColor = (kind == .quote) ? .secondaryLabelColor : .textColor
            mutable.addAttribute(.foregroundColor, value: color, range: full)
        }
        block.text = mutable
    }
}
