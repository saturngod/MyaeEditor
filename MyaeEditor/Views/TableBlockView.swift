//
//  TableBlockView.swift
//  MyaeEditor
//
//  An editable table. Columns share the editor width equally while they fit;
//  once the table needs more than the editor width (many columns), each column
//  holds a minimum width and the grid scrolls horizontally (Notion-style).
//  Row option handles are pinned in the left gutter of the scroll viewport so
//  they stay visible while scrolled; column handles scroll with their columns.
//  The "+" bars add a row (bottom) or column (right, pinned to the viewport
//  edge). Cells also have a right-click context menu.
//

import SwiftUI

/// Identifies a cell for keyboard-focus tracking (drives the active-cell ring).
struct TableCellID: Hashable { let r: Int; let c: Int }

struct TableBlockView: View {
    @Bindable var document: EditorDocument
    @Bindable var block: Block

    @State private var hovering = false
    @State private var hoveredRow: Int?
    @State private var hoveredColumn: Int?
    @FocusState private var focusedCell: TableCellID?
    /// Width available to the grid (the horizontal scroll viewport width).
    @State private var availableWidth: CGFloat = 0
    /// Each row's frame (in the table coordinate space) so the pinned row
    /// handles can float in the gutter at the right vertical offset even though
    /// they live outside the scroll content. x/width are zeroed so horizontal
    /// scrolling doesn't churn this state.
    @State private var rowFrames: [Int: CGRect] = [:]

    private let rowMinHeight: CGFloat = 32
    private let borderWidth: CGFloat = 0.5
    private let handleInset: CGFloat = 14   // how far the row handle floats into the left gutter
    private let minColumnWidth: CGFloat = 120  // below this, the table scrolls instead of shrinking
    private let topBleed: CGFloat = 16      // vertical room the clip leaves for column handles above the grid
    private let rowHandleHeight: CGFloat = 22

    /// Width to propose to the grid: fill the viewport when the columns fit,
    /// otherwise hold every column at `minColumnWidth` and let the grid overflow
    /// (the horizontal ScrollView then scrolls).
    private func contentWidth(_ table: TableData) -> CGFloat {
        max(availableWidth, minColumnWidth * CGFloat(table.columnCount))
    }

    /// Run a structural table change and signal the document for autosave.
    private func edit(_ change: () -> Void) { change(); document.markEdited() }

    var body: some View {
        if let table = block.table {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 4) {
                    scrollableGrid(table)
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

    /// The grid wrapped in a horizontal ScrollView. The scroll view is always
    /// present (not conditional on overflow) so the table keeps a stable view
    /// identity when columns are added/removed or the window resizes — otherwise
    /// crossing the fit/overflow threshold would drop the focused cell's editor.
    private func scrollableGrid(_ table: TableData) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                tableGrid(table)
                    .frame(width: contentWidth(table))
            }
            // Don't rubber-band horizontally when the table already fits.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            // Disable the default clip, then re-clip so column handles above the
            // grid aren't cut off while cell content is still clipped at the
            // viewport edges.
            .scrollClipDisabled()
            .clipShape(TopBleedClip(bleed: topBleed))
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { availableWidth = $0 }
            .coordinateSpace(name: "tableSpace")
            // Row handles are pinned to the viewport's left gutter (they must
            // stay visible while the grid scrolls, so they live outside the
            // scroll content).
            .overlay(alignment: .topLeading) { rowHandleGutter(table) }
            // Reveal the focused cell when Tab/click moves focus off-screen.
            // `anchor: nil` scrolls the minimum needed, so visible cells don't move.
            .onChange(of: focusedCell) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(new, anchor: nil) }
            }
        }
    }

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
                // Publish the row's frame so the pinned gutter handle can align
                // to it. x/width are zeroed so horizontal scrolling (which shifts
                // minX) doesn't fire this action on every scroll tick.
                .onGeometryChange(for: CGRect.self, of: {
                    let f = $0.frame(in: .named("tableSpace"))
                    return CGRect(x: 0, y: f.minY, width: 0, height: f.height)
                }) { rowFrames[r] = $0 }
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
                    Menu("Align") {
                        alignButton("Left", .left, "text.alignleft", table, c)
                        alignButton("Center", .center, "text.aligncenter", table, c)
                        alignButton("Right", .right, "text.alignright", table, c)
                    }
                    Divider()
                    Button("Delete column", role: .destructive) { edit { table.deleteColumn(at: c) } }
                    Button("Delete table", role: .destructive) { document.removeBlock(block) }
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
                .onHover { if $0 { hoveredColumn = c } }
                .help("Column options")
            }
        }
        .frame(height: 12)
        .offset(y: -14)
    }

    /// One entry in the column "Align" submenu; toggles the alignment off if it's
    /// already the current one, and marks the active choice with a check.
    private func alignButton(_ title: String, _ a: ColumnAlignment, _ symbol: String,
                             _ table: TableData, _ c: Int) -> some View {
        Button {
            edit { table.setAlignment(table.alignment(c) == a ? .none : a, column: c) }
        } label: {
            Label(table.alignment(c) == a ? "\(title) ✓" : title, systemImage: symbol)
        }
    }

    /// The stack of row handles pinned in the left gutter of the scroll
    /// viewport. Each handle floats at its row's vertical centre using the
    /// measured `rowFrames`, so it stays put while the grid scrolls sideways.
    private func rowHandleGutter(_ table: TableData) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0 ..< table.rowCount, id: \.self) { r in
                if let f = rowFrames[r] {
                    rowHandle(r, table: table)
                        .offset(x: -handleInset,
                                y: f.minY + (f.height - rowHandleHeight) / 2)
                        .opacity(hoveredRow == r ? 1 : 0)
                        // Keep the handle alive while the pointer is on it, so it
                        // doesn't fade out from under the cursor as you reach for it.
                        .onHover { if $0 { hoveredRow = r } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rowHandle(_ r: Int, table: TableData) -> some View {
        Menu {
            Button("Insert row above") { edit { table.insertRow(at: r) } }
            Button("Insert row below") { edit { table.insertRow(at: r + 1) } }
            Divider()
            Button("Delete row", role: .destructive) { edit { table.deleteRow(at: r) } }
            Button("Delete table", role: .destructive) { document.removeBlock(block) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                Image(systemName: "ellipsis").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary).rotationEffect(.degrees(90))
            }
            .frame(width: 11, height: rowHandleHeight)
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
            isFocused: focusedCell == TableCellID(r: r, c: c),
            alignment: table.alignment(c),
            isLastRow: r == table.rowCount - 1,
            isLastCol: c == table.columnCount - 1,
            minHeight: rowMinHeight,
            borderWidth: borderWidth,
            focus: $focusedCell,
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
        // Target for scroll-into-view when this cell gains focus.
        .id(TableCellID(r: r, c: c))
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
    let isFocused: Bool
    let alignment: ColumnAlignment
    let isLastRow: Bool
    let isLastCol: Bool
    let minHeight: CGFloat
    let borderWidth: CGFloat
    var focus: FocusState<TableCellID?>.Binding
    let setText: (String) -> Void
    let onHover: (Bool) -> Void
    let menu: TableCellMenu

    static func == (lhs: TableCellView, rhs: TableCellView) -> Bool {
        lhs.text == rhs.text &&
        lhs.r == rhs.r && lhs.c == rhs.c &&
        lhs.isHeader == rhs.isHeader &&
        lhs.isFocused == rhs.isFocused &&
        lhs.alignment == rhs.alignment &&
        lhs.isLastRow == rhs.isLastRow && lhs.isLastCol == rhs.isLastCol &&
        lhs.minHeight == rhs.minHeight && lhs.borderWidth == rhs.borderWidth
    }

    private var binding: Binding<String> {
        Binding(get: { text }, set: { setText($0) })
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .right:  return .topTrailing
        case .center: return .top
        default:      return .topLeading
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isHeader {
                Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5)
            }
            TextField("", text: binding, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: isHeader ? .semibold : .regular))
                .multilineTextAlignment(alignment.textAlignment)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .focused(focus, equals: TableCellID(r: r, c: c))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // maxHeight lets every cell stretch to the tallest cell in its row so the
        // borders line up even when one cell wraps to several lines. The ideal
        // height stays content-based (maxHeight only fills a concrete proposal),
        // so long text is not clipped.
        .frame(minHeight: minHeight, maxHeight: .infinity, alignment: .topLeading)
        .overlay(dividers)
        // Accent ring on the active cell so you can see where focus is in a big grid.
        .overlay {
            if isFocused {
                Rectangle().stroke(Color.accentColor, lineWidth: 2).padding(borderWidth)
            }
        }
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

/// A clip that matches the view's bounds but extends upward by `bleed`, so the
/// column handles floating above the grid stay visible while the horizontal
/// scroll still clips cell content at the left/right/bottom viewport edges.
private struct TopBleedClip: Shape {
    var bleed: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - bleed,
                    width: rect.width, height: rect.height + bleed))
    }
}
