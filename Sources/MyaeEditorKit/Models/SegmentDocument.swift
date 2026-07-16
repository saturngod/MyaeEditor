//
//  SegmentDocument.swift
//  MyaeEditor
//
//  The continuous-editor document: an ordered list of `Segment`s plus focus and
//  selection state. Replaces the block-based `EditorDocument`. Owns the same
//  image-path resolution and edit-signal contract the controller depends on.
//

import AppKit
import Combine

@Observable
final class SegmentDocument {
    var segments: [Segment]

    /// The text segment that should hold keyboard focus.
    var focusedSegmentID: UUID?
    /// When set, the focused text segment places its caret at the very start.
    var focusAtStart: Bool = false
    /// Widget-level selection (widgets have no text view; keys act on them whole).
    var selectedSegmentIDs: Set<UUID> = []

    /// One-shot request to place the caret at a location within a text segment
    /// (e.g. after a merge across a widget boundary).
    @ObservationIgnored var pendingCaretLocation: (id: UUID, location: Int)?

    /// Fires whenever content changes; the controller debounces this for autosave
    /// and dirty tracking. Not @Observable so edits don't re-render on every key.
    @ObservationIgnored let didEdit = PassthroughSubject<Void, Never>()
    func markEdited() { didEdit.send() }

    init(segments: [Segment] = [Segment.emptyText()]) {
        self.segments = segments.isEmpty ? [Segment.emptyText()] : segments
        self.focusedSegmentID = self.segments.first { $0.isText }?.id
    }

    // MARK: Image path resolution (moved verbatim from EditorDocument)

    @ObservationIgnored var imageFileDirectory: URL?
    @ObservationIgnored var imageFallbackDirectory: URL = MarkdownStore.default.directory

    var imageBaseDirectory: URL { imageFileDirectory ?? imageFallbackDirectory }

    func imageURL(for path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: path, relativeTo: imageBaseDirectory).standardized
    }

    func referencePath(for url: URL) -> String {
        let absolute = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard imageFileDirectory != nil else { return absolute }
        let file = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let base = imageBaseDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var i = 0
        while i < file.count, i < base.count, file[i] == base[i] { i += 1 }
        let ups = base.count - i
        let downs = file[i...].joined(separator: "/")
        if ups > 1 { return absolute }
        if ups == 1 { return "../" + downs }
        return "./" + downs
    }

    // MARK: Lookups

    func index(of id: UUID) -> Int? { segments.firstIndex { $0.id == id } }
    func segment(_ id: UUID) -> Segment? { segments.first { $0.id == id } }

    // MARK: Structural invariants

    /// Restore the document invariants after a structural mutation:
    /// 1. no two adjacent text segments (merge them, joining with a newline),
    /// 2. the document always contains at least one text segment.
    func normalize() {
        var result: [Segment] = []
        for seg in segments {
            if case .text(let storage) = seg.payload,
               let last = result.last, case .text(let prev) = last.payload {
                // Merge into the previous text segment with a joining newline.
                prev.append(NSAttributedString(string: "\n"))
                prev.append(storage)
            } else {
                result.append(seg)
            }
        }
        if result.isEmpty || !result.contains(where: { $0.isText }) {
            result.append(Segment.emptyText())
        }
        segments = result
    }

    /// Turn a fence paragraph inside a text segment into an editable code block:
    /// split the text segment around `paragraphRange` (dropping the fence line) and
    /// insert a `.code` segment between the halves, then focus it.
    func convertParagraphToCodeBlock(inSegment segID: UUID, paragraphRange pr: NSRange, language: CodeLanguage) {
        guard let idx = index(of: segID), case .text(let storage) = segments[idx].payload else { return }
        let full = storage.length
        let nsString = storage.string as NSString
        var newSegs: [Segment] = []

        // Text before the fence line (drop the newline that ended the prior line).
        var beforeLen = pr.location
        if beforeLen > 0, nsString.character(at: beforeLen - 1) == 10 { beforeLen -= 1 }
        if beforeLen > 0 {
            let bStore = NSTextStorage(attributedString: storage.attributedSubstring(from: NSRange(location: 0, length: beforeLen)))
            newSegs.append(Segment(payload: .text(bStore)))
        }

        let codeSeg = Segment(payload: .code(
            language: language,
            text: NSTextStorage(string: "", attributes: BlockTextView.typingAttributes(for: .code))))
        newSegs.append(codeSeg)

        // Text after the fence line.
        let afterStart = min(pr.location + pr.length, full)
        let afterLen = full - afterStart
        if afterLen > 0 {
            let aStore = NSTextStorage(attributedString: storage.attributedSubstring(from: NSRange(location: afterStart, length: afterLen)))
            newSegs.append(Segment(payload: .text(aStore)))
        } else {
            newSegs.append(Segment.emptyText())
        }

        segments.replaceSubrange(idx...idx, with: newSegs)
        normalize()
        focusedSegmentID = codeSeg.id
        markEdited()
    }

    /// Splice pasted segments into a text segment at `caret`, splitting the text
    /// around the caret. Used when pasted Markdown contains widgets (tables, code,
    /// images, …) that can't live inside a text run.
    func spliceSegments(inSegment segID: UUID, atCaret caret: Int, insert pasted: [Segment]) {
        guard let idx = index(of: segID), case .text(let storage) = segments[idx].payload, !pasted.isEmpty else { return }
        let full = storage.length
        let loc = min(max(caret, 0), full)
        var newSegs: [Segment] = []
        if loc > 0 {
            newSegs.append(Segment(payload: .text(NSTextStorage(attributedString:
                storage.attributedSubstring(from: NSRange(location: 0, length: loc))))))
        }
        newSegs.append(contentsOf: pasted)
        let afterLen = full - loc
        let afterSeg: Segment
        if afterLen > 0 {
            afterSeg = Segment(payload: .text(NSTextStorage(attributedString:
                storage.attributedSubstring(from: NSRange(location: loc, length: afterLen)))))
        } else {
            afterSeg = Segment.emptyText()
        }
        newSegs.append(afterSeg)
        let afterID = afterSeg.id
        segments.replaceSubrange(idx...idx, with: newSegs)
        normalize()
        // Land the caret in the trailing text if it survived normalization.
        focusedSegmentID = segment(afterID) != nil ? afterID : segments.first(where: { $0.isText })?.id
        focusAtStart = true
        markEdited()
    }

    /// Remove a widget segment, then merge/refocus the surrounding text so the
    /// caret lands at the join. Used for deleting code/table/image/etc. segments.
    func removeWidget(_ segID: UUID) {
        guard let idx = index(of: segID) else { return }
        let prevText: (id: UUID, loc: Int)? =
            (idx > 0 && segments[idx - 1].isText)
            ? (segments[idx - 1].id, segments[idx - 1].textStorage?.length ?? 0) : nil
        let nextTextID: UUID? =
            (idx + 1 < segments.count && segments[idx + 1].isText) ? segments[idx + 1].id : nil
        segments.remove(at: idx)
        normalize()
        if let prev = prevText, segment(prev.id) != nil {
            focusedSegmentID = prev.id
            pendingCaretLocation = (prev.id, prev.loc)
        } else if let nid = nextTextID, segment(nid) != nil {
            focusedSegmentID = nid
            focusAtStart = true
        } else {
            focusedSegmentID = segments.first(where: { $0.isText })?.id
            focusAtStart = true
        }
        markEdited()
    }

    /// If the segment before `segID` is a widget, delete it. Returns true if it did.
    @discardableResult
    func deletePrecedingWidget(before segID: UUID) -> Bool {
        guard let idx = index(of: segID), idx > 0, !segments[idx - 1].isText else { return false }
        removeWidget(segments[idx - 1].id)
        return true
    }

    // MARK: Whole-document (segment-level) selection

    /// Select every segment and drop text focus, so the selection is visible and
    /// key commands (Copy / Delete) act on the whole document.
    func selectAllSegments() {
        selectedSegmentIDs = Set(segments.map(\.id))
        focusedSegmentID = nil
    }

    func clearSelection() {
        guard !selectedSegmentIDs.isEmpty else { return }
        selectedSegmentIDs.removeAll()
    }

    /// The selected segments in document order (for copy).
    var selectedSegmentsInOrder: [Segment] {
        segments.filter { selectedSegmentIDs.contains($0.id) }
    }

    /// Delete every selected segment, leaving an empty document if all were selected.
    func deleteSelectedSegments() {
        guard !selectedSegmentIDs.isEmpty else { return }
        segments.removeAll { selectedSegmentIDs.contains($0.id) }
        selectedSegmentIDs.removeAll()
        normalize()
        focusedSegmentID = segments.first(where: { $0.isText })?.id
        focusAtStart = true
        markEdited()
    }

    /// Replace the selection with freshly decoded segments (paste over Cmd+A).
    func replaceSelectedSegments(with new: [Segment]) {
        guard !selectedSegmentIDs.isEmpty, !new.isEmpty else { return }
        let firstIdx = segments.firstIndex { selectedSegmentIDs.contains($0.id) } ?? 0
        segments.removeAll { selectedSegmentIDs.contains($0.id) }
        segments.insert(contentsOf: new, at: min(firstIdx, segments.count))
        selectedSegmentIDs.removeAll()
        normalize()
        focusedSegmentID = segments.first(where: { $0.isText })?.id
        focusAtStart = true
        markEdited()
    }

    /// Move focus to the nearest editable segment above `segID` (text or code),
    /// caret at its end. Non-editable widgets are skipped. Returns true if moved.
    @discardableResult
    func focusUp(from segID: UUID) -> Bool {
        guard let idx = index(of: segID) else { return false }
        var j = idx - 1
        while j >= 0 {
            if case .table(let t) = segments[j].payload {
                // Enter the table at its last row; the cell takes first responder.
                // Clear any pending text caret so a stale one isn't applied to
                // another segment while the table cell is focused.
                focusedSegmentID = nil
                pendingCaretLocation = nil
                t.pendingFocusRow = max(0, t.rowCount - 1)
                return true
            }
            if segments[j].isText || segments[j].codeText != nil {
                focusAtStart = false
                if let s = segments[j].textStorage { pendingCaretLocation = (segments[j].id, s.length) }
                focusedSegmentID = segments[j].id
                return true
            }
            j -= 1
        }
        return false
    }

    /// Move focus to the nearest editable segment below `segID`, caret at its start.
    @discardableResult
    func focusDown(from segID: UUID) -> Bool {
        guard let idx = index(of: segID) else { return false }
        var j = idx + 1
        while j < segments.count {
            if case .table(let t) = segments[j].payload {
                // Enter the table at its first row; the cell takes first responder.
                // Clear any pending text caret so a stale one isn't applied to
                // another segment while the table cell is focused.
                focusedSegmentID = nil
                pendingCaretLocation = nil
                t.pendingFocusRow = 0
                return true
            }
            if segments[j].isText || segments[j].codeText != nil {
                focusAtStart = true
                focusedSegmentID = segments[j].id
                return true
            }
            j += 1
        }
        return false
    }

    /// Focus the text segment after `segID` (creating an empty one if the segment
    /// is last or followed by a widget). Used to step the caret out of a code block.
    func focusTextAfter(_ segID: UUID) {
        guard let idx = index(of: segID) else { return }
        let next = idx + 1
        if next < segments.count, segments[next].isText {
            focusAtStart = true
            focusedSegmentID = segments[next].id
        } else {
            let seg = Segment.emptyText()
            segments.insert(seg, at: next)
            focusAtStart = true
            focusedSegmentID = seg.id
            markEdited()
        }
    }

    /// Re-font every open text segment in place after the editor's font setting
    /// changes — mutates each storage's `.font` runs directly (preserving caret,
    /// selection, and undo) and invalidates its layout manager's cached line
    /// heights. Code and table segments re-font through their own `updateNSView`
    /// passes, which the configuration change also triggers.
    func restyleTextFonts() {
        for seg in segments {
            guard let storage = seg.textStorage else { continue }
            SegmentStyle.restyleFonts(in: storage)
            (storage.layoutManagers.first as? CenteringLayoutManager)?.invalidateFixedHeights()
        }
    }

    /// Replace all segments (used on load/new). Resets focus to the first text run.
    func replaceAll(_ new: [Segment]) {
        segments = new.isEmpty ? [Segment.emptyText()] : new
        selectedSegmentIDs = []
        pendingCaretLocation = nil
        focusedSegmentID = segments.first { $0.isText }?.id
    }
}
