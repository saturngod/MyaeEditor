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

    // Floating format toolbar shown on text selection.
    @State private var formatBar = FormatBarController()

    @FocusState private var titleFocused: Bool

    private let space = "editor"

    /// Row frames are only needed while dragging to reorder or marquee-selecting.
    private var framesActive: Bool { draggingID != nil || marqueeStart != nil }

    init() {
        if let markdown = DocumentStore.load() {
            _document = State(initialValue: EditorDocument(blocks: MarkdownCodec.decode(markdown)))
            _lastSaved = State(initialValue: markdown)
        } else {
            _document = State(initialValue: EditorDocument(blocks: EditorView.sample))
            _lastSaved = State(initialValue: "")
        }
        _docTitle = State(initialValue: DocumentStore.loadTitle())
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
                                 onDragEnded: { draggingID = nil })
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
        .onAppear { installKeyMonitor() }
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
        .onReceive(NotificationCenter.default.publisher(for: .openMarkdown)) { _ in
            runOpenPanel()
        }
    }

    /// ⌘S — save to the open file, or prompt for a location if there isn't one.
    private func saveNow() {
        guard let url = fileURL else { runSaveAsPanel(); return }
        let markdown = MarkdownCodec.encode(document)
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
        lastSaved = markdown
    }

    /// Open an .md file. Its folder becomes the base for relative image paths.
    private func runOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.markdown, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            DocumentStore.currentFileURL = url      // set before decode so images resolve
            fileURL = url
            document.blocks = MarkdownCodec.decode(text)
            document.clearSelection()
            document.focusedBlockID = document.blocks.first?.id
            lastSaved = text
        }
    }

    /// Present a Save panel (async, so it reliably appears) and write Markdown.
    private func runSaveAsPanel() {
        let markdown = MarkdownCodec.encode(document)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "document.md"
        panel.allowedContentTypes = [.markdown]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
            DocumentStore.currentFileURL = url      // subsequent autosaves go here
            fileURL = url
            lastSaved = markdown
        }
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

    static var sample: [Block] {
        func p(_ s: String, _ kind: BlockKind = .paragraph, _ depth: Int = 0) -> Block {
            Block(kind: kind, text: NSAttributedString(
                string: s,
                attributes: BlockTextView.typingAttributes(for: kind)), depth: depth)
        }
        return [
            p("Welcome to your editor", .heading1),
            p("A native SwiftUI, block-based, WYSIWYG editor.", .paragraph),
            p("Things you can do", .heading2),
            p("Type / on an empty line to insert any block", .bulleted),
            p("Use # , ## , - , [] , > as you type to transform a line", .bulleted),
            p("Press Tab to indent, Shift+Tab to outdent", .bulleted),
            p("Nesting works at any depth", .bulleted, 1),
            p("Like this", .bulleted, 2),
            p("Press Enter for a new block, Backspace to merge or delete", .bulleted),
            p("Hover a block and drag the handle to reorder", .bulleted),
            p("Select text and press ⌘B / ⌘I for bold / italic", .bulleted),
            p("Try me", .todo),
            p("\"Simplicity is the ultimate sophistication.\"", .quote),
            p("// Pick a language from the menu above\nfunc greet(_ name: String) -> String {\n    return \"Hello, \\(name)!\"  // string interpolation\n}", .code),
            Block(kind: .table, table: TableData(cells: [
                ["Feature", "Status"],
                ["Tables", "Done"],
                ["Sync", "Planned"],
            ])),
            p(""),
        ]
    }
}

#Preview {
    EditorView().frame(width: 800, height: 700)
}
