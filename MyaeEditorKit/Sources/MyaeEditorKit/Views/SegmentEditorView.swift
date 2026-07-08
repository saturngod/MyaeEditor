//
//  SegmentEditorView.swift
//  MyaeEditor
//
//  The continuous document surface: a scrolling column of segments. Text segments
//  are editable multi-paragraph runs; widgets render between them. Driven by a
//  `MyaeEditorController` (which owns the document + file I/O).
//

import SwiftUI
import AppKit

/// A mutable reference cell for the hosting NSWindow, captured (weakly) by the
/// key monitor so it can scope events to its own window. Also carries the live
/// editability flag so the long-lived monitor closure follows configuration.
private final class SegmentWindowBox {
    weak var window: NSWindow?
    var isEditable = true
}

/// Resolves the NSWindow that hosts this SwiftUI view and reports it back.
private struct SegmentWindowAccessor: NSViewRepresentable {
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

struct SegmentEditorView: View {
    let controller: MyaeEditorController
    let configuration: MyaeEditorConfiguration

    private var document: SegmentDocument { controller.document }

    @State private var formatBar = FormatBarController()
    @State private var window: NSWindow?
    @State private var keyMonitor: Any?
    @State private var windowBox = SegmentWindowBox()
    /// Full editor width, so wide tables can break out of the text column
    /// (Notion-style) instead of scrolling inside it.
    @State private var fullWidth: CGFloat = 0
    @FocusState private var titleFocused: Bool

    init(controller: MyaeEditorController,
         configuration: MyaeEditorConfiguration = MyaeEditorConfiguration()) {
        self.controller = controller
        self.configuration = configuration
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if configuration.showsTitleField { title }

                ForEach(document.segments) { segment in
                    segmentView(segment)
                        // Whole-document selection tint (Cmd+A twice).
                        .overlay {
                            if document.selectedSegmentIDs.contains(segment.id) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.accentColor.opacity(0.12))
                                    .allowsHitTesting(false)
                            }
                        }
                }

                Color.clear
                    .frame(height: 80)
                    .contentShape(Rectangle())
                    .onTapGesture { focusLastText() }
            }
            .frame(maxWidth: configuration.maxContentWidth, alignment: .leading)
            .padding(.horizontal, configuration.horizontalPadding)
            .padding(.vertical, configuration.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { fullWidth = $0 }
        .background(Color(nsColor: .textBackgroundColor))
        .background(SegmentWindowAccessor { win in
            window = win
            windowBox.window = win
            updateWindowTitle()
        })
        .environment(\.myaeConfiguration, configuration)
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor(); formatBar.hide() }
        .onChange(of: controller.fileURL) { _, _ in updateWindowTitle() }
        .onChange(of: configuration.isEditable) { _, editable in windowBox.isEditable = editable }
    }

    // MARK: Whole-document selection key handling (Copy / Cut / Delete / Escape / Cmd+A)

    private func installKeyMonitor() {
        let copy: (SegmentDocument) -> Void = { doc in
            let selected = doc.selectedSegmentsInOrder
            guard !selected.isEmpty else { return }
            let markdown = SegmentCodec.encode(selected)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
        }
        // Physical key codes so shortcuts work on any keyboard layout.
        let A: UInt16 = 0, C: UInt16 = 8, X: UInt16 = 7, V: UInt16 = 9
        let box = windowBox
        box.isEditable = configuration.isEditable
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak document] event in
            guard let doc = document else { return event }
            // App-wide monitor: only act on this editor's own window.
            guard let w = event.window, w === box.window else { return event }
            let mods = event.modifierFlags
            let cmd = mods.contains(.command)
            let editingText = w.firstResponder is NSTextView

            // Cmd+A with no text view focused selects the whole document. While a
            // text run is focused, the text view handles Cmd+A itself (select the
            // run first, escalate on second press).
            if cmd, event.keyCode == A, !editingText {
                doc.selectAllSegments(); return nil
            }
            guard !doc.selectedSegmentIDs.isEmpty else { return event }

            switch event.keyCode {
            case 53:                                   // Escape
                doc.clearSelection(); return nil
            case 51, 117:                              // Delete / Forward-delete
                if box.isEditable { doc.deleteSelectedSegments() }; return nil
            default: break
            }

            if cmd, event.keyCode == A { doc.selectAllSegments(); return nil }
            if cmd, event.keyCode == C { copy(doc); return nil }
            if cmd, event.keyCode == X { copy(doc); if box.isEditable { doc.deleteSelectedSegments() }; return nil }
            if cmd, event.keyCode == V, box.isEditable {
                if let raw = NSPasteboard.general.string(forType: .string) {
                    doc.replaceSelectedSegments(with: SegmentCodec.decodeForPaste(raw))
                }
                return nil
            }

            // A bare keypress (no Cmd, no Shift) collapses the selection.
            if !cmd, !mods.contains(.shift) { doc.clearSelection() }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    @ViewBuilder
    private func segmentView(_ segment: Segment) -> some View {
        switch segment.payload {
        case .text(let storage):
            TextSegmentContainer(segment: segment,
                                 storage: storage,
                                 document: document,
                                 configuration: configuration,
                                 formatBar: formatBar)

        case .code:
            SegmentCodeView(segment: segment,
                            document: document,
                            isFocused: document.focusedSegmentID == segment.id,
                            rendersMermaid: configuration.rendersMermaid)

        case .table(let table):
            breakoutTable(segment, table)

        case .image(let path):
            SegmentImageView(segment: segment, document: document, path: path)

        case .equation(let latex):
            SegmentEquationView(segment: segment, document: document, latex: latex)

        case .divider:
            SegmentDividerView()
        }
    }

    /// A table that needs more room than the text column breaks out of it
    /// (Notion-style): it widens beyond the column — centered on the page — up
    /// to near the window edges, and only scrolls horizontally past that.
    @ViewBuilder
    private func breakoutTable(_ segment: Segment, _ table: TableData) -> some View {
        let columnW = fullWidth > 0
            ? min(configuration.maxContentWidth, max(fullWidth - 2 * configuration.horizontalPadding, 200))
            : configuration.maxContentWidth
        let needed = CGFloat(table.columnCount) * 120 + 26   // min col width + add-column button
        let margin: CGFloat = 44                              // window-edge margin (room for row handles)
        let avail = fullWidth > 0 ? max(fullWidth - 2 * margin, columnW) : columnW
        let width = min(max(needed, columnW), avail)

        TableBlockView(table: table,
                       formatBar: formatBar,
                       onEdited: { document.markEdited() },
                       onDelete: { document.removeWidget(segment.id) },
                       onExit: { down in
                           down ? document.focusDown(from: segment.id)
                                : document.focusUp(from: segment.id)
                       })
            .frame(width: width)
            .offset(x: -(width - columnW) / 2)   // keep the wide table page-centered
    }

    private func focusLastText() {
        guard configuration.isEditable else { return }
        if let last = document.segments.last(where: { $0.isText }) {
            document.focusAtStart = false
            document.focusedSegmentID = last.id
        }
    }

    private func updateWindowTitle() {
        guard configuration.managesWindowTitle, let window else { return }
        window.representedURL = controller.fileURL
        window.title = controller.fileURL?.lastPathComponent ?? "MyaeEditor"
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
                titleFocused = false
                if let first = document.segments.first(where: { $0.isText }) {
                    document.focusAtStart = true
                    document.focusedSegmentID = first.id
                }
            }
    }
}

// MARK: - Text segment container (text view + slash menu + inline-math popovers)

private struct TextSegmentContainer: View {
    let segment: Segment
    let storage: NSTextStorage
    let document: SegmentDocument
    let configuration: MyaeEditorConfiguration
    let formatBar: FormatBarController

    @State private var slash = SlashMenuState()
    @State private var mathEditing = false
    @State private var mathDraft = ""
    @State private var mathCaret = 0
    /// When set, the math popover edits this existing attachment instead of
    /// inserting a new one.
    @State private var mathEditRange: NSRange?

    // Link editor popup state.
    @State private var linkEditing = false
    @State private var linkRange: NSRange?
    @State private var linkTextDraft = ""
    @State private var linkURLDraft = ""
    @State private var linkAnchor = CGRect.zero

    var body: some View {
        SegmentTextView(
            storage: storage,
            isFocused: document.focusedSegmentID == segment.id,
            focusAtStart: document.focusAtStart && document.focusedSegmentID == segment.id,
            pendingCaretLocation: document.pendingCaretLocation?.id == segment.id
                ? document.pendingCaretLocation?.location : nil,
            formatBar: formatBar,
            isEditable: configuration.isEditable,
            showsFormatBar: configuration.showsFormatBar,
            onEdited: { document.markEdited() },
            onFocused: {
                document.selectedSegmentIDs = []
                document.focusedSegmentID = segment.id
            },
            onFocusApplied: { document.focusAtStart = false },
            onCaretApplied: { document.pendingCaretLocation = nil },
            onCreateCodeBlock: { pr, lang in
                document.convertParagraphToCodeBlock(inSegment: segment.id, paragraphRange: pr, language: lang)
            },
            onPasteSegments: { caret, pasted in
                document.spliceSegments(inSegment: segment.id, atCaret: caret, insert: pasted)
            },
            onBackspaceAtStart: {
                document.deletePrecedingWidget(before: segment.id)
            },
            onArrowUp: { document.focusUp(from: segment.id) },
            onArrowDown: { document.focusDown(from: segment.id) },
            onSelectAllSegments: { document.selectAllSegments() },
            showsSlashMenu: configuration.showsSlashMenu && configuration.isEditable,
            slashState: slash,
            onSlashWidget: { kind, caret in insertWidget(kind, at: caret) },
            onSlashMath: { caret in
                mathCaret = caret
                mathDraft = ""
                mathEditRange = nil
                mathEditing = true
            },
            onEditMath: { range, latex in
                mathEditRange = range
                mathDraft = latex
                mathEditing = true
            },
            onEditLink: { range, text, url, anchor in
                linkRange = range
                linkTextDraft = text
                linkURLDraft = url?.absoluteString ?? ""
                linkAnchor = anchor
                linkEditing = true
            })
            .fixedSize(horizontal: false, vertical: true)
            .popover(isPresented: Binding(get: { slash.active },
                                          set: { if !$0 { slash.active = false } }),
                     attachmentAnchor: .rect(.rect(slash.anchorRect)),
                     arrowEdge: .bottom) {
                SlashMenu(query: Binding(get: { slash.query }, set: { slash.query = $0 }),
                          selection: Binding(get: { slash.selection }, set: { slash.selection = $0 }),
                          onSelect: { kind in slash.commit?(kind) },
                          onDismiss: { slash.active = false })
            }
            .popover(isPresented: $mathEditing, arrowEdge: .bottom) {
                MathEditor(latex: $mathDraft, fontSize: 16) { latex in
                    mathEditing = false
                    insertMath(latex)
                }
            }
            .popover(isPresented: $linkEditing,
                     attachmentAnchor: .rect(.rect(linkAnchor)),
                     arrowEdge: .bottom) {
                LinkEditor(text: $linkTextDraft,
                           urlString: $linkURLDraft,
                           onOpen: {
                               if let url = URL(string: linkURLDraft) { NSWorkspace.shared.open(url) }
                           },
                           onRemove: {
                               linkEditing = false
                               commitLink(removeLink: true)
                           },
                           onDone: {
                               linkEditing = false
                               commitLink(removeLink: false)
                           })
            }
    }

    /// Write the link editor's result back into the storage: a styled link run,
    /// or plain text when removing (or when the URL is empty/invalid).
    private func commitLink(removeLink: Bool) {
        guard let range = linkRange, range.location + range.length <= storage.length else { return }
        linkRange = nil
        let pk = SegmentStyle.paragraphKind(in: storage, at: min(range.location, max(storage.length - 1, 0)))
        let urlString = linkURLDraft.trimmingCharacters(in: .whitespaces)
        let text = linkTextDraft.isEmpty ? (urlString.isEmpty ? "" : urlString) : linkTextDraft
        guard !text.isEmpty else { return }

        let replacement: NSAttributedString
        if !removeLink, !urlString.isEmpty, let url = URL(string: urlString) {
            replacement = NSAttributedString(string: text, attributes: [
                .font: pk.kind.baseFont,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .myaeLink: url,
            ])
        } else {
            var attrs = SegmentStyle.attributes(for: pk)
            attrs[.paragraphKind] = nil
            replacement = NSAttributedString(string: text, attributes: attrs)
        }
        storage.replaceCharacters(in: range, with: replacement)
        document.markEdited()
        document.focusedSegmentID = segment.id
        document.pendingCaretLocation = (segment.id, range.location + replacement.length)
    }

    /// Insert an inline-math attachment at the recorded caret location, or —
    /// when `mathEditRange` is set — replace the double-clicked attachment.
    private func insertMath(_ latex: String) {
        let trimmed = latex.trimmingCharacters(in: .whitespaces)
        let pk = SegmentStyle.paragraphKind(in: NSTextStorage(attributedString: storage),
                                            at: mathEditRange?.location ?? mathCaret)
        if let range = mathEditRange, range.location + range.length <= storage.length {
            mathEditRange = nil
            if trimmed.isEmpty {
                storage.replaceCharacters(in: range, with: "")
            } else {
                storage.replaceCharacters(in: range, with: InlineMath.attributedString(
                    latex: trimmed, fontSize: pk.kind.baseFont.pointSize, kind: pk.kind))
            }
            document.markEdited()
            return
        }
        guard !trimmed.isEmpty else { return }
        let attachment = InlineMath.attributedString(latex: trimmed,
                                                     fontSize: pk.kind.baseFont.pointSize,
                                                     kind: pk.kind)
        let loc = min(mathCaret, storage.length)
        storage.insert(attachment, at: loc)
        document.markEdited()
        document.focusedSegmentID = segment.id
        document.pendingCaretLocation = (segment.id, loc + attachment.length)
    }

    /// Insert a widget segment chosen from the slash menu.
    private func insertWidget(_ kind: BlockKind, at caret: Int) {
        let widget: Segment
        switch kind {
        case .divider:
            widget = Segment(payload: .divider)
        case .table:
            widget = Segment(payload: .table(TableData()))
        case .equation:
            widget = Segment(payload: .equation(latex: ""))
        case .code:
            widget = Segment(payload: .code(
                language: .swift,
                text: NSAttributedString(string: "", attributes: BlockTextView.typingAttributes(for: .code))))
        case .image:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            widget = Segment(payload: .image(path: document.referencePath(for: url)))
        default:
            return
        }
        document.spliceSegments(inSegment: segment.id, atCaret: caret, insert: [widget])
        // Code (and empty equations) should take focus so typing continues there.
        if kind == .code || kind == .equation {
            document.focusedSegmentID = widget.id
        }
    }
}

// MARK: - Link editor popup

/// Octarine-style link popup: edit the visible text and URL, follow the link,
/// or remove it (keeping the text).
private struct LinkEditor: View {
    @Binding var text: String
    @Binding var urlString: String
    let onOpen: () -> Void
    let onRemove: () -> Void
    let onDone: () -> Void

    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Text", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            TextField("https://example.com", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .focused($urlFocused)
                .onSubmit { onDone() }
            HStack(spacing: 10) {
                Button { onOpen() } label: {
                    Label("Open", systemImage: "safari")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Open link (also ⌘+click the link)")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urlString, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Copy URL")

                Spacer()

                Button(role: .destructive) { onRemove() } label: {
                    Image(systemName: "trash").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Remove link (keeps the text)")

                Button("Done") { onDone() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { if urlString.isEmpty { urlFocused = true } }
    }
}
