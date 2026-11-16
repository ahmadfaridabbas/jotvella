import XCTest
import AppKit
import SwiftUI
@testable import Jotvella

final class ModelCompatibilityTests: XCTestCase {
    /// A page saved before tags and code blocks existed must still decode.
    func testOldPageJSONDecodes() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","title":"Old","body":"hello",
         "contentBlocks":[{"id":"22222222-2222-2222-2222-222222222222","text":"hello"}],
         "images":[],"tables":[],"modified":0}
        """
        let page = try JSONDecoder().decode(NotePage.self, from: Data(json.utf8))
        XCTAssertEqual(page.title, "Old")
        XCTAssertNil(page.tags)
        XCTAssertNil(page.contentBlocks.first?.isCode)
    }

    func testNewFieldsRoundTripAndStayOutOfOldPages() throws {
        var page = NotePage(title: "New", contentBlocks: [PageContentBlock(id: UUID(), text: "x", table: nil, richTextData: nil, isCode: true)], tags: ["a", "b"])
        var copy = try JSONDecoder().decode(NotePage.self, from: JSONEncoder().encode(page))
        XCTAssertEqual(copy.tags, ["a", "b"])
        XCTAssertEqual(copy.contentBlocks.first?.isCode, true)

        page.tags = nil
        page.contentBlocks[0].isCode = nil
        let text = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
        XCTAssertFalse(text.contains("tags"))
        XCTAssertFalse(text.contains("isCode"))
        copy = try JSONDecoder().decode(NotePage.self, from: Data(text.utf8))
        XCTAssertNil(copy.tags)
    }
}

final class HelperTests: XCTestCase {
    func testListMarkerParsing() {
        XCTAssertEqual(ListMarker.parse("• item")?.marker, "• ")
        XCTAssertEqual(ListMarker.parse("  ☐ todo")?.indent, 2)
        XCTAssertEqual(ListMarker.parse("☑ done")?.isChecklist, true)
        XCTAssertEqual(ListMarker.parse("12. twelve")?.number, 12)
        XCTAssertNil(ListMarker.parse("1.no space"))
        XCTAssertNil(ListMarker.parse("plain"))
    }

    func testContinuation() {
        XCTAssertEqual(ListMarker.continuation(of: ListMarker.parse("• a")!), "• ")
        XCTAssertEqual(ListMarker.continuation(of: ListMarker.parse("☑ a")!), "☐ ")
        XCTAssertEqual(ListMarker.continuation(of: ListMarker.parse("  9. a")!), "  10. ")
    }

    func testMarkdownShortcuts() {
        XCTAssertEqual(MarkdownShortcut.kind(forLineBeforeSpace: "#"), .heading(1))
        XCTAssertEqual(MarkdownShortcut.kind(forLineBeforeSpace: "###"), .heading(3))
        XCTAssertNil(MarkdownShortcut.kind(forLineBeforeSpace: "#######"))
        XCTAssertEqual(MarkdownShortcut.kind(forLineBeforeSpace: "-"), .linePrefix("• "))
        XCTAssertEqual(MarkdownShortcut.kind(forLineBeforeSpace: "3."), .linePrefix("1. "))
        XCTAssertEqual(MarkdownShortcut.kind(forLineBeforeSpace: "[]"), .linePrefix("☐ "))
        XCTAssertNil(MarkdownShortcut.kind(forLineBeforeSpace: "word"))
        XCTAssertNil(MarkdownShortcut.kind(forLineBeforeSpace: "a-"))
    }

    func testFindMatches() {
        XCTAssertEqual(FindMatches.ranges(in: "Foo foo FOO", query: "foo").count, 3)
        XCTAssertEqual(FindMatches.ranges(in: "aaaa", query: "aa").count, 2)
        XCTAssertTrue(FindMatches.ranges(in: "abc", query: "").isEmpty)
    }

    func testTableClipboard() {
        XCTAssertEqual(TableClipboard.parse("a\tb\r\nc\td\n"), [["a", "b"], ["c", "d"]])
        let result = TableClipboard.apply([["x", "y"], ["z", "w"]], to: [["", ""], ["", ""]], row: 1, column: 1)
        XCTAssertEqual(result, [["", "", ""], ["", "x", "y"], ["", "z", "w"]])
    }

    func testTagText() {
        XCTAssertEqual(TagText.normalized("  #Hello World "), "Hello-World")
        XCTAssertEqual(TagText.normalized("###"), "")
    }
}

@MainActor
final class TextViewBehaviorTests: XCTestCase {
    private func makeView(_ text: String, caretAt caret: Int? = nil) -> JotvellaTextView {
        let view = JotvellaTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.isRichText = true
        view.string = text
        view.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        return view
    }

    func testEnterContinuesBulletList() {
        let view = makeView("• one")
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "• one\n• ")
    }

    func testEnterContinuesNumbers() {
        let view = makeView("1. one")
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "1. one\n2. ")
    }

    func testEnterOnEmptyItemEndsList() {
        let view = makeView("• one\n• ")
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "• one\n")
    }

    func testEnterOnPlainTextIsUnchanged() {
        let view = makeView("hello")
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "hello\n")
    }

    func testTabIndentsAndBacktabOutdentsListItem() {
        let view = makeView("• one")
        view.insertTab(nil)
        XCTAssertEqual(view.string, "  • one")
        XCTAssertEqual(view.selectedRange().location, 7)
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, "• one")
    }

    func testMarkdownShortcutRemovesTriggerAndFormats() {
        let view = makeView("#")
        var received: EditorCommand.Kind?
        view.onFormat = { received = $0 }
        view.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "")
        XCTAssertEqual(received, .heading(1))
    }

    func testSpaceAfterWordIsNotAShortcut() {
        let view = makeView("word")
        view.onFormat = { _ in XCTFail("should not trigger") }
        view.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "word ")
    }

    func testFenceThenEnterRequestsCodeBlock() {
        let view = makeView("```")
        var action: EditorBlockAction?
        view.onBlockAction = { action = $0 }
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "")
        XCTAssertEqual(action, .toggleCode)
    }

    func testDoubleBracketRequestsPageLink() {
        let view = makeView("see [")
        var action: EditorBlockAction?
        view.onBlockAction = { action = $0 }
        view.insertText("[", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "see ")
        XCTAssertEqual(action, .linkPage)
    }

    func testShortcutsAreOffInCodeBlocks() {
        let view = makeView("#")
        view.isCodeBlock = true
        view.onFormat = { _ in XCTFail("should not trigger") }
        view.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "# ")
    }
}

@MainActor
final class FormattingCommandTests: XCTestCase {
    private func makeEditor(_ text: String, selection: NSRange) -> (JotvellaTextView, RichTextEditor.Coordinator) {
        let editor = RichTextEditor(text: .constant(text), richData: .constant(nil), command: nil, focusRequest: nil, blockID: UUID(),
                                    onSelection: { _, _ in }, onPasteImage: { _ in false }, onDeleteSelectedImage: { false })
        let coordinator = RichTextEditor.Coordinator(editor)
        let view = JotvellaTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.isRichText = true
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15)]))
        view.setSelectedRange(selection)
        return (view, coordinator)
    }

    func testStrikethroughTogglesOnSelection() {
        let (view, coordinator) = makeEditor("hello", selection: NSRange(location: 0, length: 5))
        coordinator.apply(.strikethrough, to: view)
        XCTAssertEqual((view.textStorage?.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int), NSUnderlineStyle.single.rawValue)
        coordinator.apply(.strikethrough, to: view)
        XCTAssertEqual((view.textStorage?.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int) ?? 0, 0)
    }

    func testInlineCodeAndClearFormatting() {
        let (view, coordinator) = makeEditor("hello", selection: NSRange(location: 0, length: 5))
        coordinator.apply(.inlineCode, to: view)
        XCTAssertTrue((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isFixedPitch ?? false)
        coordinator.apply(.clearFormatting, to: view)
        XCTAssertFalse((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isFixedPitch ?? true)
        XCTAssertNil(view.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    func testChecklistPrefixToggleAndIndentedLines() {
        let (view, coordinator) = makeEditor("task", selection: NSRange(location: 0, length: 0))
        coordinator.apply(.linePrefix("☐ "), to: view)
        XCTAssertEqual(view.string, "☐ task")
        coordinator.apply(.linePrefix("☐ "), to: view)
        XCTAssertEqual(view.string, "task")

        let (indented, coordinator2) = makeEditor("  • item", selection: NSRange(location: 4, length: 0))
        coordinator2.apply(.linePrefix("1. "), to: indented)
        XCTAssertEqual(indented.string, "  1. item")
    }

    func testPageLinkInsertsLinkedTitle() {
        let (view, coordinator) = makeEditor("", selection: NSRange(location: 0, length: 0))
        let id = UUID()
        coordinator.apply(.pageLink(id, "Plans"), to: view)
        XCTAssertEqual(view.string, "Plans")
        XCTAssertEqual((view.textStorage?.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.absoluteString, "jotvella://page/\(id.uuidString)")
    }
}


final class TableEditingTests: XCTestCase {
    private func sample() -> PageTable {
        PageTable(cells: [["a", "b", "c"], ["d", "e", "f"]], columnWidths: [100, 110, 120], rowHeights: [40, 50])
    }

    func testInsertRowKeepsHeightsInStep() {
        let above = sample().insertingRow(at: 0)
        XCTAssertEqual(above.cells, [["", "", ""], ["a", "b", "c"], ["d", "e", "f"]])
        XCTAssertEqual(above.rowHeights, [42, 40, 50])
        XCTAssertEqual(sample().insertingRow(at: 99).cells.count, 3)
    }

    func testDeleteRowAndLastRowGuard() {
        let result = sample().deletingRow(at: 0)
        XCTAssertEqual(result?.cells, [["d", "e", "f"]])
        XCTAssertEqual(result?.rowHeights, [50])
        XCTAssertNil(result?.deletingRow(at: 0))
        XCTAssertNil(sample().deletingRow(at: 5))
    }

    func testInsertAndDeleteColumnKeepWidthsInStep() {
        let wider = sample().insertingColumn(at: 1)
        XCTAssertEqual(wider.cells, [["a", "", "b", "c"], ["d", "", "e", "f"]])
        XCTAssertEqual(wider.columnWidths?.count, 4)
        XCTAssertEqual(wider.columnWidths?[0], 100)
        let narrower = sample().deletingColumn(at: 1)
        XCTAssertEqual(narrower?.cells, [["a", "c"], ["d", "f"]])
        XCTAssertEqual(narrower?.columnWidths, [100, 120])
        XCTAssertNil(PageTable(cells: [["x"]]).deletingColumn(at: 0))
    }

    func testMoveAndDuplicate() {
        XCTAssertEqual(sample().movingRow(from: 0, by: 1).cells, [["d", "e", "f"], ["a", "b", "c"]])
        XCTAssertEqual(sample().movingRow(from: 0, by: 1).rowHeights, [50, 40])
        XCTAssertEqual(sample().movingRow(from: 0, by: -1).cells, sample().cells)
        XCTAssertEqual(sample().movingColumn(from: 0, by: 2).cells, [["c", "b", "a"], ["f", "e", "d"]])
        XCTAssertEqual(sample().movingColumn(from: 0, by: 2).columnWidths, [120, 110, 100])
        XCTAssertEqual(sample().duplicatingRow(at: 1).cells.last, ["d", "e", "f"])
        XCTAssertEqual(sample().duplicatingRow(at: 1).rowHeights, [40, 50, 50])
    }

    func testClearing() {
        XCTAssertEqual(sample().clearingRow(at: 0).cells[0], ["", "", ""])
        XCTAssertEqual(sample().clearingColumn(at: 1).cells, [["a", "", "c"], ["d", "", "f"]])
        XCTAssertEqual(sample().clearingCell(row: 1, column: 2).cells[1], ["d", "e", ""])
        XCTAssertTrue(sample().hasContent)
        XCTAssertFalse(PageTable(cells: [["", ""]]).hasContent)
    }

    func testSizeLimits() {
        var table = PageTable(cells: [Array(repeating: "", count: PageTable.maxColumns)])
        XCTAssertEqual(table.insertingColumn(at: 0).columns, PageTable.maxColumns)
        table = PageTable(cells: Array(repeating: [""], count: PageTable.maxRows))
        XCTAssertEqual(table.insertingRow(at: 0).rows, PageTable.maxRows)
    }

    func testReplacingCellsKeepsAndPadsSizes() {
        let grown = sample().replacingCells([["a", "b", "c", "x"], ["d", "e", "f", "y"], ["g", "h", "i", "z"]])
        XCTAssertEqual(grown.columnWidths?.prefix(3).map { $0 }, [100, 110, 120])
        XCTAssertEqual(grown.columnWidths?.count, 4)
        XCTAssertEqual(grown.rowHeights, [40, 50, 42])
    }

    func testHeaderFlagDefaultsOnAndRoundTrips() throws {
        var table = sample()
        XCTAssertTrue(table.showsHeaderRow)
        table.hasHeaderRow = false
        let copy = try JSONDecoder().decode(PageTable.self, from: JSONEncoder().encode(table))
        XCTAssertFalse(copy.showsHeaderRow)
        let old = try JSONDecoder().decode(PageTable.self, from: Data(#"{"id":"11111111-1111-1111-1111-111111111111","cells":[["a"]]}"#.utf8))
        XCTAssertTrue(old.showsHeaderRow)
    }
}


final class PageClipboardTests: XCTestCase {
    func testPageTextIncludesTextAndTables() {
        let table = PageTable(cells: [["a", "b"], ["c", "d"]])
        let page = NotePage(title: "T", contentBlocks: [.textBlock("hello"), .tableBlock(table), .textBlock("bye")])
        XCTAssertEqual(PageClipboard.attributedString(for: page).string, "hello\na\tb\nc\td\nbye")
        XCTAssertTrue(PageClipboard.hasContent(page))
    }

    func testLegacyPageAndEmptyPage() {
        XCTAssertEqual(PageClipboard.attributedString(for: NotePage(title: "T", body: "old body")).string, "old body")
        XCTAssertFalse(PageClipboard.hasContent(NotePage(title: "T")))
        XCTAssertTrue(PageClipboard.hasContent(NotePage(title: "T", images: [PageImage(filename: "x.png", x: 0, y: 0, width: 100)])))
    }
}


@MainActor
final class BlockScrollTests: XCTestCase {
    func testBlockNeverScrollsAwayFromItsFirstLine() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        scroll.contentView = TopPinnedClipView()
        let view = JotvellaTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.documentView = view
        view.contentView_scrollTest()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        XCTAssertEqual(scroll.contentView.bounds.origin, .zero)
    }
}

private extension NSView {
    func contentView_scrollTest() { layoutSubtreeIfNeeded() }
}


@MainActor
final class BlockAppearanceTests: XCTestCase {
    func testClipViewIsTransparent() {
        XCTAssertFalse(TopPinnedClipView().drawsBackground)
        XCTAssertFalse(TopPinnedClipView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)).drawsBackground)
    }

    func testBackspaceInEmptyBlockRequestsRemoval() {
        let view = JotvellaTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 50))
        var action: EditorBlockAction?
        view.onBlockAction = { action = $0 }
        view.deleteBackward(nil)
        XCTAssertEqual(action, .removeBlock)

        action = nil
        view.string = "text"
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.deleteBackward(nil)
        XCTAssertNil(action)
    }
}


@MainActor
final class PageContentUndoTests: XCTestCase {
    func testClearAndUndoRestoresTextTablesAndPictureFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jotvella-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("JOTVELLA_DATA_DIRECTORY", dir.path, 1)
        defer { unsetenv("JOTVELLA_DATA_DIRECTORY") }

        let store = NotebookStore()
        store.addNotebook()
        let pageID = try XCTUnwrap(store.selectedPage)
        let table = PageTable(cells: [["a", "b"]])
        let blockID = UUID()
        store.updatePage { page in
            page.title = "Keep me"
            page.tags = ["x"]
            page.contentBlocks = [.textBlock("hello", id: blockID), .tableBlock(table)]
        }
        store.addImage(data: Data([1, 2, 3]), forPageID: pageID, at: CGPoint(x: 20, y: 200))
        let image = try XCTUnwrap(store.currentPage?.images.first)
        let imageURL = store.imageURL(image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))

        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        store.clearPageContent(pageID: pageID, keeping: blockID, undoManager: undo)
        undo.endUndoGrouping()

        var cleared = try XCTUnwrap(store.currentPage)
        XCTAssertEqual(cleared.contentBlocks.count, 1)
        XCTAssertEqual(cleared.contentBlocks.first?.text, "")
        XCTAssertTrue(cleared.images.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertEqual(cleared.title, "Keep me")
        XCTAssertEqual(cleared.tags, ["x"])

        undo.undo()
        var restored = try XCTUnwrap(store.currentPage)
        XCTAssertEqual(restored.contentBlocks.count, 2)
        XCTAssertEqual(restored.contentBlocks.first?.text, "hello")
        XCTAssertNotNil(restored.contentBlocks.last?.table)
        XCTAssertEqual(restored.images.count, 1)
        XCTAssertEqual(try Data(contentsOf: imageURL), Data([1, 2, 3]))

        undo.redo()
        cleared = try XCTUnwrap(store.currentPage)
        XCTAssertEqual(cleared.contentBlocks.count, 1)
        XCTAssertTrue(cleared.images.isEmpty)

        undo.undo()
        restored = try XCTUnwrap(store.currentPage)
        XCTAssertEqual(restored.images.count, 1)
    }
}
