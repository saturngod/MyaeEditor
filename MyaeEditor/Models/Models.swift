//
//  Models.swift
//  MyaeEditor
//
//  Block model + document store for the editor.
//

import SwiftUI
import AppKit
import Combine

/// The kinds of blocks the editor supports.
enum BlockKind: String, CaseIterable, Identifiable, Codable {
    case paragraph
    case heading1
    case heading2
    case heading3
    case bulleted
    case numbered
    case todo
    case quote
    case code
    case divider
    case table
    case image
    /// A centered display equation whose LaTeX source is stored in the block text.
    case equation
    /// Not a real block kind — only used as a slash-menu command that inserts an
    /// inline math attachment into the current block. Never assigned to a block.
    case inlineMath

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paragraph: "Text"
        case .heading1:  "Heading 1"
        case .heading2:  "Heading 2"
        case .heading3:  "Heading 3"
        case .bulleted:  "Bulleted list"
        case .numbered:  "Numbered list"
        case .todo:      "To-do list"
        case .quote:     "Quote"
        case .code:      "Code"
        case .divider:   "Divider"
        case .table:     "Table"
        case .image:     "Image"
        case .equation:  "Block equation"
        case .inlineMath: "Inline math"
        }
    }

    var subtitle: String {
        switch self {
        case .paragraph: "Just start writing with plain text."
        case .heading1:  "Big section heading."
        case .heading2:  "Medium section heading."
        case .heading3:  "Small section heading."
        case .bulleted:  "Create a simple bulleted list."
        case .numbered:  "Create a list with numbering."
        case .todo:      "Track tasks with a checkbox."
        case .quote:     "Capture a quote."
        case .code:      "Capture a code snippet."
        case .divider:   "Visually divide blocks."
        case .table:     "Add a simple table."
        case .image:     "Upload or embed an image."
        case .equation:  "Display a centered formula."
        case .inlineMath: "Insert a formula like $E = mc^2$."
        }
    }

    var systemImage: String {
        switch self {
        case .paragraph: "text.alignleft"
        case .heading1:  "textformat.size.larger"
        case .heading2:  "textformat.size"
        case .heading3:  "textformat.size.smaller"
        case .bulleted:  "list.bullet"
        case .numbered:  "list.number"
        case .todo:      "checklist"
        case .quote:     "quote.opening"
        case .code:      "chevron.left.forwardslash.chevron.right"
        case .divider:   "minus"
        case .table:     "tablecells"
        case .image:     "photo"
        case .equation:  "x.squareroot"
        case .inlineMath: "function"
        }
    }

    /// Base font used for the block's text.
    var baseFont: NSFont {
        switch self {
        case .heading1: return .systemFont(ofSize: 30, weight: .bold)
        case .heading2: return .systemFont(ofSize: 24, weight: .bold)
        case .heading3: return .systemFont(ofSize: 20, weight: .semibold)
        case .code:     return .monospacedSystemFont(ofSize: 14, weight: .regular)
        default:        return .systemFont(ofSize: 16, weight: .regular)
        }
    }

    /// Text-editing block kinds that can be freely converted between each other.
    var isTextual: Bool {
        switch self {
        case .paragraph, .heading1, .heading2, .heading3,
             .bulleted, .numbered, .todo, .quote, .code: return true
        default: return false
        }
    }

    /// The kinds offered in the "Turn into" menu, in display order.
    static let convertible: [BlockKind] = [
        .paragraph, .heading1, .heading2, .heading3,
        .bulleted, .numbered, .todo, .quote, .code,
    ]

    /// Whether typing Enter inside this block should continue the same kind.
    var continuesOnEnter: Bool {
        switch self {
        case .bulleted, .numbered, .todo: return true
        default: return false
        }
    }

    var placeholder: String {
        switch self {
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .quote:    "Empty quote"
        case .code:     "Code"
        default:        "Type '/' for commands"
        }
    }
}

/// A single editable block in the document.
@Observable
final class Block: Identifiable {
    let id: UUID
    var kind: BlockKind
    var text: NSAttributedString
    var checked: Bool          // used by .todo
    var depth: Int             // indentation level (0 = top level)
    var language: CodeLanguage // used by .code
    var table: TableData?      // used by .table
    var imagePath: String?     // used by .image — path relative to the store dir

    init(id: UUID = UUID(),
         kind: BlockKind = .paragraph,
         text: NSAttributedString = NSAttributedString(string: ""),
         checked: Bool = false,
         depth: Int = 0,
         language: CodeLanguage = .swift,
         table: TableData? = nil,
         imagePath: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.checked = checked
        self.depth = depth
        self.language = language
        self.table = table
        self.imagePath = imagePath
    }

    var isEmpty: Bool { text.length == 0 }

    var plainText: String { text.string }
}

/// A simple table: rows of string cells. Row 0 is treated as the header.
@Observable
final class TableData {
    var cells: [[String]]
    /// Whether the first row / first column is styled as a header.
    var hasHeaderRow: Bool = true
    var hasHeaderColumn: Bool = false

    init(rows: Int = 3, columns: Int = 2) {
        cells = Array(repeating: Array(repeating: "", count: columns), count: rows)
    }
    init(cells: [[String]]) {
        self.cells = cells.isEmpty ? [[""]] : cells
    }

    var rowCount: Int { cells.count }
    var columnCount: Int { cells.first?.count ?? 0 }

    func addRow() { cells.append(Array(repeating: "", count: columnCount)) }
    func addColumn() { for r in cells.indices { cells[r].append("") } }

    func insertRow(at i: Int) {
        cells.insert(Array(repeating: "", count: columnCount), at: min(max(i, 0), rowCount))
    }
    func insertColumn(at i: Int) {
        let at = min(max(i, 0), columnCount)
        for r in cells.indices { cells[r].insert("", at: at) }
    }
    func deleteRow(at i: Int) {
        guard rowCount > 1, cells.indices.contains(i) else { return }
        cells.remove(at: i)
    }
    func deleteColumn(at i: Int) {
        guard columnCount > 1 else { return }
        for r in cells.indices where cells[r].indices.contains(i) { cells[r].remove(at: i) }
    }
}

/// The document: an ordered list of blocks plus focus state.
@Observable
final class EditorDocument {
    var blocks: [Block]
    /// The block that should hold keyboard focus.
    var focusedBlockID: UUID?
    /// When set, the focused block should place its caret at the very start.
    var focusAtStart: Bool = false
    /// Block-level selection (set via Cmd+A escalation or marquee drag). When
    /// non-empty, no text view holds focus and key commands act on whole blocks.
    var selectedBlockIDs: Set<UUID> = []
    /// Fixed end of a keyboard (Shift+Arrow) block selection; the lead is the
    /// moving end. Not observed — they only steer `selectedBlockIDs`.
    @ObservationIgnored var selectionAnchorID: UUID?
    @ObservationIgnored var selectionLeadID: UUID?

    /// Fires whenever the document content changes. Drives debounced autosave.
    /// (Not @Observable-tracked, so it doesn't re-render the view on every edit.)
    @ObservationIgnored let didEdit = PassthroughSubject<Void, Never>()

    /// Debounced autosave trigger: fires ~2s after the last edit, never on idle.
    /// Owned by the document (a single persisted instance) so the pipeline's
    /// debounce state survives EditorView re-inits.
    @ObservationIgnored lazy var autosaveSignal: AnyPublisher<Void, Never> =
        didEdit
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .eraseToAnyPublisher()

    /// Signal that content changed (call after any content mutation).
    func markEdited() { didEdit.send() }

    init(blocks: [Block] = [Block()]) {
        self.blocks = blocks
        self.focusedBlockID = blocks.first?.id
    }

    func index(of block: Block) -> Int? {
        blocks.firstIndex { $0.id == block.id }
    }

    // MARK: Block-level selection

    /// Select every block and drop text focus, so the selection is visible and
    /// key commands (Copy / Delete) act on whole blocks.
    func selectAllBlocks() {
        selectedBlockIDs = Set(blocks.map(\.id))
        selectionAnchorID = nil
        selectionLeadID = nil
        focusedBlockID = nil
    }

    /// Select all blocks whose vertical extent intersects [yMin, yMax] (editor
    /// coordinate space). Used by the marquee drag.
    func selectBlocks(intersecting yMin: CGFloat, _ yMax: CGFloat, frames: [UUID: CGRect]) {
        let lo = min(yMin, yMax), hi = max(yMin, yMax)
        let hits = blocks.filter { b in
            guard let f = frames[b.id] else { return false }
            return f.maxY >= lo && f.minY <= hi
        }
        selectedBlockIDs = Set(hits.map(\.id))
        selectionAnchorID = nil
        selectionLeadID = nil
        if !selectedBlockIDs.isEmpty { focusedBlockID = nil }
    }

    func clearSelection() {
        guard !selectedBlockIDs.isEmpty else { return }
        selectedBlockIDs.removeAll()
        selectionAnchorID = nil
        selectionLeadID = nil
    }

    /// Grow or shrink the block-level selection by one block toward the top
    /// (`up`) or bottom. If nothing is selected yet, start at `from` (or the
    /// focused block) and drop text focus so the selection shows on its own.
    func extendBlockSelection(up: Bool, from startID: UUID? = nil) {
        if selectedBlockIDs.isEmpty {
            guard let start = startID ?? focusedBlockID ?? blocks.first?.id else { return }
            selectionAnchorID = start
            selectionLeadID = start
            selectedBlockIDs = [start]
            focusedBlockID = nil
        }
        // Re-pin the anchor/lead when either is missing or no longer in the
        // document — after Select-All, a marquee drag, or a block deletion that
        // left a dangling id. Pin the anchor to the far end so this press grows
        // the selection from the near end.
        let anchorAlive = selectionAnchorID.map { id in blocks.contains { $0.id == id } } ?? false
        let leadAlive = selectionLeadID.map { id in blocks.contains { $0.id == id } } ?? false
        if !anchorAlive || !leadAlive {
            let idxs = blocks.indices.filter { selectedBlockIDs.contains(blocks[$0].id) }
            guard let first = idxs.first, let last = idxs.last else { return }
            selectionAnchorID = blocks[up ? last : first].id
            selectionLeadID = blocks[up ? first : last].id
        }
        guard let anchor = selectionAnchorID, let lead = selectionLeadID,
              let anchorIdx = blocks.firstIndex(where: { $0.id == anchor }),
              let leadIdx = blocks.firstIndex(where: { $0.id == lead }) else { return }
        let newLead = up ? max(0, leadIdx - 1) : min(blocks.count - 1, leadIdx + 1)
        selectionLeadID = blocks[newLead].id
        let lo = min(anchorIdx, newLead), hi = max(anchorIdx, newLead)
        selectedBlockIDs = Set(blocks[lo...hi].map(\.id))
    }

    /// Delete all selected blocks, then focus the block that takes their place.
    func deleteSelectedBlocks() {
        guard !selectedBlockIDs.isEmpty else { return }
        let firstIdx = blocks.firstIndex { selectedBlockIDs.contains($0.id) } ?? 0
        blocks.removeAll { selectedBlockIDs.contains($0.id) }
        selectedBlockIDs.removeAll()
        selectionAnchorID = nil
        selectionLeadID = nil
        if blocks.isEmpty { blocks = [Block()] }
        let target = blocks[min(firstIdx, blocks.count - 1)]
        focusedBlockID = target.id
        focusAtStart = true
        markEdited()
    }

    /// The selected blocks, in document order (for copy).
    var selectedBlocksInOrder: [Block] {
        blocks.filter { selectedBlockIDs.contains($0.id) }
    }

    func block(before block: Block) -> Block? {
        guard let i = index(of: block), i > 0 else { return nil }
        return blocks[i - 1]
    }

    func block(after block: Block) -> Block? {
        guard let i = index(of: block), i < blocks.count - 1 else { return nil }
        return blocks[i + 1]
    }

    /// The 1-based ordinal of a numbered block among its siblings at the same depth.
    /// Deeper sub-items are skipped; a shallower block or a non-numbered sibling
    /// ends the run.
    func number(for block: Block) -> Int {
        guard let i = index(of: block) else { return 1 }
        let d = block.depth
        var n = 1
        var j = i - 1
        while j >= 0 {
            let b = blocks[j]
            if b.depth > d { j -= 1; continue }     // skip nested sub-items
            if b.depth < d { break }                // parent list ended
            if b.kind == .numbered { n += 1; j -= 1 } else { break }
        }
        return n
    }

    /// Ordinals for every numbered block, computed in a single forward pass (same
    /// semantics as `number(for:)`, mirroring `MarkdownCodec.encode`). O(n) total
    /// instead of O(n) per numbered row — the latter is O(n²) when the whole list
    /// re-renders. Deeper items are transparent; a shallower or non-numbered block
    /// ends the run at that depth.
    func numberedOrdinals() -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var counters: [Int: Int] = [:]
        for block in blocks {
            let d = block.depth
            counters = counters.filter { $0.key <= d }
            if block.kind == .numbered {
                let n = (counters[d] ?? 0) + 1
                counters[d] = n
                result[block.id] = n
            } else {
                counters[d] = nil
            }
        }
        return result
    }

    /// Indent a block one level, if the block above allows it. Returns true on change.
    @discardableResult
    func indent(_ block: Block) -> Bool {
        guard let prev = self.block(before: block), block.depth <= prev.depth else { return false }
        block.depth += 1
        markEdited()
        return true
    }

    /// Outdent a block one level. Returns true on change.
    @discardableResult
    func outdent(_ block: Block) -> Bool {
        guard block.depth > 0 else { return false }
        block.depth -= 1
        markEdited()
        return true
    }

    // MARK: Mutations

    /// Insert a new empty block after `block` and focus it. Returns the new block.
    @discardableResult
    func insertBlock(after block: Block, kind: BlockKind) -> Block {
        let new = Block(kind: kind, depth: block.depth)
        if let i = index(of: block) {
            blocks.insert(new, at: i + 1)
        } else {
            blocks.append(new)
        }
        focusedBlockID = new.id
        focusAtStart = false
        markEdited()
        return new
    }

    /// Delete `block`, focusing the previous one (caret at end). No-op if it's the only block.
    func deleteAndFocusPrevious(_ block: Block) {
        guard blocks.count > 1, let i = index(of: block) else {
            // Last remaining block: just clear it back to a paragraph.
            block.text = NSAttributedString(string: "")
            block.kind = .paragraph
            markEdited()
            return
        }
        let previous = i > 0 ? blocks[i - 1] : nil
        blocks.remove(at: i)
        markEdited()
        if let previous {
            focusedBlockID = previous.id
            focusAtStart = false
        } else {
            focusedBlockID = blocks.first?.id
            focusAtStart = true
        }
    }

    /// Merge `block`'s text into the previous block and focus the join point.
    /// Returns true if a merge happened.
    @discardableResult
    func mergeIntoPrevious(_ block: Block) -> Bool {
        guard let i = index(of: block), i > 0 else { return false }
        let previous = blocks[i - 1]
        if previous.kind == .divider {
            // Remove the divider instead of merging into it.
            blocks.remove(at: i - 1)
            focusedBlockID = block.id
            focusAtStart = true
            pendingCaretLocation = nil   // no merge happened; drop any stale request
            markEdited()
            return true
        }
        let joinLocation = previous.text.length
        let merged = NSMutableAttributedString(attributedString: previous.text)
        merged.append(block.text)
        previous.text = merged
        blocks.remove(at: i)
        focusedBlockID = previous.id
        // Caret should land at the join point; handled by the text view via a pending request.
        pendingCaretLocation = (previous.id, joinLocation)
        markEdited()
        return true
    }

    /// A one-shot request to place the caret at a specific location in a block.
    var pendingCaretLocation: (id: UUID, location: Int)?

    /// Change a block's kind, re-applying the target base font to its text while
    /// preserving bold/italic runs (used by the "Turn into" menu).
    func changeKind(of block: Block, to kind: BlockKind) {
        guard block.kind != kind else { return }
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
        if kind != .code {
            let color: NSColor = (kind == .quote) ? .secondaryLabelColor : .textColor
            mutable.addAttribute(.foregroundColor, value: color, range: full)
        }
        block.text = mutable
        focusedBlockID = block.id
        markEdited()
    }

    /// Insert a copy of `block` right after it and focus the copy.
    @discardableResult
    func duplicate(_ block: Block) -> Block {
        let copiedTable = block.table.map { TableData(cells: $0.cells) }
        copiedTable?.hasHeaderRow = block.table?.hasHeaderRow ?? true
        copiedTable?.hasHeaderColumn = block.table?.hasHeaderColumn ?? false
        let copy = Block(
            kind: block.kind,
            text: NSAttributedString(attributedString: block.text),
            checked: block.checked,
            depth: block.depth,
            language: block.language,
            table: copiedTable,
            imagePath: block.imagePath
        )
        if let i = index(of: block) {
            blocks.insert(copy, at: i + 1)
        } else {
            blocks.append(copy)
        }
        focusedBlockID = copy.id
        markEdited()
        return copy
    }

    /// Remove a block entirely (used by e.g. "Delete table").
    func removeBlock(_ block: Block) {
        guard let i = index(of: block) else { return }
        if blocks.count == 1 {
            // Keep at least one block; reset it to an empty paragraph.
            block.kind = .paragraph
            block.table = nil
            block.text = NSAttributedString(string: "")
            markEdited()
            return
        }
        blocks.remove(at: i)
        focusedBlockID = blocks[max(0, i - 1)].id
        markEdited()
    }

    func move(from source: IndexSet, to destination: Int) {
        blocks.move(fromOffsets: source, toOffset: destination)
        markEdited()
    }

    func moveBlock(id: UUID, before targetID: UUID) {
        guard let from = blocks.firstIndex(where: { $0.id == id }),
              var to = blocks.firstIndex(where: { $0.id == targetID }) else { return }
        if from == to { return }
        let block = blocks.remove(at: from)
        if from < to { to -= 1 }
        blocks.insert(block, at: to)
        markEdited()
    }

    func moveBlockToEnd(id: UUID) {
        guard let from = blocks.firstIndex(where: { $0.id == id }) else { return }
        let block = blocks.remove(at: from)
        blocks.append(block)
        markEdited()
    }

    /// Move `id` so that it sits at `index` counted among the *other* blocks
    /// (i.e. the array with the dragged block removed). Used by gesture reorder.
    func move(id: UUID, toIndexAmongOthers index: Int) {
        guard let from = blocks.firstIndex(where: { $0.id == id }) else { return }
        let block = blocks.remove(at: from)
        let clamped = max(0, min(index, blocks.count))
        blocks.insert(block, at: clamped)
        markEdited()
    }
}
