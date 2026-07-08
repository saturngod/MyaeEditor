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
    /// The table model (owned by a segment's payload).
    @Bindable var table: TableData
    /// Shared floating format toolbar (bold / italic / strike / code).
    var formatBar: FormatBarController
    /// Signal that content changed (drives autosave).
    var onEdited: () -> Void
    /// Delete the whole table (removes its segment).
    var onDelete: () -> Void
    /// Step keyboard focus out of the table to the adjacent segment. `down` is
    /// true when leaving through the bottom (down arrow on the last row). Returns
    /// false when there is nowhere to go (table at the document edge, or the
    /// neighbor is a non-editable widget), so the arrow can fall through.
    var onExit: (_ down: Bool) -> Bool = { _ in false }
    /// Reports hover changes up to the enclosing row so its left-gutter controls
    /// (+ and drag handle) stay visible while the pointer is over the table's
    /// AppKit-backed cells — the row's own `.onHover` drops there.
    var onHoverChange: ((Bool) -> Void)? = nil

    @State private var hovering = false
    @State private var hoveredRow: Int?
    @State private var hoveredColumn: Int?
    /// Delays clearing `hoveredRow`/`hoveredColumn` when the pointer leaves the
    /// grid, so it can cross into the row/column "…" handles (which float in the
    /// gutter / top-bleed, outside the grid's `.onHover` frame) before they hide.
    @State private var clearHoverTask: Task<Void, Never>?
    /// The cell currently editing (drives the active-cell ring + Tab navigation).
    /// Plain state, not @FocusState, because cells are NSTextView-backed.
    @State private var activeCell: TableCellID?
    /// Width available to the grid (the horizontal scroll viewport width).
    @State private var availableWidth: CGFloat = 0
    /// Each row's frame (in the table coordinate space) so the pinned row
    /// handles can float in the gutter at the right vertical offset even though
    /// they live outside the scroll content. x/width are zeroed so horizontal
    /// scrolling doesn't churn this state.
    @State private var rowFrames: [Int: CGRect] = [:]

    private let rowMinHeight: CGFloat = 32
    private let borderWidth: CGFloat = 0.5
    // How far the row handle floats into the left gutter. The 11×22 pill is
    // rotated 90°, so its *rendering* is 22 wide centered on the 11pt layout
    // frame (±5.5pt overhang each side) — inset far enough that the rotated
    // face clears the table's left border instead of overlaying the first cell.
    private let handleInset: CGFloat = 24
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
    private func edit(_ change: () -> Void) { change(); onEdited() }

    /// Tab / Shift+Tab focus movement: advance across the row, wrapping to the
    /// next/previous row. Stops (stays put) at the first/last cell.
    private func moveFocus(from id: TableCellID, forward: Bool, in table: TableData) {
        let cols = table.columnCount, rows = table.rowCount
        guard cols > 0, rows > 0 else { return }
        var index = id.r * cols + id.c + (forward ? 1 : -1)
        index = max(0, min(index, rows * cols - 1))
        activeCell = TableCellID(r: index / cols, c: index % cols)
    }

    /// Up/down arrow from a cell edge: move to the same column in the row above/
    /// below, or step out of the table when already at the top/bottom row. Returns
    /// whether the move was handled — at the top/bottom edge it reports whatever
    /// `onExit` did, so a trapped arrow (nowhere to go) falls through to the cell.
    private func moveVertically(from id: TableCellID, down: Bool, in table: TableData) -> Bool {
        if down {
            if id.r < table.rowCount - 1 { activeCell = TableCellID(r: id.r + 1, c: id.c); return true }
            return onExit(true)
        } else {
            if id.r > 0 { activeCell = TableCellID(r: id.r - 1, c: id.c); return true }
            return onExit(false)
        }
    }

    /// Left/right arrow at a cell's start/end: advance in row-major order (same
    /// path as Tab), wrapping across rows; step out of the table at the very
    /// first/last cell. Returns whether the move was handled.
    private func moveHorizontally(from id: TableCellID, forward: Bool, in table: TableData) -> Bool {
        let cols = table.columnCount, rows = table.rowCount
        guard cols > 0, rows > 0 else { return false }
        let index = id.r * cols + id.c + (forward ? 1 : -1)
        if index < 0 { return onExit(false) }
        if index > rows * cols - 1 { return onExit(true) }
        activeCell = TableCellID(r: index / cols, c: index % cols)
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                scrollableGrid(table)
                // Always clickable: kept faintly visible so it can't hide out from
                // under the pointer as you reach for it.
                addColumnButton(table).opacity(hovering ? 1 : 0.4)
            }
            addRowButton(table).opacity(hovering ? 1 : 0.4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover {
            hovering = $0
            onHoverChange?($0)
            if $0 { keepHover() } else { scheduleClearHover() }
        }
        // Keyboard nav (up/down arrow from a neighbouring segment) requested that
        // the caret enter this table — focus column 0 of the requested row.
        .onChange(of: table.pendingFocusRow) { _, row in
            guard let row else { return }
            let r = max(0, min(row, table.rowCount - 1))
            activeCell = TableCellID(r: r, c: 0)
            table.pendingFocusRow = nil
        }
    }

    /// Cancel a pending hover clear — the pointer is over the grid or a handle.
    private func keepHover() {
        clearHoverTask?.cancel()
        clearHoverTask = nil
    }

    /// Clear the hovered row/column after a short grace period, giving the
    /// pointer time to cross into a floating "…" handle before it disappears.
    private func scheduleClearHover() {
        clearHoverTask?.cancel()
        clearHoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            hoveredRow = nil
            hoveredColumn = nil
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
                    // Reserve room for the column handles INSIDE the scroll
                    // view's bounds — content drawn above an NSScrollView's
                    // frame renders (with a clip bleed) but can never be
                    // clicked, since AppKit hit-testing stops at the frame.
                    .padding(.top, topBleed)
            }
            // Don't rubber-band horizontally when the table already fits.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            // Pull the row back up so the reserved handle strip overlaps the
            // gap above the block instead of pushing the grid down.
            .padding(.top, -topBleed)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { availableWidth = $0 }
            .coordinateSpace(name: "tableSpace")
            // Row handles are pinned to the viewport's left gutter (they must
            // stay visible while the grid scrolls, so they live outside the
            // scroll content).
            .overlay(alignment: .topLeading) { rowHandleGutter(table) }
            // Reveal the focused cell when Tab/click moves focus off-screen.
            // `anchor: nil` scrolls the minimum needed, so visible cells don't move.
            .onChange(of: activeCell) { _, new in
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
                    Button("Delete table", role: .destructive) { onDelete() }
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
                .onHover { if $0 { keepHover(); hoveredColumn = c } }
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
                        .onHover { if $0 { keepHover(); hoveredRow = r } }
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
            Button("Delete table", role: .destructive) { onDelete() }
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
            isFocused: activeCell == TableCellID(r: r, c: c),
            alignment: table.alignment(c),
            isLastRow: r == table.rowCount - 1,
            isLastCol: c == table.columnCount - 1,
            minHeight: rowMinHeight,
            borderWidth: borderWidth,
            formatBar: formatBar,
            activeCell: $activeCell,
            onTab: { forward in moveFocus(from: TableCellID(r: r, c: c), forward: forward, in: table) },
            onVerticalMove: { down in moveVertically(from: TableCellID(r: r, c: c), down: down, in: table) },
            onHorizontalMove: { forward in moveHorizontally(from: TableCellID(r: r, c: c), forward: forward, in: table) },
            setText: { new in
                if table.cells.indices.contains(r), table.cells[r].indices.contains(c) {
                    table.cells[r][c] = new
                    onEdited()
                }
            },
            onHover: { if $0 { keepHover(); if hoveredRow != r { hoveredRow = r }; if hoveredColumn != c { hoveredColumn = c } } },
            menu: TableCellMenu(
                insertRowAbove: { edit { table.insertRow(at: r) } },
                insertRowBelow: { edit { table.insertRow(at: r + 1) } },
                insertColumnLeft: { edit { table.insertColumn(at: c) } },
                insertColumnRight: { edit { table.insertColumn(at: c + 1) } },
                deleteRow: { edit { table.deleteRow(at: r) } },
                deleteColumn: { edit { table.deleteColumn(at: c) } },
                deleteTable: { onDelete() }
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
    /// False in read-only mode — gates the context-menu mutation items.
    @Environment(\.isEnabled) private var isEnabled

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
    var formatBar: FormatBarController
    @Binding var activeCell: TableCellID?
    let onTab: (_ forward: Bool) -> Void
    let onVerticalMove: (_ down: Bool) -> Bool
    let onHorizontalMove: (_ forward: Bool) -> Bool
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isHeader {
                Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5)
            }
            // NSTextView-backed editor: same bold/italic/strike/inline-code support
            // (Cmd+B/I/E, Cmd+Shift+S, and the floating format bar) as a paragraph
            // block. Cell text is stored as inline Markdown.
            TableCellTextView(
                markdown: binding,
                isHeader: isHeader,
                alignment: alignment,
                formatBar: formatBar,
                cellID: TableCellID(r: r, c: c),
                activeCell: $activeCell,
                onTab: onTab,
                onVerticalMove: onVerticalMove,
                onHorizontalMove: onHorizontalMove
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
            // Context menus aren't controls, so .disabled alone doesn't block
            // them — hide the mutation items entirely in read-only mode.
            if isEnabled {
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

