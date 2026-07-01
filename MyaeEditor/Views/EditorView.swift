//
//  EditorView.swift
//  MyaeEditor
//
//  The document surface: a scrolling column of blocks with drag-to-reorder.
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

extension UTType {
    static var markdown: UTType { UTType(filenameExtension: "md") ?? .plainText }
}

extension Notification.Name {
    static let saveMarkdown = Notification.Name("saveMarkdown")
    static let saveAsMarkdown = Notification.Name("saveAsMarkdown")
    static let openMarkdown = Notification.Name("openMarkdown")
    static let newDocument = Notification.Name("newDocument")
}

/// One-shot hand-off used when Open is invoked with no window: the App stages the
/// chosen file here, opens a window, and the new `EditorView.init` consumes it.
enum LaunchIntent {
    static var pendingOpenURL: URL?
}

/// Collects each row's frame (in the editor coordinate space) so the drag
/// gesture can figure out where to drop.
struct RowFramePreference: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct EditorView: View {
    @State private var document: EditorDocument
    @State private var lastSaved: String
    @State private var docTitle: String
    /// The .md file currently open (nil = unsaved default document).
    @State private var fileURL: URL?

    // Gesture-based reorder state.
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var draggingID: UUID?

    // Marquee (drag-to-select) state.
    @State private var marqueeStart: CGFloat?
    @State private var keyMonitor: Any?

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

    /// True once the autosaved document has been restored into the first window
    /// of this launch. Later windows open blank instead of re-showing it.
    private static var didRestore = false

    init() {
        if let url = LaunchIntent.pendingOpenURL {
            // Open was invoked with no window — load the chosen file into this
            // freshly created window.
            LaunchIntent.pendingOpenURL = nil
            EditorView.didRestore = true
            DocumentStore.currentFileURL = url
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            _document = State(initialValue: EditorDocument(blocks: MarkdownCodec.decode(text)))
            _lastSaved = State(initialValue: text)
            _fileURL = State(initialValue: url)
            _docTitle = State(initialValue: url.deletingPathExtension().lastPathComponent)
        } else if !EditorView.didRestore, let markdown = DocumentStore.load() {
            // First window of the launch restores the autosaved document.
            EditorView.didRestore = true
            _document = State(initialValue: EditorDocument(blocks: MarkdownCodec.decode(markdown)))
            _lastSaved = State(initialValue: markdown)
            _docTitle = State(initialValue: DocumentStore.loadTitle())
        } else {
            // A new window starts as a blank page.
            EditorView.didRestore = true
            _document = State(initialValue: EditorDocument(blocks: EditorView.blankBlocks()))
            _lastSaved = State(initialValue: "")
            _docTitle = State(initialValue: "")
        }
    }

    var body: some View {
        // Compute numbered-list ordinals once per render, not once per row.
        let numbers = document.numberedOrdinals()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
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
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .center)
            .coordinateSpace(.named(space))
            .contentShape(Rectangle())
            .gesture(marqueeGesture)
            .onPreferenceChange(RowFramePreference.self) { rowFrames = $0 }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { installKeyMonitor(); updateWindowTitle() }
        .onDisappear { removeKeyMonitor(); formatBar.hide() }
        .onReceive(document.autosaveSignal) { _ in saveIfChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            saveIfChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveMarkdown)) { _ in
            saveNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveAsMarkdown)) { _ in
            runSaveAsPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMarkdown)) { note in
            if let url = note.object as? URL { loadFile(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newDocument)) { _ in
            newBlankDocument()
        }
    }

    /// ⌘S — save to the open file, or prompt for a location if there isn't one.
    private func saveNow() {
        guard let url = fileURL else { runSaveAsPanel(); return }
        let markdown = MarkdownCodec.encode(document)
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
        lastSaved = markdown
    }

    /// Load an .md file into this window. Its folder becomes the base for relative
    /// image paths. The App presents the Open panel and hands us the URL.
    private func loadFile(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        DocumentStore.currentFileURL = url      // set before decode so images resolve
        fileURL = url
        document.blocks = MarkdownCodec.decode(text)
        document.clearSelection()
        document.focusedBlockID = document.blocks.first?.id
        lastSaved = text
        updateWindowTitle()
    }

    /// Reset this window to an empty document (File ▸ New into an existing window).
    private func newBlankDocument() {
        DocumentStore.currentFileURL = nil
        fileURL = nil
        document.blocks = EditorView.blankBlocks()
        document.clearSelection()
        document.focusedBlockID = document.blocks.first?.id
        lastSaved = ""
        updateWindowTitle()
    }

    /// Present a Save panel and write Markdown.
    private func runSaveAsPanel() {
        let markdown = MarkdownCodec.encode(document)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "document.md"
        panel.allowedContentTypes = [.markdown]
        panel.canCreateDirectories = true
        // runModal (not the async .begin) so the panel reliably comes to front when
        // launched from the Save As menu command.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
        DocumentStore.currentFileURL = url      // subsequent autosaves go here
        fileURL = url
        lastSaved = markdown
        updateWindowTitle()
    }

    /// Reflect the open file's name in the window's title bar (and proxy icon).
    private func updateWindowTitle() {
        let window = NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
        guard let window else { return }
        window.representedURL = fileURL
        window.title = fileURL?.lastPathComponent ?? "MyaeEditor"
    }

    /// Serialize and write to disk only when the Markdown actually changed.
    private func saveIfChanged() {
        let markdown = MarkdownCodec.encode(document)
        guard markdown != lastSaved else { return }
        if let url = fileURL {
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        } else {
            DocumentStore.save(markdown)
        }
        lastSaved = markdown
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
                }
                document.selectBlocks(intersecting: marqueeStart!, value.location.y, frames: rowFrames)
            }
            .onEnded { _ in marqueeStart = nil }
    }

    // MARK: Block-selection key handling (Copy / Delete / Escape / Cmd+A)

    private func installKeyMonitor() {
        let doc = document
        let copy: () -> Void = { [weak doc] in
            guard let doc else { return }
            let selected = doc.selectedBlocksInOrder
            guard !selected.isEmpty else { return }
            let markdown = MarkdownCodec.encode(EditorDocument(blocks: selected))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !doc.selectedBlockIDs.isEmpty else { return event }
            let cmd = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case 53:                                   // Escape
                doc.clearSelection(); return nil
            case 51, 117:                              // Delete / Forward-delete
                doc.deleteSelectedBlocks(); return nil
            default: break
            }
            if cmd, event.charactersIgnoringModifiers == "a" {
                doc.selectAllBlocks(); return nil
            }
            if cmd, event.charactersIgnoringModifiers == "c" {
                copy(); return nil
            }
            if cmd, event.charactersIgnoringModifiers == "x" {
                copy(); doc.deleteSelectedBlocks(); return nil
            }
            if !cmd { doc.clearSelection() }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private var title: some View {
        TextField("Untitled", text: $docTitle)
            .textFieldStyle(.plain)
            .font(.system(size: 40, weight: .heavy))
            .foregroundStyle(.primary)
            .focused($titleFocused)
            .padding(.bottom, 28)
            .onSubmit {
                // Enter in the title jumps the caret into the first block.
                titleFocused = false
                if let first = document.blocks.first {
                    document.focusAtStart = true
                    document.focusedBlockID = first.id
                }
            }
            .onChange(of: docTitle) { _, new in DocumentStore.saveTitle(new) }
            .onChange(of: titleFocused) { _, focused in if focused { document.clearSelection() } }
    }

    /// A fresh, empty document: a single blank paragraph the caret can land in.
    static func blankBlocks() -> [Block] {
        [Block(kind: .paragraph,
               text: NSAttributedString(
                string: "",
                attributes: BlockTextView.typingAttributes(for: .paragraph)))]
    }
}

#Preview {
    EditorView().frame(width: 800, height: 700)
}
