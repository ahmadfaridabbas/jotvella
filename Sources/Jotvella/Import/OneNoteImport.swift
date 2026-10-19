import Foundation

/// Decoded payload emitted by the bundled `jotvella-one-importer` helper for a
/// single OneNote `.one` section.
struct ImportedOneNoteSection: Decodable {
    var name: String
    var pages: [ImportedOneNotePage]
}

struct ImportedOneNotePage: Decodable {
    var title: String
    var body: String
    var blocks: [ImportedOneNoteBlock]?
    var images: [ImportedOneNoteImage]
}

struct ImportedOneNoteBlock: Decodable {
    var text: String?
    var table: [[String]]?
}

struct ImportedOneNoteImage: Decodable {
    var data: String
    var x: Double
    var y: Double
}

/// User-facing errors surfaced while importing a OneNote section.
enum OneNoteImportError: LocalizedError {
    case parserMissing
    case parserFailed(String)
    case noPages
    var errorDescription: String? {
        switch self {
        case .parserMissing: "The OneNote import component is missing from the app."
        case .parserFailed(let message): "Jotvella couldn't read this OneNote section. \(message)"
        case .noPages: "This OneNote section doesn't contain any pages."
        }
    }
}
