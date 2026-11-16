import Foundation

/// A single page on the free canvas, composed of positioned content blocks,
/// images, and (legacy) tables.
struct NotePage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var body: String = ""
    var richTextData: Data? = nil
    var images: [PageImage] = []
    var tables: [PageTable] = []
    var contentBlocks: [PageContentBlock] = []
    var modified: Date = .now
    /// Optional so pages saved before tags existed decode unchanged.
    var tags: [String]? = nil

    private enum CodingKeys: String, CodingKey { case id, title, body, richTextData, images, tables, contentBlocks, modified, tags }
    init(id: UUID = UUID(), title: String, body: String = "", richTextData: Data? = nil, images: [PageImage] = [], tables: [PageTable] = [], contentBlocks: [PageContentBlock] = [], modified: Date = .now, tags: [String]? = nil) {
        self.id = id; self.title = title; self.body = body; self.richTextData = richTextData; self.images = images; self.tables = tables; self.contentBlocks = contentBlocks; self.modified = modified; self.tags = tags
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        richTextData = try c.decodeIfPresent(Data.self, forKey: .richTextData)
        images = try c.decodeIfPresent([PageImage].self, forKey: .images) ?? []
        tables = try c.decodeIfPresent([PageTable].self, forKey: .tables) ?? []
        contentBlocks = try c.decodeIfPresent([PageContentBlock].self, forKey: .contentBlocks) ?? []
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? .now
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
    }
}

/// A positioned image placed on a page's canvas.
struct PageImage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var filename: String
    var x: Double
    var y: Double
    var width: Double
}

/// A grid of string cells with optional per-column/row sizing.
struct PageTable: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var cells: [[String]]
    var columnWidths: [Double]?
    var rowHeights: [Double]?
    /// nil means "shade the first row as a header" (how tables always looked). Optional so old tables decode unchanged.
    var hasHeaderRow: Bool? = nil
    init(id: UUID = UUID(), cells: [[String]], columnWidths: [Double]? = nil, rowHeights: [Double]? = nil) {
        self.id = id
        self.cells = cells
        self.columnWidths = columnWidths
        self.rowHeights = rowHeights
    }
    var columns: Int { cells.first?.count ?? 0 }
    var rows: Int { cells.count }
}

/// One block in a page's content stream: either rich/plain text or a table.
struct PageContentBlock: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var text: String?
    var table: PageTable?
    var richTextData: Data?
    /// When true the text block is shown as a monospaced code block. Optional so older pages decode unchanged.
    var isCode: Bool? = nil
    static func textBlock(_ text: String, id: UUID = UUID(), richTextData: Data? = nil) -> Self { .init(id: id, text: text, table: nil, richTextData: richTextData) }
    static func tableBlock(_ table: PageTable) -> Self { .init(id: table.id, text: nil, table: table) }
}
