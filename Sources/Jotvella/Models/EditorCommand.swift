import AppKit

/// A formatting command issued by the toolbar and applied by the rich-text editor
/// to a specific text block at a given selection.
struct EditorCommand: Equatable {
    var id = UUID()
    var kind: Kind
    var targetBlockID: UUID?
    var selection: NSRange
    enum Kind: Equatable {
        case bold, italic, underline
        case heading(Int), fontSize(Int), alignment(NSTextAlignment)
        case textColor(NSColor), highlightColor(NSColor), link(String), linePrefix(String)
    }
}
