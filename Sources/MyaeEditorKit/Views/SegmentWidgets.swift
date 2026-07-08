//
//  SegmentWidgets.swift
//  MyaeEditor
//
//  Rendered widget segments embedded in the continuous document: divider, image,
//  equation, code/mermaid, and table. These render the segment payload; deeper
//  editing (table cells, mermaid flip-to-source, image picker) is layered on in a
//  later milestone.
//

import SwiftUI
import AppKit

// MARK: - Divider

struct SegmentDividerView: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Image

struct SegmentImageView: View {
    let segment: Segment
    let document: SegmentDocument
    let path: String?

    @Environment(\.myaeConfiguration) private var config
    @State private var hovering = false
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 520, maxHeight: 400, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        if hovering && config.isEditable {
                            Button { remove() } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.5))
                                    .padding(6)
                            }
                            .buttonStyle(.plain)
                            .help("Remove image")
                        }
                    }
                    .onHover { hovering = $0 }
                    .contextMenu {
                        if config.isEditable {
                            Button("Replace…") { pickImage() }
                            Button("Remove", role: .destructive) { remove() }
                        }
                    }
            } else {
                placeholder
            }
        }
        .padding(.vertical, 6)
        .task(id: path) { image = loadImage() }
    }

    private var placeholder: some View {
        Button { if config.isEditable { pickImage() } } label: {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                Text(path == nil ? "Add an image" : "Missing image — click to replace")
                Spacer()
            }
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4])))
        }
        .buttonStyle(.plain)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Reference the picked file in place — don't copy it into the app's store.
        segment.payload = .image(path: document.referencePath(for: url))
        document.markEdited()
    }

    private func remove() {
        document.removeWidget(segment.id)
    }

    private func loadImage() -> NSImage? {
        guard let path else { return nil }
        return NSImage(contentsOf: document.imageURL(for: path))
    }
}

// MARK: - Equation

struct SegmentEquationView: View {
    let segment: Segment
    let document: SegmentDocument
    let latex: String

    @Environment(\.myaeConfiguration) private var config
    @State private var editing = false
    @State private var draft = ""

    private let displaySize: CGFloat = 24

    var body: some View {
        Button { startEditing() } label: { content }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                MathEditor(latex: $draft, fontSize: displaySize) { newLatex in
                    editing = false
                    let trimmed = newLatex.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        document.removeWidget(segment.id)
                    } else {
                        segment.payload = .equation(latex: trimmed)
                        document.markEdited()
                    }
                }
            }
            .onAppear { if latex.isEmpty { startEditing() } }
            .contextMenu {
                if config.isEditable {
                    Button("Edit…") { startEditing() }
                    Button("Delete equation", role: .destructive) { document.removeWidget(segment.id) }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if latex.isEmpty {
            HStack {
                Spacer()
                Label("Add equation", systemImage: "x.squareroot")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            MathPreview(latex: latex, fontSize: displaySize, background: false)
                .frame(maxWidth: .infinity)
        }
    }

    private func startEditing() {
        guard config.isEditable else { return }
        draft = latex
        editing = true
    }
}

// MARK: - Code / Mermaid

struct SegmentCodeView: View {
    let segment: Segment
    let document: SegmentDocument
    var isFocused: Bool
    var rendersMermaid: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var mermaidHeight: CGFloat = 44
    @State private var mermaidError: String?
    @State private var hovering = false
    @State private var justCopied = false
    @State private var showingZoom = false

    private var language: CodeLanguage { segment.codeLanguage ?? .plain }
    private var text: NSAttributedString { segment.codeText ?? NSAttributedString(string: "") }

    /// Copy the block's source to the pasteboard, with brief ✓ feedback.
    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.string, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) { justCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 0.2)) { justCopied = false }
        }
    }

    private var copyButton: some View {
        Button { copyCode() } label: {
            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12))
                .foregroundStyle(justCopied ? Color.green : .secondary)
        }
        .buttonStyle(.plain)
        .help("Copy code")
        .opacity(hovering || justCopied ? 1 : 0)
    }

    /// Open the full-size zoom/pan viewer for the rendered diagram.
    private var expandButton: some View {
        Button { showingZoom = true } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("View larger")
        .opacity(hovering ? 1 : 0)
    }

    var body: some View {
        // Mermaid renders as a diagram when it isn't being edited; everything else
        // (and mermaid while focused) is an editable code block.
        Group {
            if language == .mermaid && rendersMermaid && !text.string.isEmpty && !isFocused {
                mermaid
            } else {
                code
            }
        }
        // Attached here (not on `mermaid`) so switching to the editable `code`
        // branch — e.g. focus moving here — doesn't tear the sheet down mid-view.
        .sheet(isPresented: $showingZoom) {
            MermaidZoomView(source: text.string, theme: MermaidTheme(colorScheme)) {
                showingZoom = false
            }
        }
    }

    private var mermaid: some View {
        VStack(alignment: .leading, spacing: 4) {
            MermaidWebView(source: text.string,
                           theme: MermaidTheme(colorScheme),
                           backgroundHex: "transparent",
                           height: $mermaidHeight,
                           errorMessage: $mermaidError)
                .frame(height: max(44, mermaidHeight))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let mermaidError {
                Label(mermaidError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor).opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) { expandButton; copyButton }.padding(10)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { document.focusedSegmentID = segment.id }   // tap mermaid → edit source
        .onHover { hovering = $0 }
    }

    private var code: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                languageMenu
                Spacer()
                copyButton
            }
            CodeSegmentEditor(segment: segment, language: language, document: document, isFocused: isFocused)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .padding(.vertical, 6)
        .onHover { hovering = $0 }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(CodeLanguage.allCases, id: \.self) { lang in
                Button(lang.displayName) { setLanguage(lang) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(language.displayName).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func setLanguage(_ lang: CodeLanguage) {
        segment.payload = .code(language: lang, text: segment.codeText ?? NSAttributedString(string: ""))
        document.markEdited()
    }
}

/// An editable, syntax-highlighted code editor for a `.code` segment.
struct CodeSegmentEditor: NSViewRepresentable {
    let segment: Segment
    let language: CodeLanguage
    let document: SegmentDocument
    var isFocused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CodeNSTextView {
        let tv = CodeNSTextView()
        tv.delegate = context.coordinator
        tv.exitDown = { [weak document] in document?.focusTextAfter(segment.id) }
        tv.deleteEmpty = { [weak document] in document?.removeWidget(segment.id) }
        tv.arrowUp = { [weak document] in document?.focusUp(from: segment.id) ?? false }
        tv.arrowDown = { [weak document] in document?.focusDown(from: segment.id) ?? false }
        tv.selectAllSegments = { [weak document] in document?.selectAllSegments() }
        tv.onFocusGained = { [weak document] in
            document?.selectedSegmentIDs = []
            document?.focusedSegmentID = segment.id
        }
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isEditable = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        // Same fixed-height, baseline-centered lines (and centered caret) as the
        // main editor. The highlighter rewrites attributes without `.paragraphKind`,
        // so the code font/multiple are set as an override instead.
        let codeLM = CenteringLayoutManager()
        codeLM.overrideFont = BlockKind.code.baseFont
        codeLM.overrideMultiple = BlockTextView.lineHeightMultiple(for: .code)
        tv.textContainer?.replaceLayoutManager(codeLM)
        tv.font = BlockKind.code.baseFont
        tv.typingAttributes = BlockTextView.typingAttributes(for: .code)
        if let code = segment.codeText { tv.textStorage?.setAttributedString(code) }
        if let storage = tv.textStorage {
            SyntaxHighlighter.highlight(storage, language: language, font: BlockKind.code.baseFont)
        }
        context.coordinator.lastLanguage = language
        tv.unregisterDraggedTypes()
        return tv
    }

    func updateNSView(_ tv: CodeNSTextView, context: Context) {
        context.coordinator.parent = self
        // Push a changed editor font setting onto the live code storage. Re-run
        // the highlighter (it rewrites `.font` across the run) and reset the
        // layout override; mutating storage attributes directly keeps the caret
        // and undo intact.
        let codeFont = BlockKind.code.baseFont
        if tv.font != codeFont {
            tv.font = codeFont
            tv.typingAttributes = BlockTextView.typingAttributes(for: .code)
            (tv.layoutManager as? CenteringLayoutManager)?.overrideFont = codeFont
            if let storage = tv.textStorage {
                SyntaxHighlighter.highlight(storage, language: language, font: codeFont)
            }
        }
        // Re-highlight when the language is switched via the dropdown.
        if context.coordinator.lastLanguage != language, let storage = tv.textStorage {
            context.coordinator.lastLanguage = language
            SyntaxHighlighter.highlight(storage, language: language, font: codeFont)
        }
        if isFocused, tv.window?.firstResponder !== tv {
            DispatchQueue.main.async { [weak tv] in
                guard let tv else { return }
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeSegmentEditor
        var lastLanguage: CodeLanguage?
        init(_ parent: CodeSegmentEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? CodeNSTextView, let storage = tv.textStorage else { return }
            SyntaxHighlighter.highlight(storage, language: parent.language,
                                        font: BlockKind.code.baseFont, editedRange: storage.editedRange)
            parent.segment.payload = .code(language: parent.language,
                                           text: NSAttributedString(attributedString: storage))
            tv.invalidateIntrinsicContentSize()
            parent.document.markEdited()
        }
    }
}

/// A minimal auto-sizing code text view: Tab inserts spaces, Enter on an empty
/// last line steps out of the block.
final class CodeNSTextView: AutoSizingTextView {
    var exitDown: (() -> Void)?
    var deleteEmpty: (() -> Void)?
    var arrowUp: (() -> Bool)?
    var arrowDown: (() -> Bool)?
    var selectAllSegments: (() -> Void)?
    var onFocusGained: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusGained?() }
        return ok
    }

    override func paste(_ sender: Any?) { pasteLiteral() }
    override func pasteAsPlainText(_ sender: Any?) { pasteLiteral() }

    // Cmd+A: select this block's code first; second press selects the whole document.
    override func selectAll(_ sender: Any?) {
        let length = (string as NSString).length
        let allSelected = selectedRange() == NSRange(location: 0, length: length)
        if length == 0 || allSelected {
            selectAllSegments?()
            window?.makeFirstResponder(nil)
        } else {
            setSelectedRange(NSRange(location: 0, length: length))
        }
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            if caretIsOnFirstLine(), arrowUp?() == true { return }
            super.doCommand(by: selector)
        case #selector(NSResponder.moveDown(_:)):
            if caretIsOnLastLine(), arrowDown?() == true { return }
            super.doCommand(by: selector)
        case #selector(NSResponder.deleteBackward(_:)):
            // Backspace in an empty code block deletes the whole block.
            if (string as NSString).length == 0 {
                deleteEmpty?()
                return
            }
            super.doCommand(by: selector)
        case #selector(NSResponder.insertTab(_:)):
            insertText("    ", replacementRange: selectedRange())
            return
        case #selector(NSResponder.insertNewline(_:)):
            // Enter on an empty last line exits the code block.
            let s = string as NSString
            let sel = selectedRange()
            if sel.length == 0, sel.location == s.length,
               s.length > 0, s.character(at: s.length - 1) == 10 {
                // Drop the trailing empty line and step out.
                if shouldChangeText(in: NSRange(location: s.length - 1, length: 1), replacementString: "") {
                    textStorage?.replaceCharacters(in: NSRange(location: s.length - 1, length: 1), with: "")
                    didChangeText()
                }
                exitDown?()
                return
            }
            super.doCommand(by: selector)
        default:
            super.doCommand(by: selector)
        }
    }
}

// Tables are rendered by the full editor `TableBlockView` (segment-bound).
