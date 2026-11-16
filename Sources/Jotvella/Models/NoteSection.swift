import Foundation

/// A section within a notebook: a named, icon-tagged list of pages.
struct NoteSection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var pages: [NotePage]
    var iconSymbol: String = NoteSection.defaultIcon
    static let defaultIcon = "book.closed"

    private enum CodingKeys: String, CodingKey { case id, name, pages, iconSymbol }

    init(id: UUID = UUID(), name: String, pages: [NotePage], iconSymbol: String = NoteSection.defaultIcon) {
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
        // Sections used to default to a folder icon, which can no longer be picked; show the book instead.
        let stored = try container.decodeIfPresent(String.self, forKey: .iconSymbol)
        iconSymbol = (stored == nil || stored == "folder") ? NoteSection.defaultIcon : stored!
    }
}
