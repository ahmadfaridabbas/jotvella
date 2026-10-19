import Foundation

/// A top-level notebook: a named, orderable collection of sections.
struct Notebook: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var sections: [NoteSection]
    var isStarred: Bool = false

    private enum CodingKeys: String, CodingKey { case id, name, sections, isStarred }
    init(id: UUID = UUID(), name: String, sections: [NoteSection], isStarred: Bool = false) {
        self.id = id; self.name = name; self.sections = sections; self.isStarred = isStarred
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        sections = try c.decodeIfPresent([NoteSection].self, forKey: .sections) ?? []
        isStarred = try c.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
    }
}
