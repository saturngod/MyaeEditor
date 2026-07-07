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
    case heading4
    case heading5
    case heading6
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
        case .heading4:  "Heading 4"
        case .heading5:  "Heading 5"
        case .heading6:  "Heading 6"
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
        case .heading4:  "Smaller section heading."
        case .heading5:  "Tiny section heading."
        case .heading6:  "Smallest section heading."
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
        case .heading4:  "textformat.size.smaller"
        case .heading5:  "textformat.size.smaller"
        case .heading6:  "textformat.size.smaller"
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
        case .heading4: return .systemFont(ofSize: 18, weight: .semibold)
        case .heading5: return .systemFont(ofSize: 16, weight: .semibold)
        case .heading6: return .systemFont(ofSize: 14, weight: .semibold)
        case .code:     return .monospacedSystemFont(ofSize: 14, weight: .regular)
        default:        return .systemFont(ofSize: 16, weight: .regular)
        }
    }

    /// Text-editing block kinds that can be freely converted between each other.
    var isTextual: Bool {
        switch self {
        case .paragraph, .heading1, .heading2, .heading3, .heading4, .heading5, .heading6,
             .bulleted, .numbered, .todo, .quote, .code: return true
        default: return false
        }
    }

    /// The kinds offered in the "Turn into" menu, in display order.
    static let convertible: [BlockKind] = [
        .paragraph, .heading1, .heading2, .heading3, .heading4, .heading5, .heading6,
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
        case .heading4: "Heading 4"
        case .heading5: "Heading 5"
        case .heading6: "Heading 6"
        case .quote:    "Empty quote"
        case .code:     "Code"
        default:        "Type '/' for commands"
        }
    }
}

/// Horizontal alignment of a table column, matching GFM separator syntax
/// (`:---` left, `:---:` center, `---:` right, `---` unspecified).
enum ColumnAlignment: String {
    case none, left, center, right

    var textAlignment: TextAlignment {
        switch self {
        case .right:  return .trailing
        case .center: return .center
        default:      return .leading
        }
    }

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .right:  return .right
        case .center: return .center
        default:      return .left
        }
    }
}

/// A simple table: rows of string cells. Row 0 is treated as the header.
@Observable
final class TableData {
    var cells: [[String]]
    /// Per-column horizontal alignment; kept the same length as `columnCount`.
    var columnAlignments: [ColumnAlignment]
    /// Whether the first row / first column is styled as a header.
    var hasHeaderRow: Bool = true
    var hasHeaderColumn: Bool = false

    init(rows: Int = 3, columns: Int = 2) {
        cells = Array(repeating: Array(repeating: "", count: columns), count: rows)
        columnAlignments = Array(repeating: .none, count: columns)
    }
    init(cells: [[String]], alignments: [ColumnAlignment]? = nil) {
        let normalized = cells.isEmpty ? [[""]] : cells
        self.cells = normalized
        let n = normalized.first?.count ?? 0
        var a = alignments ?? []
        if a.count < n { a += Array(repeating: .none, count: n - a.count) }
        columnAlignments = Array(a.prefix(n))
    }

    var rowCount: Int { cells.count }
    var columnCount: Int { cells.first?.count ?? 0 }

    /// Alignment for column `c`, tolerant of a transiently out-of-range index.
    func alignment(_ c: Int) -> ColumnAlignment {
        columnAlignments.indices.contains(c) ? columnAlignments[c] : .none
    }

    func setAlignment(_ a: ColumnAlignment, column c: Int) {
        guard columnAlignments.indices.contains(c) else { return }
        columnAlignments[c] = a
    }

    func addRow() { cells.append(Array(repeating: "", count: columnCount)) }
    func addColumn() { for r in cells.indices { cells[r].append("") }; columnAlignments.append(.none) }

    func insertRow(at i: Int) {
        cells.insert(Array(repeating: "", count: columnCount), at: min(max(i, 0), rowCount))
    }
    func insertColumn(at i: Int) {
        let at = min(max(i, 0), columnCount)
        for r in cells.indices { cells[r].insert("", at: at) }
        columnAlignments.insert(.none, at: min(at, columnAlignments.count))
    }
    func deleteRow(at i: Int) {
        guard rowCount > 1, cells.indices.contains(i) else { return }
        cells.remove(at: i)
    }
    func deleteColumn(at i: Int) {
        guard columnCount > 1 else { return }
        for r in cells.indices where cells[r].indices.contains(i) { cells[r].remove(at: i) }
        if columnAlignments.indices.contains(i) { columnAlignments.remove(at: i) }
    }
}
