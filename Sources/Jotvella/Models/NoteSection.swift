import Foundation

/// A section within a notebook: a named, icon-tagged list of pages.
struct NoteSection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var pages: [NotePage]
    var iconSymbol: String = "folder"

    private enum CodingKeys: String, CodingKey { case id, name, pages, iconSymbol }

    init(id: UUID = UUID(), name: String, pages: [NotePage], iconSymbol: String = "folder") {
        self.id = id
        self.name = name
        self.pages = pages
        self.iconSymbol = iconSymbol
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        pages = try container.decodeIfPresent([NotePage].self, forKey: .pages) ?? []
        iconSymbol = try container.decodeIfPresent(String.self, forKey: .iconSymbol) ?? "folder"
    }
}
