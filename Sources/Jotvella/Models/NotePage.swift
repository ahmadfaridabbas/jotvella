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

    private enum CodingKeys: String, CodingKey { case id, title, body, richTextData, images, tables, contentBlocks, modified }
    init(id: UUID = UUID(), title: String, body: String = "", richTextData: Data? = nil, images: [PageImage] = [], tables: [PageTable] = [], contentBlocks: [PageContentBlock] = [], modified: Date = .now) {
        self.id = id; self.title = title; self.body = body; self.richTextData = richTextData; self.images = images; self.tables = tables; self.contentBlocks = contentBlocks; self.modified = modified
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
    static func textBlock(_ text: String, id: UUID = UUID(), richTextData: Data? = nil) -> Self { .init(id: id, text: text, table: nil, richTextData: richTextData) }
    static func tableBlock(_ table: PageTable) -> Self { .init(id: table.id, text: nil, table: table) }
}
