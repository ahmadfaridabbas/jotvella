import Foundation

/// Structural edits on a `PageTable`. Every operation returns a new table and keeps
/// `columnWidths` and `rowHeights` in step with the cells, so resizing survives edits.
/// Operations that cannot apply (out of range, last row or column, size limit) return
/// the table unchanged, or nil where a missing result matters.
extension PageTable {
    static let maxRows = 200
    static let maxColumns = 12
    static let defaultRowHeight = 42.0

    /// Row 0 is shaded as a header unless a table opts out. Optional so old tables look the same.
    var showsHeaderRow: Bool { hasHeaderRow ?? true }

    var hasContent: Bool { cells.contains { row in row.contains { !$0.isEmpty } } }

    private var validRowHeights: [Double]? {
        guard let heights = rowHeights, heights.count == rows else { return nil }
        return heights
    }
    private var validColumnWidths: [Double]? {
        guard let widths = columnWidths, widths.count == columns else { return nil }
        return widths
    }

    // MARK: Rows

    func insertingRow(at index: Int) -> PageTable {
        guard rows < Self.maxRows, columns > 0 else { return self }
        var result = self
        let position = min(max(0, index), rows)
        result.cells.insert(Array(repeating: "", count: columns), at: position)
        result.rowHeights = validRowHeights.map { var heights = $0; heights.insert(Self.defaultRowHeight, at: position); return heights }
        return result
    }

    func duplicatingRow(at index: Int) -> PageTable {
        guard rows < Self.maxRows, cells.indices.contains(index) else { return self }
        var result = self
        result.cells.insert(cells[index], at: index + 1)
        result.rowHeights = validRowHeights.map { var heights = $0; heights.insert(heights[index], at: index + 1); return heights }
        return result
    }

    /// Returns nil when the row does not exist or is the only row.
    func deletingRow(at index: Int) -> PageTable? {
        guard rows > 1, cells.indices.contains(index) else { return nil }
        var result = self
        result.cells.remove(at: index)
        result.rowHeights = validRowHeights.map { var heights = $0; heights.remove(at: index); return heights }
        return result
    }

    func movingRow(from index: Int, by offset: Int) -> PageTable {
        let target = index + offset
        guard cells.indices.contains(index), cells.indices.contains(target), index != target else { return self }
        var result = self
        result.cells.swapAt(index, target)
        result.rowHeights = validRowHeights.map { var heights = $0; heights.swapAt(index, target); return heights }
        return result
    }

    func clearingRow(at index: Int) -> PageTable {
        guard cells.indices.contains(index) else { return self }
        var result = self
        result.cells[index] = Array(repeating: "", count: cells[index].count)
        return result
    }

    // MARK: Columns

    func insertingColumn(at index: Int) -> PageTable {
        guard columns < Self.maxColumns, rows > 0 else { return self }
        var result = self
        let position = min(max(0, index), columns)
        for row in result.cells.indices {
            result.cells[row].insert("", at: min(position, result.cells[row].count))
        }
        result.columnWidths = validColumnWidths.map { widths in
            var updated = widths
            let average = widths.reduce(0, +) / Double(max(1, widths.count))
            updated.insert(min(150, max(70, average)), at: position)
            return updated
        }
        return result
    }

    /// Returns nil when the column does not exist or is the only column.
    func deletingColumn(at index: Int) -> PageTable? {
        guard columns > 1, index >= 0, index < columns else { return nil }
        var result = self
        for row in result.cells.indices where index < result.cells[row].count { result.cells[row].remove(at: index) }
        result.columnWidths = validColumnWidths.map { var widths = $0; widths.remove(at: index); return widths }
        return result
    }

    func movingColumn(from index: Int, by offset: Int) -> PageTable {
        let target = index + offset
        guard index >= 0, index < columns, target >= 0, target < columns, index != target else { return self }
        var result = self
        for row in result.cells.indices where max(index, target) < result.cells[row].count { result.cells[row].swapAt(index, target) }
        result.columnWidths = validColumnWidths.map { var widths = $0; widths.swapAt(index, target); return widths }
        return result
    }

    func clearingColumn(at index: Int) -> PageTable {
        guard index >= 0, index < columns else { return self }
        var result = self
        for row in result.cells.indices where index < result.cells[row].count { result.cells[row][index] = "" }
        return result
    }

    // MARK: Cells

    func clearingCell(row: Int, column: Int) -> PageTable {
        guard cells.indices.contains(row), cells[row].indices.contains(column) else { return self }
        var result = self
        result.cells[row][column] = ""
        return result
    }

    /// Replaces the cells (for example after a paste that grew the table) and pads or trims
    /// the stored sizes to match, instead of discarding them.
    func replacingCells(_ newCells: [[String]]) -> PageTable {
        var result = self
        result.cells = newCells
        let newColumns = newCells.first?.count ?? 0
        if var widths = validColumnWidths ?? columnWidths {
            let fill = min(150, max(70, widths.isEmpty ? 120 : widths.reduce(0, +) / Double(widths.count)))
            while widths.count < newColumns { widths.append(fill) }
            result.columnWidths = Array(widths.prefix(newColumns))
        }
        if var heights = rowHeights {
            while heights.count < newCells.count { heights.append(Self.defaultRowHeight) }
            result.rowHeights = Array(heights.prefix(newCells.count))
        }
        return result
    }
}
