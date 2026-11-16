import Foundation

/// Parsing for the plain-text list markers the editor uses ("• ", "☐ ", "☑ ", "1. ").
/// Lists stay ordinary characters in the text, so stored pages are unchanged.
enum ListMarker {
    static let bullet = "• "
    static let unchecked = "☐ "
    static let checked = "☑ "

    struct Match: Equatable {
        /// Number of leading spaces before the marker.
        var indent: Int
        /// The marker itself, for example "• " or "12. ".
        var marker: String
        /// The item number for numbered markers.
        var number: Int?
        var isChecklist: Bool
        /// Length in UTF-16 units of indent plus marker.
        var prefixLength: Int { indent + (marker as NSString).length }
    }

    /// Returns the marker at the start of `line`, or nil if the line is not a list item.
    static func parse(_ line: String) -> Match? {
        let indent = line.prefix(while: { $0 == " " }).count
        let rest = line.dropFirst(indent)
        for marker in [bullet, unchecked, checked] where rest.hasPrefix(marker) {
            return Match(indent: indent, marker: marker, number: nil, isChecklist: marker != bullet)
        }
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 6, rest.dropFirst(digits.count).hasPrefix(". "), let number = Int(digits) else { return nil }
        return Match(indent: indent, marker: "\(digits). ", number: number, isChecklist: false)
    }

    /// The text to insert at the start of the next line when Enter is pressed on `match`.
    static func continuation(of match: Match) -> String {
        let spaces = String(repeating: " ", count: match.indent)
        if let number = match.number { return spaces + "\(number + 1). " }
        return spaces + (match.isChecklist ? unchecked : bullet)
    }
}

/// Markdown-style triggers typed at the start of a line, completed with a space.
enum MarkdownShortcut {
    /// `lineBeforeSpace` is the text from the start of the line to the caret.
    static func kind(forLineBeforeSpace line: String) -> EditorCommand.Kind? {
        if !line.isEmpty, line.count <= 6, line.allSatisfy({ $0 == "#" }) { return .heading(line.count) }
        switch line {
        case "-", "*": return .linePrefix(ListMarker.bullet)
        case "[]": return .linePrefix(ListMarker.unchecked)
        case ">": return .heading(103)
        default: break
        }
        if line.count >= 2, line.hasSuffix("."), line.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }) { return .linePrefix("1. ") }
        return nil
    }
}

/// Case-insensitive, non-overlapping search used by Find in Page.
enum FindMatches {
    static func ranges(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var result: [NSRange] = []
        var cursor = 0
        while cursor < source.length {
            let found = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: cursor, length: source.length - cursor))
            guard found.location != NSNotFound, found.length > 0 else { break }
            result.append(found)
            cursor = NSMaxRange(found)
        }
        return result
    }
}

/// Tab-separated clipboard text (as copied from spreadsheets) mapped onto table cells.
enum TableClipboard {
    static func parse(_ text: String) -> [[String]] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        while lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return lines.map { $0.components(separatedBy: "\t") }
    }

    /// Writes `grid` into `cells` starting at (`row`, `column`), growing the table as needed.
    static func apply(_ grid: [[String]], to cells: [[String]], row: Int, column: Int) -> [[String]] {
        guard !cells.isEmpty, !grid.isEmpty else { return cells }
        var result = cells
        let width = max(cells[0].count, column + (grid.map(\.count).max() ?? 0))
        let height = max(cells.count, row + grid.count)
        for index in result.indices { result[index] += Array(repeating: "", count: width - result[index].count) }
        while result.count < height { result.append(Array(repeating: "", count: width)) }
        for (r, line) in grid.enumerated() {
            for (c, value) in line.enumerated() { result[row + r][column + c] = value }
        }
        return result
    }

    static func containsGridSeparators(_ value: String) -> Bool {
        value.contains("\t") || value.contains("\n") || value.contains("\r")
    }
}

/// Normalizes tag text typed by the user.
enum TagText {
    static func normalized(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("#") { value.removeFirst() }
        return value.split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }
}
