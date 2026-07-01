//
//  TableBlockView.swift
//  MyaeEditor
//
//  An editable table. Columns share the editor width equally.
//  Row/column option handles float in the gutter on hover (they don't take
//  layout space, so the grid left-aligns with the surrounding text). The "+"
//  bars add a row (bottom) or column (right). Cells also have a right-click
//  context menu.
//

import SwiftUI

struct TableBlockView: View {
    @Bindable var document: EditorDocument
    @Bindable var block: Block

    @State private var hovering = false
    @State private var hoveredRow: Int?
    @State private var hoveredColumn: Int?

    private let rowMinHeight: CGFloat = 32
    private let borderWidth: CGFloat = 0.5
    private let handleInset: CGFloat = 20   // how far the row handle floats into the left gutter

    /// Run a structural table change and signal the document for autosave.
    private func edit(_ change: () -> Void) { change(); document.markEdited() }

    var body: some View {
        if let table = block.table {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 4) {
                    tableGrid(table)
                    addColumnButton(table).opacity(hovering ? 1 : 0)
                }
                addRowButton(table).opacity(hovering ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover {
                hovering = $0
                if !$0 { hoveredRow = nil; hoveredColumn = nil }
            }
        }
    }

    // MARK: Table grid (single outer border + internal lines)

    private func tableGrid(_ table: TableData) -> some View {
        // Lazy so only the rows near the viewport keep live TextFields — a wide
        // table no longer instantiates every cell (hundreds) at once. Equal-width
        // columns and per-row maxHeight sizing are unaffected by laziness.
        LazyVStack(spacing: 0) {
            ForEach(0 ..< table.rowCount, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0 ..< table.columnCount, id: \.self) { c in
                        cell(table, r, c)
                    }
                }
                // Row handle floats in the left gutter; it does not take layout
                // space, so the grid stays aligned with surrounding blocks.
                .overlay(alignment: .leading) {
                    rowHandle(r, table: table)
                        .offset(x: -handleInset)
                        .opacity(hoveredRow == r ? 1 : 0)
                }
            }
        }
        .overlay(tableBorder)
        // Column handles float just above the grid, aligned to each column.
        .overlay(alignment: .top) { columnHandles(table) }
    }

    private var tableBorder: some View {
        Rectangle()
            .stroke(Color(nsColor: .separatorColor), lineWidth: borderWidth)
    }

    // MARK: Handles row / column

    private func columnHandles(_ table: TableData) -> some View {
        HStack(spacing: 0) {
            ForEach(0 ..< table.columnCount, id: \.self) { c in
                Menu {
                    Button("Insert column left") { edit { table.insertColumn(at: c) } }
                    Button("Insert column right") { edit { table.insertColumn(at: c + 1) } }
                    Divider()
                    Button("Delete column", role: .destructive) { edit { table.deleteColumn(at: c) } }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                        Image(systemName: "ellipsis").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 11)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity)
                .opacity(hoveredColumn == c ? 1 : 0)
                .help("Column options")
            }
        }
        .frame(height: 12)
        .offset(y: -14)
    }

    private func rowHandle(_ r: Int, table: TableData) -> some View {
        Menu {
            Button("Insert row above") { edit { table.insertRow(at: r) } }
            Button("Insert row below") { edit { table.insertRow(at: r + 1) } }
            Divider()
            Button("Delete row", role: .destructive) { edit { table.deleteRow(at: r) } }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                Image(systemName: "ellipsis").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary).rotationEffect(.degrees(90))
            }
            .frame(width: 11, height: 22)
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Row options")
    }

    // MARK: Cell

    private func cell(_ table: TableData, _ r: Int, _ c: Int) -> some View {
        let isHeader = (table.hasHeaderRow && r == 0) || (table.hasHeaderColumn && c == 0)
        // r/c come from ForEach over rowCount/columnCount and cells is rectangular,
        // so a direct read is safe. (setText still guards against mid-mutation races.)
        let text = table.cells[r][c]
        // `.equatable()` skips re-rendering this cell when only its neighbours or
        // the table's hover state change — so hovering while scrolling and typing
        // in one cell no longer rebuild the whole grid.
        return TableCellView(
            text: text,
            r: r, c: c,
            isHeader: isHeader,
            isLastRow: r == table.rowCount - 1,
            isLastCol: c == table.columnCount - 1,
            minHeight: rowMinHeight,
            borderWidth: borderWidth,
            setText: { new in
                if table.cells.indices.contains(r), table.cells[r].indices.contains(c) {
                    table.cells[r][c] = new
                    document.markEdited()
                }
            },
            onHover: { if $0 { if hoveredRow != r { hoveredRow = r }; if hoveredColumn != c { hoveredColumn = c } } },
            menu: TableCellMenu(
                insertRowAbove: { edit { table.insertRow(at: r) } },
                insertRowBelow: { edit { table.insertRow(at: r + 1) } },
                insertColumnLeft: { edit { table.insertColumn(at: c) } },
                insertColumnRight: { edit { table.insertColumn(at: c + 1) } },
                deleteRow: { edit { table.deleteRow(at: r) } },
                deleteColumn: { edit { table.deleteColumn(at: c) } },
                deleteTable: { document.removeBlock(block) }
            )
        )
        .equatable()
    }

    // MARK: Add buttons

    private func addRowButton(_ table: TableData) -> some View {
        Button { edit { table.addRow() } } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Add row")
    }

    private func addColumnButton(_ table: TableData) -> some View {
        Button { edit { table.addColumn() } } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 18)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Add column")
    }

}

/// The cell's context-menu actions, bundled so `TableCellView` can stay
/// `Equatable` (these closures are excluded from equality).
struct TableCellMenu {
    let insertRowAbove: () -> Void
    let insertRowBelow: () -> Void
    let insertColumnLeft: () -> Void
    let insertColumnRight: () -> Void
    let deleteRow: () -> Void
    let deleteColumn: () -> Void
    let deleteTable: () -> Void
}

/// One table cell. Conforms to `Equatable` (comparing only its value inputs, not
/// its closures) so SwiftUI skips rebuilding it when unrelated cells, hover
/// state, or other cells' text change. This is what keeps large tables smooth:
/// hovering during a scroll and typing in a single cell no longer re-render the
/// entire grid.
struct TableCellView: View, Equatable {
    let text: String
    let r: Int
    let c: Int
    let isHeader: Bool
    let isLastRow: Bool
    let isLastCol: Bool
    let minHeight: CGFloat
    let borderWidth: CGFloat
    let setText: (String) -> Void
    let onHover: (Bool) -> Void
    let menu: TableCellMenu

    static func == (lhs: TableCellView, rhs: TableCellView) -> Bool {
        lhs.text == rhs.text &&
        lhs.r == rhs.r && lhs.c == rhs.c &&
        lhs.isHeader == rhs.isHeader &&
        lhs.isLastRow == rhs.isLastRow && lhs.isLastCol == rhs.isLastCol &&
        lhs.minHeight == rhs.minHeight && lhs.borderWidth == rhs.borderWidth
    }

    private var binding: Binding<String> {
        Binding(get: { text }, set: { setText($0) })
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isHeader {
                Color.secondary.opacity(0.06)
            }
            TextField("", text: binding, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: isHeader ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // maxHeight lets every cell stretch to the tallest cell in its row so the
        // borders line up even when one cell wraps to several lines. The ideal
        // height stays content-based (maxHeight only fills a concrete proposal),
        // so long text is not clipped.
        .frame(minHeight: minHeight, maxHeight: .infinity, alignment: .topLeading)
        .overlay(dividers)
        .onHover(perform: onHover)
        .contextMenu {
            Button("Insert row above") { menu.insertRowAbove() }
            Button("Insert row below") { menu.insertRowBelow() }
            Button("Insert column left") { menu.insertColumnLeft() }
            Button("Insert column right") { menu.insertColumnRight() }
            Divider()
            Button("Delete row", role: .destructive) { menu.deleteRow() }
            Button("Delete column", role: .destructive) { menu.deleteColumn() }
            Divider()
            Button("Delete table", role: .destructive) { menu.deleteTable() }
        }
    }

    @ViewBuilder
    private var dividers: some View {
        // Bottom border (skip for last row — outer border handles it)
        if !isLastRow {
            VStack {
                Spacer()
                Color(nsColor: .separatorColor).frame(height: borderWidth)
            }
        }
        // Right border (skip for last column — outer border handles it)
        if !isLastCol {
            HStack {
                Spacer()
                Color(nsColor: .separatorColor).frame(width: borderWidth)
            }
        }
    }
}
