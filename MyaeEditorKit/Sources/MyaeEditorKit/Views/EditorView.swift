//
//  EditorView.swift
//  MyaeEditorKit
//
//  The document surface: a scrolling column of blocks with drag-to-reorder.
//  Driven by a `MyaeEditorController` (which owns the document + file I/O); this
//  view is purely the editing UI.
//

import SwiftUI
import AppKit
import Combine

/// Collects each row's frame (in the editor coordinate space) so the drag
/// gesture can figure out where to drop.
struct RowFramePreference: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// A mutable reference cell for the hosting NSWindow, captured (weakly) by the
/// key monitor so it can scope events to its own window. Also carries the live
/// editability flag so the long-lived monitor closure follows configuration
/// changes instead of freezing the value captured at install time.
final class WindowBox {
    weak var window: NSWindow?
    var isEditable = true
}

/// Resolves the NSWindow that hosts this SwiftUI view and reports it back.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in onResolve(v?.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in onResolve(nsView?.window) }
    }
}

struct EditorView: View {
    let controller: MyaeEditorController
    let configuration: MyaeEditorConfiguration

    /// The live document — owned by the controller.
    private var document: EditorDocument { controller.document }

    // Gesture-based reorder state.
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var draggingID: UUID?

    // Marquee (drag-to-select) state.
    @State private var marqueeStart: CGFloat?
    @State private var keyMonitor: Any?
    /// Holds this view's hosting window so the app-wide key monitor can ignore
    /// events belonging to other windows or panels.
    @State private var windowBox = WindowBox()

    // Cross-block text-selection drag (escalates to whole-block selection).
    @State private var crossDragging = false
    @State private var crossAnchorID: UUID?

    // Floating format toolbar shown on text selection.
    @State private var formatBar = FormatBarController()

    @FocusState private var titleFocused: Bool

    private let space = "editor"

    /// Row frames are only needed while dragging to reorder, marquee-selecting, or
    /// running a cross-block text-selection drag.
    private var framesActive: Bool { draggingID != nil || marqueeStart != nil || crossDragging }

    init(controller: MyaeEditorController, configuration: MyaeEditorConfiguration = MyaeEditorConfiguration()) {
        self.controller = controller
        self.configuration = configuration
    }

    var body: some View {
        // Compute numbered-list ordinals once per render, not once per row.
        let numbers = document.numberedOrdinals()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if configuration.showsTitleField { title }

                ForEach(document.blocks) { block in
                    BlockRowView(document: document,
                                 block: block,
                                 number: numbers[block.id],
                                 draggingID: $draggingID,
                                 formatBar: formatBar,
                                 onDragChanged: { y in reorder(toY: y) },
                                 onDragEnded: { draggingID = nil },
                                 onSelectionDragBegan: { crossDragging = true; crossAnchorID = block.id },
                                 onSelectionDragChanged: { localY, h in crossDrag(localY: localY, textHeight: h) },
                                 onSelectionDragEnded: { crossDragging = false; crossAnchorID = nil })
                        // Measure row frames only during an active drag/marquee.
                        // When idle there's no GeometryReader, so scrolling a large
                        // document doesn't churn the rowFrames preference every pass.
                        .background(alignment: .topLeading) {
                            if framesActive { rowFrameReader(for: block) }
                        }
                        .opacity(draggingID == block.id ? 0.35 : 1)
                }

                // Trailing zone: click to add a block at the end.
                Color.clear
                    .frame(height: 120)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard configuration.isEditable else { return }
                        document.clearSelection()
                        guard let last = document.blocks.last else { return }
                        // A divider renders no text view, so it can't take focus —
                        // append a paragraph instead of focusing it.
                        if last.isEmpty && last.kind != .divider {
                            document.focusAtStart = false
                            document.focusedBlockID = last.id
                        } else {
                            let new = document.insertBlock(after: last, kind: .paragraph)
                            document.focusedBlockID = new.id
                        }
                    }
            }
            .frame(maxWidth: configuration.maxContentWidth, alignment: .leading)
            .padding(.horizontal, configuration.horizontalPadding)
            .padding(.vertical, configuration.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .center)
            .coordinateSpace(.named(space))
            .contentShape(Rectangle())
            .gesture(marqueeGesture)
            .onPreferenceChange(RowFramePreference.self) { rowFrames = $0 }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .background(WindowAccessor { window in
            // Resolves asynchronously after onAppear — set the initial title here,
            // or a window opened directly onto a file would never show its name.
            windowBox.window = window
            updateWindowTitle()
        })
        .environment(\.myaeConfiguration, configuration)
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor(); formatBar.hide() }
        .onChange(of: controller.fileURL) { _, _ in updateWindowTitle() }
        .onChange(of: configuration.isEditable) { _, editable in windowBox.isEditable = editable }
    }

    /// Reflect the open file's name in the hosting window's title bar (and proxy
    /// icon). Scoped to this view's own window so multi-window apps stay correct.
    private func updateWindowTitle() {
        guard configuration.managesWindowTitle, let window = windowBox.window else { return }
        window.representedURL = controller.fileURL
        window.title = controller.fileURL?.lastPathComponent ?? "MyaeEditor"
    }

    private func rowFrameReader(for block: Block) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: RowFramePreference.self,
                value: [block.id: geo.frame(in: .named(space))])
        }
    }

    /// Reorder the dragged block to wherever the pointer (`y`, in editor space) is.
    /// Under LazyVStack `rowFrames` only holds built (roughly visible) rows, so
    /// reorder targets whatever is on screen — which is all the user can aim at
    /// anyway (there's no drag auto-scroll).
    private func reorder(toY y: CGFloat) {
        guard let draggingID else { return }
        let others = document.blocks.filter { $0.id != draggingID }
        var index = others.count
        for (i, b) in others.enumerated() {
            if let f = rowFrames[b.id], y < f.midY { index = i; break }
        }
        // Only mutate when the target slot actually changes, to avoid churn.
        let desiredID = index < others.count ? others[index].id : nil
        let currentIndex = document.blocks.firstIndex { $0.id == draggingID }
        let currentNextID = currentIndex.flatMap { document.blocks.indices.contains($0 + 1) ? document.blocks[$0 + 1].id : nil }
        if desiredID == draggingID || desiredID == currentNextID { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            document.move(id: draggingID, toIndexAmongOthers: index)
        }
    }

    /// Drive whole-block selection from an escalated cross-block text drag. `localY`
    /// is the pointer's Y in the anchor text view's coords; we translate it to
    /// editor space off the edge it exited so row padding introduces no error, then
    /// select every block between the anchor's mid and the pointer.
    private func crossDrag(localY: CGFloat, textHeight: CGFloat) {
        guard let anchorID = crossAnchorID, let f = rowFrames[anchorID] else { return }
        let pointerY = localY < 0 ? f.minY + localY : f.maxY + (localY - textHeight)
        document.selectBlocks(intersecting: f.midY, pointerY, frames: rowFrames)
        formatBar.hide()
    }

    // MARK: Marquee drag-to-select

    /// Dragging across the gutter / margins selects whole blocks. (Drags that
    /// start on a text view are consumed by AppKit, so this only fires on the
    /// empty areas around blocks — exactly where a marquee should begin.)
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(space))
            .onChanged { value in
                guard draggingID == nil else { return }   // not while reordering a block
                if marqueeStart == nil {
                    marqueeStart = value.startLocation.y
                    titleFocused = false
                    formatBar.hide()
                    // Drop any text caret so the block selection stands alone and
                    // the key monitor (not the text view) handles Shift+Arrow.
                    windowBox.window?.makeFirstResponder(nil)
                }
                document.selectBlocks(intersecting: marqueeStart!, value.location.y, frames: rowFrames)
            }
            .onEnded { _ in marqueeStart = nil }
    }

    // MARK: Block-selection key handling (Copy / Delete / Escape / Cmd+A)

    private func installKeyMonitor() {
        let copy: (EditorDocument) -> Void = { doc in
            let selected = doc.selectedBlocksInOrder
            guard !selected.isEmpty else { return }
            let markdown = MarkdownCodec.encode(EditorDocument(blocks: selected))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
        }
        // Key codes are physical (layout-independent), so Cmd+A works on any
        // keyboard layout — unlike matching charactersIgnoringModifiers.
        let A: UInt16 = 0, C: UInt16 = 8, X: UInt16 = 7, V: UInt16 = 9
        let up: UInt16 = 126, down: UInt16 = 125
        let box = windowBox
        box.isEditable = configuration.isEditable
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak document] event in
            guard let doc = document else { return event }
            // Local monitors are app-wide: only act on events for this editor's
            // own window, never panels (Open/Save) or other editor windows.
            guard let w = event.window, w === box.window else { return event }
            let mods = event.modifierFlags
            let cmd = mods.contains(.command)
            let editingText = w.firstResponder is NSTextView

            // Cmd+A with no text field focused: select every block so the whole
            // document can be deleted/copied without dragging. While a text block
            // is focused, BlockTextView handles Cmd+A itself (select the block's
            // text first, then escalate to all blocks on a second press).
            if cmd, event.keyCode == A, !editingText {
                doc.selectAllBlocks(); return nil
            }
            guard !doc.selectedBlockIDs.isEmpty else { return event }

            switch event.keyCode {
            case 53:                                   // Escape
                doc.clearSelection(); return nil
            case 51, 117:                              // Delete / Forward-delete
                if box.isEditable { doc.deleteSelectedBlocks() }; return nil
            default: break
            }
            // Shift+Up / Shift+Down (Shift alone) extend the block selection.
            // Other chords (Cmd/Opt/Ctrl+Shift+Arrow) fall through to the system.
            let onlyShift = mods.contains(.shift)
                && mods.isDisjoint(with: [.command, .option, .control])
            if onlyShift, event.keyCode == up { doc.extendBlockSelection(up: true); return nil }
            if onlyShift, event.keyCode == down { doc.extendBlockSelection(up: false); return nil }

            if cmd, event.keyCode == A { doc.selectAllBlocks(); return nil }
            if cmd, event.keyCode == C { copy(doc); return nil }
            if cmd, event.keyCode == X { copy(doc); if box.isEditable { doc.deleteSelectedBlocks() }; return nil }
            // Paste over a block selection replaces it (Shift not distinguished —
            // literal vs parsed is meaningless when replacing whole blocks).
            if cmd, event.keyCode == V, box.isEditable {
                if let raw = NSPasteboard.general.string(forType: .string) {
                    doc.replaceSelectedBlocks(with: MarkdownCodec.decodeForPaste(raw))
                }
                return nil
            }

            // A bare keypress (no Cmd, no Shift) collapses the selection; Shift is
            // spared so an unhandled Shift+Arrow doesn't silently wipe it.
            if !cmd, !mods.contains(.shift) { doc.clearSelection() }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private var title: some View {
        TextField("Untitled", text: Binding(
            get: { controller.documentTitle },
            set: { controller.documentTitle = $0 }))
            .textFieldStyle(.plain)
            .font(.system(size: 40, weight: .heavy))
            .foregroundStyle(.primary)
            .focused($titleFocused)
            .padding(.bottom, 28)
            .disabled(!configuration.isEditable)
            .onSubmit {
                // Enter in the title jumps the caret into the first block.
                titleFocused = false
                if let first = document.blocks.first {
                    document.focusAtStart = true
                    document.focusedBlockID = first.id
                }
            }
            .onChange(of: titleFocused) { _, focused in if focused { document.clearSelection() } }
    }
}
