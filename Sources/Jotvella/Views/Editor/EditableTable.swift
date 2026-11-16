import SwiftUI

/// Identifies a focused cell within an `EditableTable`.
private struct TableCellPosition: Hashable {
    let row: Int
    let column: Int
}

/// An inline, resizable table editor with add/remove row and column controls and
/// draggable column/row boundaries.
struct EditableTable: View {
    let table: PageTable
    let focusFirstCell: Bool
    let maxWidth: CGFloat
    let onChange: ([[String]]) -> Void
    let onColumnWidthsChange: ([Double]) -> Void
    let onRowHeightsChange: ([Double]) -> Void
    /// Replaces the whole table (rows or columns added, removed or moved) while keeping its sizing.
    let onTableChange: (PageTable) -> Void
    let onDelete: () -> Void
    @FocusState private var focusedCell: TableCellPosition?
    @State private var activeCell: TableCellPosition?
    @State private var showDeleteConfirmation = false
    @State private var resizeStartWidths: [CGFloat]?
    @State private var resizeStartHeights: [CGFloat]?
    @State private var previewColumnWidths: [CGFloat]?
    @State private var previewRowHeights: [CGFloat]?

    private var effectiveColumnWidths: [CGFloat] {
        guard table.columns > 0 else { return [] }
        if let widths = previewColumnWidths, widths.count == table.columns {
            return widths
        }
        if let widths = table.columnWidths, widths.count == table.columns {
            let values = widths.map { CGFloat($0) }
            let total = values.reduce(0, +)
            if total <= maxWidth { return values }
            let scale = maxWidth / total
            return values.map { $0 * scale }
        }
        let width = min(150, maxWidth / CGFloat(table.columns))
        return Array(repeating: width, count: table.columns)
    }

    private var effectiveRowHeights: [CGFloat] {
        guard table.rows > 0 else { return [] }
        if let heights = previewRowHeights, heights.count == table.rows { return heights }
        if let heights = table.rowHeights, heights.count == table.rows {
            return heights.map { max(32, CGFloat($0)) }
        }
        return Array(repeating: 42, count: table.rows)
    }

    /// Moves keyboard focus between cells, adding a row when tabbing past the last cell.
    private func moveFocus(from row: Int, column: Int, backwards: Bool) {
        var target = TableCellPosition(row: row, column: column + (backwards ? -1 : 1))
        if target.column < 0 { target = TableCellPosition(row: row - 1, column: table.columns - 1) }
        else if target.column >= table.columns { target = TableCellPosition(row: row + 1, column: 0) }
        if target.row < 0 { return }
        if target.row >= table.rows {
            guard table.rows < PageTable.maxRows else { return }
            commit(table.insertingRow(at: table.rows))
        }
        DispatchQueue.main.async { focusedCell = target }
    }

    private func moveFocusDown(from row: Int, column: Int) {
        guard row + 1 < table.rows else { return }
        focusedCell = TableCellPosition(row: row + 1, column: column)
    }

    /// Spreads tab-separated clipboard text over the table starting at a cell.
    private func pasteGrid(_ text: String, row: Int, column: Int) {
        commit(table.replacingCells(TableClipboard.apply(TableClipboard.parse(text), to: table.cells, row: row, column: column)))
    }

    /// Sends a structural change up and drops any in-progress resize preview, which belongs to the old shape.
    private func commit(_ updated: PageTable, focus: TableCellPosition? = nil) {
        previewColumnWidths = nil; previewRowHeights = nil
        resizeStartWidths = nil; resizeStartHeights = nil
        onTableChange(updated)
        if let focus {
            activeCell = focus
            DispatchQueue.main.async { focusedCell = focus }
        }
    }

    private var current: TableCellPosition {
        let cell = activeCell ?? focusedCell ?? TableCellPosition(row: table.rows - 1, column: table.columns - 1)
        return TableCellPosition(row: min(max(0, cell.row), table.rows - 1), column: min(max(0, cell.column), table.columns - 1))
    }

    private func deleteRow(_ row: Int) {
        guard let updated = table.deletingRow(at: row) else { return }
        commit(updated, focus: TableCellPosition(row: min(row, updated.rows - 1), column: min(current.column, updated.columns - 1)))
    }

    private func deleteColumn(_ column: Int) {
        guard let updated = table.deletingColumn(at: column) else { return }
        commit(updated, focus: TableCellPosition(row: min(current.row, updated.rows - 1), column: min(column, updated.columns - 1)))
    }

    private func requestDelete() {
        if table.hasContent { showDeleteConfirmation = true } else { onDelete() }
    }

    /// Row, column and table actions for one cell. Used by the header menu and the cell's context menu.
    @ViewBuilder
    private func tableMenu(row: Int, col: Int) -> some View {
        Section("Row \(row + 1)") {
            Button("Insert Row Above", systemImage: "arrow.up.to.line") { commit(table.insertingRow(at: row), focus: TableCellPosition(row: row, column: col)) }
                .disabled(table.rows >= PageTable.maxRows)
            Button("Insert Row Below", systemImage: "arrow.down.to.line") { commit(table.insertingRow(at: row + 1), focus: TableCellPosition(row: row + 1, column: col)) }
                .disabled(table.rows >= PageTable.maxRows)
            Button("Duplicate Row", systemImage: "plus.square.on.square") { commit(table.duplicatingRow(at: row), focus: TableCellPosition(row: row + 1, column: col)) }
                .disabled(table.rows >= PageTable.maxRows)
            Button("Move Row Up", systemImage: "arrow.up") { commit(table.movingRow(from: row, by: -1), focus: TableCellPosition(row: row - 1, column: col)) }
                .disabled(row <= 0)
            Button("Move Row Down", systemImage: "arrow.down") { commit(table.movingRow(from: row, by: 1), focus: TableCellPosition(row: row + 1, column: col)) }
                .disabled(row >= table.rows - 1)
            Button("Clear Row", systemImage: "eraser") { commit(table.clearingRow(at: row)) }
            Button("Delete Row", systemImage: "trash", role: .destructive) { deleteRow(row) }
                .disabled(table.rows <= 1)
        }
        Section("Column \(col + 1)") {
            Button("Insert Column Left", systemImage: "arrow.left.to.line") { commit(table.insertingColumn(at: col), focus: TableCellPosition(row: row, column: col)) }
                .disabled(table.columns >= PageTable.maxColumns)
            Button("Insert Column Right", systemImage: "arrow.right.to.line") { commit(table.insertingColumn(at: col + 1), focus: TableCellPosition(row: row, column: col + 1)) }
                .disabled(table.columns >= PageTable.maxColumns)
            Button("Move Column Left", systemImage: "arrow.left") { commit(table.movingColumn(from: col, by: -1), focus: TableCellPosition(row: row, column: col - 1)) }
                .disabled(col <= 0)
            Button("Move Column Right", systemImage: "arrow.right") { commit(table.movingColumn(from: col, by: 1), focus: TableCellPosition(row: row, column: col + 1)) }
                .disabled(col >= table.columns - 1)
            Button("Clear Column", systemImage: "eraser") { commit(table.clearingColumn(at: col)) }
            Button("Delete Column", systemImage: "trash", role: .destructive) { deleteColumn(col) }
                .disabled(table.columns <= 1)
        }
        Section("Table") {
            Button("Clear Cell", systemImage: "eraser") { commit(table.clearingCell(row: row, column: col)) }
            Toggle("Header Row", isOn: Binding(get: { table.showsHeaderRow }, set: { value in
                var updated = table; updated.hasHeaderRow = value; commit(updated)
            }))
            Button("Delete Table", systemImage: "trash", role: .destructive) { requestDelete() }
        }
    }

    private func headerButton(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 26)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let start = focusedCell ?? TableCellPosition(row: 0, column: 0)
        pasteGrid(text, row: start.row, column: start.column)
    }

    private func resizeBoundary(_ index: Int, by delta: CGFloat) {
        if resizeStartWidths == nil { resizeStartWidths = effectiveColumnWidths }
        guard let start = resizeStartWidths, index + 1 < start.count else { return }
        let pairWidth = start[index] + start[index + 1]
        let adjusted = min(pairWidth - 64, max(64, start[index] + delta))
        var widths = start
        widths[index] = adjusted
        widths[index + 1] = pairWidth - adjusted
        previewColumnWidths = widths
    }

    private func resizeRowBoundary(_ index: Int, by delta: CGFloat) {
        if resizeStartHeights == nil { resizeStartHeights = effectiveRowHeights }
        guard let start = resizeStartHeights, index + 1 < start.count else { return }
        let pairHeight = start[index] + start[index + 1]
        let adjusted = min(pairHeight - 32, max(32, start[index] + delta))
        var heights = start
        heights[index] = adjusted
        heights[index + 1] = pairHeight - adjusted
        previewRowHeights = heights
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label("\(table.rows) × \(table.columns)", systemImage: "tablecells")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                headerButton("plus.rectangle", help: "Add a row below the selected cell (or at the end)", disabled: table.rows >= PageTable.maxRows) {
                    let row = focusedCell == nil && activeCell == nil ? table.rows : current.row + 1
                    commit(table.insertingRow(at: row), focus: TableCellPosition(row: min(row, table.rows), column: min(current.column, table.columns - 1)))
                }
                headerButton("rectangle.split.3x1", help: "Add a column right of the selected cell (or at the end)", disabled: table.columns >= PageTable.maxColumns) {
                    let column = focusedCell == nil && activeCell == nil ? table.columns : current.column + 1
                    commit(table.insertingColumn(at: column), focus: TableCellPosition(row: min(current.row, table.rows - 1), column: min(column, table.columns)))
                }
                headerButton("doc.on.clipboard", help: "Paste copied cells (for example from a spreadsheet) starting at the selected cell") { pasteFromClipboard() }
                headerButton("trash", help: "Delete table") { requestDelete() }
                    .foregroundStyle(Color.red.opacity(0.85))
                    .accessibilityLabel("Delete table")
                Menu { tableMenu(row: current.row, col: current.column) } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 26)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Row, column and table options for the selected cell")
            }
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(table.cells.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.cells[row].indices, id: \.self) { col in
                            TextField("", text: Binding(get: { table.cells[row][col] }, set: { value in
                                if TableClipboard.containsGridSeparators(value) { pasteGrid(value, row: row, column: col); return }
                                var cells = table.cells; cells[row][col] = value; onChange(cells)
                            }))
                            .textFieldStyle(.plain)
                            .onSubmit { moveFocusDown(from: row, column: col) }
                            .modifier(CellTabNavigation { backwards in moveFocus(from: row, column: col, backwards: backwards) })
                            .padding(.horizontal, 9)
                            .frame(width: effectiveColumnWidths[col], height: effectiveRowHeights[row], alignment: .leading)
                            .background(Color.primary.opacity(row == 0 && table.showsHeaderRow ? 0.045 : 0.012))
                            .overlay {
                                Rectangle().strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.6)
                            }
                            .focused($focusedCell, equals: TableCellPosition(row: row, column: col))
                            .contextMenu { tableMenu(row: row, col: col) }
                            .overlay(alignment: .trailing) {
                                if col < table.columns - 1 {
                                    Rectangle()
                                        .fill(Color.clear)
                                        .frame(width: 8)
                                        .contentShape(Rectangle())
                                        .overlay {
                                            Rectangle()
                                                .fill(Color.primary.opacity(0.18))
                                                .frame(width: 1)
                                        }
                                        .gesture(
                                            DragGesture(minimumDistance: 2)
                                                .onChanged { resizeBoundary(col, by: $0.translation.width) }
                                                .onEnded { _ in
                                                    if let previewColumnWidths { onColumnWidthsChange(previewColumnWidths.map(Double.init)) }
                                                    previewColumnWidths = nil
                                                    resizeStartWidths = nil
                                                }
                                        )
                                        .help("Drag to resize columns")
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if row < table.rows - 1 {
                                    Rectangle()
                                        .fill(Color.clear)
                                        .frame(height: 8)
                                        .contentShape(Rectangle())
                                        .overlay {
                                            Rectangle()
                                                .fill(Color.primary.opacity(0.18))
                                                .frame(height: 1)
                                        }
                                        .gesture(
                                            DragGesture(minimumDistance: 2)
                                                .onChanged { resizeRowBoundary(row, by: $0.translation.height) }
                                                .onEnded { _ in
                                                    if let previewRowHeights { onRowHeightsChange(previewRowHeights.map(Double.init)) }
                                                    previewRowHeights = nil
                                                    resizeStartHeights = nil
                                                }
                                        )
                                        .help("Drag to resize rows")
                                }
                            }
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .padding(.vertical, 8)
        .onChange(of: focusedCell) { newValue in
            if let newValue { activeCell = newValue }
        }
        .confirmationDialog("Delete this table?", isPresented: $showDeleteConfirmation) {
            Button("Delete Table", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Everything in the table will be removed.") }
        .onAppear {
            guard focusFirstCell else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedCell = TableCellPosition(row: 0, column: 0)
            }
        }
    }
}


/// Tab and Shift-Tab move between table cells. `onKeyPress` needs macOS 14; on macOS 13
/// the system's default Tab behavior is left alone.
private struct CellTabNavigation: ViewModifier {
    let move: (_ backwards: Bool) -> Void
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onKeyPress(keys: [.tab], phases: .down) { press in
                move(press.modifiers.contains(.shift))
                return .handled
            }
        } else {
            content
        }
    }
}
