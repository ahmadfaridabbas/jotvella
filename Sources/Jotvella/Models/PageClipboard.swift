import AppKit

/// Builds clipboard content for a whole page (used by Select All on Page, then Copy or Cut).
enum PageClipboard {
    /// The page's blocks in reading order, including pages saved before content blocks existed.
    static func blocks(of page: NotePage) -> [PageContentBlock] {
        if !page.contentBlocks.isEmpty { return page.contentBlocks }
        return [.textBlock(page.body, richTextData: page.richTextData)] + page.tables.map(PageContentBlock.tableBlock)
    }

    /// Text blocks keep their formatting. Tables become tab-separated rows, which paste
    /// into spreadsheets and into Jotvella tables.
    static func attributedString(for page: NotePage) -> NSAttributedString {
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor]
        let result = NSMutableAttributedString()
        for block in blocks(of: page) {
            let piece: NSAttributedString
            if let table = block.table {
                piece = NSAttributedString(string: table.cells.map { $0.joined(separator: "\t") }.joined(separator: "\n"), attributes: plain)
            } else if let data = block.richTextData,
                      let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                piece = rich
            } else {
                piece = NSAttributedString(string: block.text ?? "", attributes: plain)
            }
            guard piece.length > 0 else { continue }
            if result.length > 0, !result.string.hasSuffix("\n") { result.append(NSAttributedString(string: "\n", attributes: plain)) }
            result.append(piece)
        }
        return result
    }

    static func write(_ page: NotePage, images: [NSImage], to pasteboard: NSPasteboard = .general) {
        let text = attributedString(for: page)
        var items: [NSPasteboardWriting] = []
        if text.length > 0 { items.append(text) }
        items.append(contentsOf: images)
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    static func hasContent(_ page: NotePage) -> Bool {
        !page.images.isEmpty || blocks(of: page).contains { $0.table != nil || !($0.text ?? "").isEmpty }
    }
}
