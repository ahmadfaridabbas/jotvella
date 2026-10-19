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
    let onDelete: () -> Void
    @FocusState private var focusedCell: TableCellPosition?
    @State private var resizeStartWidths: [CGFloat]?
    @State private var resizeStartHeights: [CGFloat]?
    @State private var previewColumnWidths: [CGFloat]?
    @State private var previewRowHeights: [CGFloat]?
    @State private var showTableOptions = false

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
                Button {
                    var cells = table.cells
                    cells.append(Array(repeating: "", count: table.columns))
                    onChange(cells)
                } label: {
                    Image(systemName: "plus.rectangle")
                        .frame(width: 28, height: 26)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Add row")
                Button {
                    var cells = table.cells
                    for index in cells.indices { cells[index].append("") }
                    onChange(cells)
                } label: {
                    Image(systemName: "rectangle.split.3x1")
                        .frame(width: 28, height: 26)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Add column")
                Button { showTableOptions.toggle() } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 26)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Table options")
                .popover(isPresented: $showTableOptions, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            if table.rows > 1 { onChange(Array(table.cells.dropLast())) }
                            showTableOptions = false
                        } label: {
                            Label("Remove last row", systemImage: "minus.rectangle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(table.rows <= 1)
                        .buttonStyle(.plain)
                        .padding(.vertical, 5)

                        Button {
                            if table.columns > 1 { onChange(table.cells.map { Array($0.dropLast()) }) }
                            showTableOptions = false
                        } label: {
                            Label("Remove last column", systemImage: "rectangle.split.3x1")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(table.columns <= 1)
                        .buttonStyle(.plain)
                        .padding(.vertical, 5)

                        Divider().padding(.vertical, 3)

                        Button(role: .destructive) {
                            showTableOptions = false
                            onDelete()
                        } label: {
                            Label("Delete table", systemImage: "trash")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 5)
                    }
                    .padding(10)
                    .frame(width: 190)
                }
            }
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(table.cells.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.cells[row].indices, id: \.self) { col in
                            TextField("", text: Binding(get: { table.cells[row][col] }, set: { value in
                                var cells = table.cells; cells[row][col] = value; onChange(cells)
                            }))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 9)
                            .frame(width: effectiveColumnWidths[col], height: effectiveRowHeights[row], alignment: .leading)
                            .background(Color.primary.opacity(row == 0 ? 0.045 : 0.012))
                            .overlay {
                                Rectangle().strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.6)
                            }
                            .focused($focusedCell, equals: TableCellPosition(row: row, column: col))
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
        .onAppear {
            guard focusFirstCell else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedCell = TableCellPosition(row: 0, column: 0)
            }
        }
    }
}
