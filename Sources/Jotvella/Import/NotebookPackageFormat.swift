import Foundation

/// Legacy single-file notebook package manifest (first development format).
struct NotebookPackageManifest: Codable {
    var formatVersion: Int = 1
    var notebook: Notebook
}

/// Table of contents written at the root of a `.jotpkg` package. It records the
/// notebook identity, ordering, and the section files that make up the notebook.
struct NotebookPackageTOC: Codable {
    var formatVersion: Int = 1
    var notebookID: UUID
    var notebookName: String
    var sectionIDs: [UUID]
    var orderNum: Int = 0
    var isStarred: Bool = false

    private enum CodingKeys: String, CodingKey { case formatVersion, notebookID, notebookName, sectionIDs, orderNum, isStarred }
    init(notebookID: UUID, notebookName: String, sectionIDs: [UUID], orderNum: Int, isStarred: Bool = false) {
        self.notebookID = notebookID; self.notebookName = notebookName; self.sectionIDs = sectionIDs; self.orderNum = orderNum; self.isStarred = isStarred
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        notebookID = try c.decode(UUID.self, forKey: .notebookID)
        notebookName = try c.decode(String.self, forKey: .notebookName)
        sectionIDs = try c.decodeIfPresent([UUID].self, forKey: .sectionIDs) ?? []
        orderNum = try c.decodeIfPresent(Int.self, forKey: .orderNum) ?? 0
        isStarred = try c.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
    }
}
