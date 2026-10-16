import SwiftUI
import UniformTypeIdentifiers
import AppKit

@MainActor
private enum WindowLaunchCoordinator {
    static var openMainWindow: (() -> Void)?
}

@MainActor
private final class JotvellaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        DispatchQueue.main.async {
            if let window = sender.windows.first(where: { $0.canBecomeKey }) {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
            } else {
                WindowLaunchCoordinator.openMainWindow?()
            }
            sender.activate(ignoringOtherApps: true)
        }
        return false
    }
}

@main
struct JotvellaApp: App {
    @NSApplicationDelegateAdaptor(JotvellaAppDelegate.self) private var appDelegate
    @StateObject private var store = NotebookStore()
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup(id: "main") {
            JotvellaWindow()
                .environmentObject(store)
                .onAppear { applyAppearance(appearance) }
                .onChange(of: appearance) { newValue in
                    applyAppearance(newValue)
                }
                .onChange(of: scenePhase) { phase in
                    if phase != .active { store.saveNow() }
                }
                .frame(minWidth: 960, minHeight: 650)
        }
        .commands {
            CommandGroup(after: .windowList) {
                Button("Close Window") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: [.command])
            }
            CommandGroup(replacing: .newItem) {
                Button("New Page") { store.addPage() }
                    .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command])
                Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x", modifiers: [.command])
                Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c", modifiers: [.command])
                Button("Paste") {
                    // Let the focused editor handle paste so image insertion can use its caret.
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: [.command])
                Button("Select All") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                    .keyboardShortcut("a", modifiers: [.command])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { store.saveNow() }
                    .keyboardShortcut("s", modifiers: [.command])
            }
        }
    }

    private func applyAppearance(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

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
private struct ImportedOneNoteSection: Decodable {
    var name: String
    var pages: [ImportedOneNotePage]
}
private struct ImportedOneNotePage: Decodable {
    var title: String
    var body: String
    var blocks: [ImportedOneNoteBlock]?
    var images: [ImportedOneNoteImage]
}
private struct ImportedOneNoteBlock: Decodable {
    var text: String?
    var table: [[String]]?
}
private struct ImportedOneNoteImage: Decodable {
    var data: String
    var x: Double
    var y: Double
}
private enum OneNoteImportError: LocalizedError {
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
private struct NotebookPackageManifest: Codable {
    var formatVersion: Int = 1
    var notebook: Notebook
}
private struct NotebookPackageTOC: Codable {
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

private enum SectionIconPalette {
    static let tint = Color.white
}

private struct SectionIconPicker: View {
    let selectedSymbol: String
    let onSelect: (String) -> Void

    private let symbols = [
        "briefcase", "house", "building.2", "person.2", "graduationcap", "book.closed", "lightbulb", "wrench.and.screwdriver",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Section Icon")
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 5), count: 8), spacing: 5) {
                ForEach(symbols, id: \.self) { symbol in
                    Button {
                        onSelect(symbol)
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(SectionIconPalette.tint)
                            .frame(width: 34, height: 34)
                            .background(selectedSymbol == symbol ? SectionIconPalette.tint.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help(symbol.replacingOccurrences(of: ".", with: " "))
                    .accessibilityLabel("Select \(symbol.replacingOccurrences(of: ".", with: " ")) icon")
                }
            }
        }
        .padding(14)
        .frame(width: 326)
    }
}
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
struct PageImage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var filename: String
    var x: Double
    var y: Double
    var width: Double
}
struct PageTable: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var cells: [[String]]
    var columns: Int { cells.first?.count ?? 0 }
    var rows: Int { cells.count }
}
struct PageContentBlock: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var text: String?
    var table: PageTable?
    var richTextData: Data?
    static func textBlock(_ text: String, id: UUID = UUID(), richTextData: Data? = nil) -> Self { .init(id: id, text: text, table: nil, richTextData: richTextData) }
    static func tableBlock(_ table: PageTable) -> Self { .init(id: table.id, text: nil, table: table) }
}
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

@MainActor
final class NotebookStore: ObservableObject {
    @Published var notebooks: [Notebook] = [] { didSet { schedulePersist() } }
    @Published var selectedNotebook: UUID?
    @Published var selectedSection: UUID?
    @Published var selectedPage: UUID?
    @Published var query = ""
    private let root: URL
    private let persistenceQueue = DispatchQueue(label: "com.jotvella.notebooks.persistence", qos: .utility)
    private var pendingPersist: DispatchWorkItem?

    init() {
        let base = ProcessInfo.processInfo.environment["JOTVELLA_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jotvella", isDirectory: true)
        root = base
        try? FileManager.default.createDirectory(at: packagesRoot, withIntermediateDirectories: true)
        if let packaged = loadNotebookPackages(), !packaged.isEmpty {
            notebooks = Self.joiningAdjacentPlainTextBlocks(in: packaged)
            persist() // Upgrade older package metadata and retain explicit notebook order.
        } else if FileManager.default.fileExists(atPath: packagesRoot.appendingPathComponent(".empty-library").path) {
            notebooks = []
        } else if let data = try? Data(contentsOf: base.appendingPathComponent("notebooks.json")),
                  let decoded = try? JSONDecoder().decode([Notebook].self, from: data) {
            notebooks = Self.joiningAdjacentPlainTextBlocks(in: decoded)
            persist() // One-time migration; the legacy JSON remains as a backup.
        } else {
            let page = NotePage(title: "Jotvella — Product Vision", body: "A personal knowledge space should feel less like managing a system and more like returning to a familiar desk. Jotvella brings the reassurance of notebooks together with the freedom to shape a page as ideas take form.\n\nWhat we’re making\nA quiet place to collect, organize, write, and revisit the knowledge that matters to one person. The structure should be there when you need it, then recede while you think.\n\nProduct goals\n• Make capture immediate, and make returning to an idea feel effortless.\n• Give every thought a natural home: notebook, section, page, or a freeform space.\n• Keep writing comfortable across a quick note and a long-form session.\n\nPrinciples\nLocal-first by intention. Calm by default. Flexible without asking people to learn a new way to think.")
            notebooks = [Notebook(name: "Personal", sections: [NoteSection(name: "Journal", pages: []), NoteSection(name: "Reading", pages: []), NoteSection(name: "Ideas", pages: [])]), Notebook(name: "Software Projects", sections: [NoteSection(name: "Jotvella", pages: [page, NotePage(title: "UX Research"), NotePage(title: "Development Notes")]), NoteSection(name: "KegPilot", pages: [])]), Notebook(name: "Professional", sections: [])]
            selectedNotebook = notebooks[1].id
            selectedSection = notebooks[1].sections[0].id
            selectedPage = page.id
            persist()
        }
        if selectedNotebook == nil { selectFirstPage() }
    }

    private var packagesRoot: URL { root.appendingPathComponent("Notebooks", isDirectory: true) }
    /// OneNote exposes each paragraph as a separate block. Keep adjacent plain
    /// paragraphs in one editor so the editor's minimum block height does not
    /// create a large blank area between every paragraph.
    private static func joinAdjacentPlainTextBlocks(_ blocks: [PageContentBlock]) -> [PageContentBlock] {
        var result: [PageContentBlock] = []
        var pending: [PageContentBlock] = []

        func flushPending() {
            guard !pending.isEmpty else { return }
            if pending.count == 1 {
                result.append(pending[0])
            } else {
                result.append(.textBlock(pending.compactMap(\.text).joined(separator: "\n"), id: pending[0].id))
            }
            pending.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            if block.text != nil && block.richTextData == nil {
                pending.append(block)
            } else {
                flushPending()
                result.append(block)
            }
        }
        flushPending()
        return result
    }

    /// OneNote serializes each hyperlink as a hidden HYPERLINK field followed by
    /// its visible text. The parser's plain-text value includes that hidden
    /// field, so remove it before the text reaches the editor.
    private static func cleanOneNoteHyperlinkMarkers(_ source: String) -> String {
        var value = source
        let markers = ["\u{fffd}HYPERLINK \"", "HYPERLINK \""]
        for marker in markers {
            while let range = value.range(of: marker) {
                guard let closingQuote = value[range.upperBound...].firstIndex(of: "\"") else {
                    value.removeSubrange(range.lowerBound..<value.endIndex)
                    break
                }
                let prefixScalars = value.unicodeScalars[..<range.lowerBound]
                let start = prefixScalars.last?.value == 0xFDDf ? value.index(before: range.lowerBound) : range.lowerBound
                value.removeSubrange(start...closingQuote)
            }
        }
        return value
    }

    /// Repair pages imported by earlier builds when the notebook is loaded.
    private static func joiningAdjacentPlainTextBlocks(in notebooks: [Notebook]) -> [Notebook] {
        notebooks.map { original in
            var notebook = original
            notebook.sections = notebook.sections.map { originalSection in
                var section = originalSection
                section.pages = section.pages.map { originalPage in
                    var page = originalPage
                    page.body = cleanOneNoteHyperlinkMarkers(page.body)
                    guard !page.contentBlocks.isEmpty else { return page }
                    for index in page.contentBlocks.indices {
                        guard let text = page.contentBlocks[index].text else { continue }
                        let cleaned = cleanOneNoteHyperlinkMarkers(text)
                        if cleaned != text {
                            page.contentBlocks[index].text = cleaned
                            page.contentBlocks[index].richTextData = nil
                        }
                    }
                    page.contentBlocks = joinAdjacentPlainTextBlocks(page.contentBlocks)
                    page.body = page.contentBlocks.compactMap(\.text).joined()
                    return page
                }
                return section
            }
            return notebook
        }
    }

    private func packageURL(for notebookID: UUID) -> URL {
        packagesRoot.appendingPathComponent("\(notebookID.uuidString).jotpkg", isDirectory: true)
    }
    func openNotebookInFinder(_ notebookID: UUID) {
        saveNow()
        let package = packageURL(for: notebookID)
        let target = FileManager.default.fileExists(atPath: package.path) ? package : packagesRoot
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
    private func loadNotebookPackages() -> [Notebook]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: packagesRoot, includingPropertiesForKeys: nil),
              !urls.isEmpty else { return nil }
        let decoder = JSONDecoder()
        let notebooks = urls.filter { $0.pathExtension == "jotpkg" }.compactMap { packageURL -> (Notebook, Int)? in
            let tocURL = packageURL.appendingPathComponent("Notebook.jottoc")
            if let data = try? Data(contentsOf: tocURL),
               let toc = try? decoder.decode(NotebookPackageTOC.self, from: data),
               toc.formatVersion == 1 {
                let sections = toc.sectionIDs.compactMap { sectionID -> NoteSection? in
                    let sectionURL = packageURL.appendingPathComponent("Sections", isDirectory: true)
                        .appendingPathComponent("\(sectionID.uuidString).jotdoc")
                    guard let sectionData = try? Data(contentsOf: sectionURL) else { return nil }
                    return try? decoder.decode(NoteSection.self, from: sectionData)
                }
                return (Notebook(id: toc.notebookID, name: toc.notebookName, sections: sections, isStarred: toc.isStarred), toc.orderNum)
            }
            // Read the first package format written during development.
            let legacyURL = packageURL.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: legacyURL),
                  let manifest = try? decoder.decode(NotebookPackageManifest.self, from: data),
                  manifest.formatVersion == 1 else { return nil }
            return (manifest.notebook, 0)
        }
        guard !notebooks.isEmpty else { return nil }
        if notebooks.allSatisfy({ $0.1 == 0 }),
           let legacyData = try? Data(contentsOf: root.appendingPathComponent("notebooks.json")),
           let legacy = try? decoder.decode([Notebook].self, from: legacyData) {
            let legacyOrder = Dictionary(uniqueKeysWithValues: legacy.enumerated().map { ($0.element.id, $0.offset) })
            return notebooks.sorted { legacyOrder[$0.0.id, default: Int.max] < legacyOrder[$1.0.id, default: Int.max] }.map(\.0)
        }
        return notebooks.sorted { $0.1 < $1.1 }.map(\.0)
    }

    var currentPage: NotePage? {
        guard let n = currentNotebook, let s = n.sections.first(where: { $0.id == selectedSection }) ?? n.sections.first(where: { $0.pages.contains(where: { $0.id == selectedPage }) }) else { return nil }
        return s.pages.first(where: { $0.id == selectedPage })
    }
    var currentNotebook: Notebook? {
        if let selectedNotebook, let notebook = notebooks.first(where: { $0.id == selectedNotebook }) { return notebook }
        if let selectedSection, let notebook = notebooks.first(where: { $0.sections.contains(where: { $0.id == selectedSection }) }) { return notebook }
        if let selectedPage, let notebook = notebooks.first(where: { $0.sections.contains(where: { $0.pages.contains(where: { $0.id == selectedPage }) }) }) { return notebook }
        return nil
    }
    var currentSection: NoteSection? {
        guard let notebook = currentNotebook else { return nil }
        return notebook.sections.first(where: { $0.id == selectedSection }) ?? notebook.sections.first(where: { $0.pages.contains(where: { $0.id == selectedPage }) })
    }

    func selectFirstPage() {
        for notebook in notebooks {
            for section in notebook.sections {
                if let page = section.pages.first {
                    selectedNotebook = notebook.id; selectedSection = section.id; selectedPage = page.id
                    return
                }
            }
        }
        guard let notebook = notebooks.first else { return }
        selectedNotebook = notebook.id
        selectedSection = notebook.sections.first?.id
        selectedPage = nil
    }
    func select(_ page: NotePage, section: NoteSection, notebook: Notebook) {
        if selectedNotebook != nil && query.isEmpty { selectedNotebook = notebook.id } else { selectedNotebook = nil }
        selectedSection = section.id; selectedPage = page.id
    }
    func updatePage(_ change: (inout NotePage) -> Void) {
        guard let notebookID = currentNotebook?.id, let ni = notebooks.firstIndex(where: { $0.id == notebookID }), let si = notebooks[ni].sections.firstIndex(where: { $0.id == selectedSection }) ?? notebooks[ni].sections.firstIndex(where: { $0.pages.contains(where: { $0.id == selectedPage }) }), let pi = notebooks[ni].sections[si].pages.firstIndex(where: { $0.id == selectedPage }) else { return }
        change(&notebooks[ni].sections[si].pages[pi]); notebooks[ni].sections[si].pages[pi].modified = .now
    }
    func addNotebook() {
        let section = NoteSection(name: "General", pages: [])
        let notebook = Notebook(name: "New Notebook", sections: [section])
        notebooks.append(notebook); selectedNotebook = notebook.id; selectedSection = section.id; addPage()
    }
    func renameNotebook(_ id: UUID, to name: String) {
        guard let index = notebooks.firstIndex(where: { $0.id == id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        notebooks[index].name = trimmedName
    }
    func renameSection(_ sectionID: UUID, in notebookID: UUID, to name: String) {
        guard let notebookIndex = notebooks.firstIndex(where: { $0.id == notebookID }),
              let sectionIndex = notebooks[notebookIndex].sections.firstIndex(where: { $0.id == sectionID }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        notebooks[notebookIndex].sections[sectionIndex].name = trimmedName
    }
    func setSectionIcon(_ sectionID: UUID, in notebookID: UUID, to symbol: String) {
        guard let notebookIndex = notebooks.firstIndex(where: { $0.id == notebookID }),
              let sectionIndex = notebooks[notebookIndex].sections.firstIndex(where: { $0.id == sectionID }) else { return }
        notebooks[notebookIndex].sections[sectionIndex].iconSymbol = symbol
    }
    func moveSection(_ sectionID: UUID, in notebookID: UUID, relativeTo targetID: UUID) {
        guard let notebookIndex = notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
        guard let sourceIndex = notebooks[notebookIndex].sections.firstIndex(where: { $0.id == sectionID }),
              let targetIndex = notebooks[notebookIndex].sections.firstIndex(where: { $0.id == targetID }),
              sourceIndex != targetIndex else { return }
        let section = notebooks[notebookIndex].sections.remove(at: sourceIndex)
        let adjustedTargetIndex = notebooks[notebookIndex].sections.firstIndex(where: { $0.id == targetID }) ?? targetIndex
        let insertionIndex = sourceIndex < targetIndex ? adjustedTargetIndex + 1 : adjustedTargetIndex
        notebooks[notebookIndex].sections.insert(section, at: insertionIndex)
    }
    func toggleNotebookStar(_ id: UUID) {
        guard let index = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[index].isStarred.toggle()
    }
    func deleteNotebook(_ id: UUID) {
        guard let index = notebooks.firstIndex(where: { $0.id == id }) else { return }
        let notebook = notebooks[index]
        let selectionWasDeleted = selectedNotebook == id
            || notebook.sections.contains(where: { $0.id == selectedSection })
            || notebook.sections.contains(where: { $0.pages.contains(where: { $0.id == selectedPage }) })
        notebooks.remove(at: index)
        try? FileManager.default.removeItem(at: packageURL(for: id))
        if selectionWasDeleted {
            selectedNotebook = nil
            selectedSection = nil
            selectedPage = nil
            if !notebooks.isEmpty { selectFirstPage() }
        }
    }
    func deleteSection(_ sectionID: UUID, from notebookID: UUID) {
        guard let ni = notebooks.firstIndex(where: { $0.id == notebookID }),
              let si = notebooks[ni].sections.firstIndex(where: { $0.id == sectionID }) else { return }
        let section = notebooks[ni].sections[si]
        let selectedContentWasDeleted = selectedSection == sectionID
            || section.pages.contains(where: { $0.id == selectedPage })
        for image in section.pages.flatMap(\.images) {
            let url = packageURL(for: notebookID).appendingPathComponent("Resources", isDirectory: true).appendingPathComponent(image.filename)
            try? FileManager.default.removeItem(at: url)
        }
        notebooks[ni].sections.remove(at: si)
        if selectedContentWasDeleted {
            selectedNotebook = nil
            selectedSection = nil
            selectedPage = nil
            selectFirstPage()
        }
    }
    func deletePage(_ pageID: UUID, from sectionID: UUID, in notebookID: UUID) {
        guard let ni = notebooks.firstIndex(where: { $0.id == notebookID }),
              let si = notebooks[ni].sections.firstIndex(where: { $0.id == sectionID }),
              let pi = notebooks[ni].sections[si].pages.firstIndex(where: { $0.id == pageID }) else { return }
        let page = notebooks[ni].sections[si].pages[pi]
        for image in page.images {
            let url = packageURL(for: notebookID).appendingPathComponent("Resources", isDirectory: true).appendingPathComponent(image.filename)
            try? FileManager.default.removeItem(at: url)
        }
        notebooks[ni].sections[si].pages.remove(at: pi)
        if selectedPage == pageID {
            selectedNotebook = notebookID
            selectedSection = sectionID
            selectedPage = notebooks[ni].sections[si].pages.first?.id
        }
    }
    func importOneNoteSection(at sourceURL: URL) throws {
        guard let helperURL = Bundle.module.url(forResource: "jotvella-one-importer", withExtension: nil) else {
            throw OneNoteImportError.parserMissing
        }
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = helperURL
        process.arguments = [sourceURL.path]
        process.standardOutput = output
        process.standardError = errorOutput
        do { try process.run() } catch { throw OneNoteImportError.parserFailed(error.localizedDescription) }
        let json = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: diagnostic, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw OneNoteImportError.parserFailed(message.isEmpty ? "The file format was not recognized." : message)
        }
        let imported = try JSONDecoder().decode(ImportedOneNoteSection.self, from: json)
        guard !imported.pages.isEmpty else { throw OneNoteImportError.noPages }

        let existingNotebookIndex = notebooks.firstIndex(where: { $0.id == selectedNotebook })
        let notebookID = existingNotebookIndex.map { notebooks[$0].id } ?? UUID()
        let resources = packageURL(for: notebookID).appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let pages = imported.pages.map { importedPage -> NotePage in
            let pageID = UUID()
            var pageImages: [PageImage] = []
            for importedImage in importedPage.images {
                guard let bytes = Data(base64Encoded: importedImage.data),
                      let png = Self.pngData(from: bytes) else { continue }
                let filename = "\(pageID.uuidString)-\(UUID().uuidString).png"
                let destination = resources.appendingPathComponent(filename)
                guard (try? png.write(to: destination, options: .atomic)) != nil else { continue }
                pageImages.append(PageImage(filename: filename, x: max(18, importedImage.x), y: max(180, importedImage.y + 180), width: 260))
            }
            let body = Self.cleanOneNoteHyperlinkMarkers(importedPage.body).trimmingCharacters(in: .newlines)
            let parsedBlocks = (importedPage.blocks ?? []).compactMap { block -> PageContentBlock? in
                if let text = block.text { return .textBlock(Self.cleanOneNoteHyperlinkMarkers(text)) }
                guard let sourceRows = block.table, !sourceRows.isEmpty else { return nil }
                let columns = max(1, sourceRows.map(\.count).max() ?? 1)
                let cells = sourceRows.map { row in row + Array(repeating: "", count: max(0, columns - row.count)) }
                return .tableBlock(PageTable(cells: cells))
            }
            let contentBlocks = Self.joinAdjacentPlainTextBlocks(parsedBlocks)
            let finalBlocks = contentBlocks.isEmpty && !body.isEmpty ? [PageContentBlock.textBlock(body)] : contentBlocks
            return NotePage(id: pageID, title: importedPage.title.isEmpty ? "Untitled" : importedPage.title, body: body, images: pageImages, tables: finalBlocks.compactMap(\.table), contentBlocks: finalBlocks)
        }
        let section = NoteSection(name: imported.name.isEmpty ? sourceURL.deletingPathExtension().lastPathComponent : imported.name, pages: pages)
        if let existingNotebookIndex {
            notebooks[existingNotebookIndex].sections.insert(section, at: 0)
            selectedNotebook = notebooks[existingNotebookIndex].id
        } else {
            let notebook = Notebook(id: notebookID, name: imported.name.isEmpty ? "OneNote Import" : imported.name, sections: [section])
            notebooks.append(notebook)
            selectedNotebook = notebook.id
        }
        selectedSection = section.id
        selectedPage = pages.first?.id
    }
    func addSection() {
        if selectedNotebook == nil { selectedNotebook = currentNotebook?.id }
        guard let ni = notebooks.firstIndex(where: { $0.id == selectedNotebook }) else { return }
        let section = NoteSection(name: "New Section", pages: [])
        notebooks[ni].sections.append(section); selectedSection = section.id; selectedPage = nil
    }
    func addPage() {
        if selectedNotebook == nil { selectedNotebook = currentNotebook?.id }
        guard let ni = notebooks.firstIndex(where: { $0.id == selectedNotebook }) else { addNotebook(); return }
        if notebooks[ni].sections.isEmpty { let s = NoteSection(name: "General", pages: []); notebooks[ni].sections.append(s); selectedSection = s.id }
        guard let si = notebooks[ni].sections.firstIndex(where: { $0.id == selectedSection }) ?? notebooks[ni].sections.indices.first else { return }
        let page = NotePage(title: "Untitled", body: "")
        notebooks[ni].sections[si].pages.append(page); selectedSection = notebooks[ni].sections[si].id; selectedPage = page.id
    }
    func addImage(from url: URL, at point: CGPoint) {
        addImage(from: url, forPageID: selectedPage, at: point)
    }
    func addImage(from url: URL, forPageID pageID: UUID?, at point: CGPoint) {
        guard url.startAccessingSecurityScopedResource() || url.isFileURL else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        addImage(data: data, fileExtension: url.pathExtension.isEmpty ? "png" : url.pathExtension, forPageID: pageID, at: point)
    }
    func addImage(data: Data, fileExtension: String = "png", at point: CGPoint) {
        addImage(data: data, fileExtension: fileExtension, forPageID: selectedPage, at: point)
    }
    func addImage(data: Data, fileExtension: String = "png", forPageID pageID: UUID?, at point: CGPoint) {
        guard let pageID,
              let notebookIndex = notebooks.firstIndex(where: { notebook in notebook.sections.contains { section in section.pages.contains { $0.id == pageID } } }),
              let sectionIndex = notebooks[notebookIndex].sections.firstIndex(where: { $0.pages.contains { $0.id == pageID } }),
              let pageIndex = notebooks[notebookIndex].sections[sectionIndex].pages.firstIndex(where: { $0.id == pageID }) else { return }

        let name = "\(pageID.uuidString)-\(UUID().uuidString).\(fileExtension)"
        let resources = packageURL(for: notebooks[notebookIndex].id).appendingPathComponent("Resources", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)) != nil else { return }
        let dest = resources.appendingPathComponent(name)
        guard (try? data.write(to: dest)) != nil else { return }
        let image = PageImage(filename: name, x: max(18, point.x), y: max(180, point.y), width: 260)
        notebooks[notebookIndex].sections[sectionIndex].pages[pageIndex].images.append(image)
        notebooks[notebookIndex].sections[sectionIndex].pages[pageIndex].modified = .now
    }
    static func clipboardImageData() -> Data? {
        let pasteboard = NSPasteboard.general
        for type in pasteboard.types ?? [] where UTType(type.rawValue)?.conforms(to: .image) == true {
            if let data = pasteboard.data(forType: type), let png = pngData(from: data) { return png }
        }
        if let image = (pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first,
           let png = pngData(from: image) { return png }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let data = try? Data(contentsOf: url) {
            return pngData(from: data)
        }
        return nil
    }
    fileprivate static func pngData(from data: Data) -> Data? {
        if let bitmap = NSBitmapImageRep(data: data) { return bitmap.representation(using: .png, properties: [:]) }
        guard let image = NSImage(data: data) else { return nil }
        return pngData(from: image)
    }
    fileprivate static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
    func imageURL(_ image: PageImage) -> URL {
        for notebook in notebooks where notebook.sections.contains(where: { section in
            section.pages.contains(where: { image.filename.hasPrefix($0.id.uuidString + "-") })
        }) {
            let packagedImage = packageURL(for: notebook.id).appendingPathComponent("Resources", isDirectory: true).appendingPathComponent(image.filename)
            if FileManager.default.fileExists(atPath: packagedImage.path) { return packagedImage }
        }
        return root.appendingPathComponent("Images", isDirectory: true).appendingPathComponent(image.filename)
    }
    func moveImage(_ id: UUID, to point: CGPoint) {
        updatePage { page in if let i = page.images.firstIndex(where: { $0.id == id }) { page.images[i].x = max(0, point.x); page.images[i].y = max(180, point.y) } }
    }
    func deleteImage(_ imageID: UUID, fromPageID pageID: UUID) {
        guard let notebookIndex = notebooks.firstIndex(where: { $0.sections.contains { $0.pages.contains(where: { $0.id == pageID }) } }),
              let sectionIndex = notebooks[notebookIndex].sections.firstIndex(where: { $0.pages.contains(where: { $0.id == pageID }) }),
              let pageIndex = notebooks[notebookIndex].sections[sectionIndex].pages.firstIndex(where: { $0.id == pageID }),
              let imageIndex = notebooks[notebookIndex].sections[sectionIndex].pages[pageIndex].images.firstIndex(where: { $0.id == imageID }) else { return }
        let image = notebooks[notebookIndex].sections[sectionIndex].pages[pageIndex].images[imageIndex]
        let resourceURL = packageURL(for: notebooks[notebookIndex].id)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(image.filename)
        notebooks[notebookIndex].sections[sectionIndex].pages[pageIndex].images.remove(at: imageIndex)
        notebooks[notebookIndex].sections[sectionIndex].pages[pageIndex].modified = .now
        try? FileManager.default.removeItem(at: resourceURL)
    }
    func saveNow() {
        pendingPersist?.cancel()
        pendingPersist = nil
        let snapshot = notebooks
        let root = root
        persistenceQueue.sync { Self.persist(snapshot, root: root) }
    }

    private func schedulePersist() {
        pendingPersist?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.notebooks
            let root = self.root
            self.persistenceQueue.async {
                Self.persist(snapshot, root: root)
            }
        }
        pendingPersist = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(450), execute: work)
    }

    private func persist() {
        Self.persist(notebooks, root: root)
    }

    nonisolated private static func persist(_ notebooks: [Notebook], root: URL) {
        guard !root.path.isEmpty else { return }
        let manager = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let packagesRoot = root.appendingPathComponent("Notebooks", isDirectory: true)
        let emptyLibraryMarker = packagesRoot.appendingPathComponent(".empty-library")
        if notebooks.isEmpty {
            try? manager.createDirectory(at: packagesRoot, withIntermediateDirectories: true)
            try? Data().write(to: emptyLibraryMarker, options: .atomic)
            return
        }
        try? manager.removeItem(at: emptyLibraryMarker)
        for (orderNum, notebook) in notebooks.enumerated() {
            let package = packagesRoot.appendingPathComponent("\(notebook.id.uuidString).jotpkg", isDirectory: true)
            let resources = package.appendingPathComponent("Resources", isDirectory: true)
            let sectionsDirectory = package.appendingPathComponent("Sections", isDirectory: true)
            guard (try? manager.createDirectory(at: resources, withIntermediateDirectories: true)) != nil,
                  (try? manager.createDirectory(at: sectionsDirectory, withIntermediateDirectories: true)) != nil,
                  let tocData = try? encoder.encode(NotebookPackageTOC(notebookID: notebook.id, notebookName: notebook.name, sectionIDs: notebook.sections.map(\.id), orderNum: orderNum, isStarred: notebook.isStarred)) else { continue }

            for section in notebook.sections {
                guard let sectionData = try? encoder.encode(section) else { continue }
                try? sectionData.write(to: sectionsDirectory.appendingPathComponent("\(section.id.uuidString).jotdoc"), options: .atomic)
            }

            for image in notebook.sections.flatMap(\.pages).flatMap(\.images) {
                let destination = resources.appendingPathComponent(image.filename)
                let legacyImage = root.appendingPathComponent("Images", isDirectory: true).appendingPathComponent(image.filename)
                if !manager.fileExists(atPath: destination.path), manager.fileExists(atPath: legacyImage.path) {
                    try? manager.copyItem(at: legacyImage, to: destination)
                }
            }
            try? tocData.write(to: package.appendingPathComponent("Notebook.jottoc"), options: .atomic)

            // Remove section files and resource images no longer referenced by
            // the current model so deleted content does not accumulate on disk.
            // The TOC's sectionIDs remain the source of truth on load, so this
            // only reclaims storage and never changes what is read back.
            let liveSectionFiles = Set(notebook.sections.map { "\($0.id.uuidString).jotdoc" })
            pruneDirectory(sectionsDirectory, keeping: liveSectionFiles, manager: manager)
            let liveImageFiles = Set(notebook.sections.flatMap(\.pages).flatMap(\.images).map(\.filename))
            pruneDirectory(resources, keeping: liveImageFiles, manager: manager)
        }

        // Remove notebook packages for notebooks no longer in the library.
        let livePackages = Set(notebooks.map { "\($0.id.uuidString).jotpkg" })
        if let packageURLs = try? manager.contentsOfDirectory(at: packagesRoot, includingPropertiesForKeys: nil) {
            for url in packageURLs where url.pathExtension == "jotpkg" && !livePackages.contains(url.lastPathComponent) {
                try? manager.removeItem(at: url)
            }
        }
    }

    /// Delete every regular file in `directory` whose name is not in `keeping`.
    /// Used to reclaim storage from sections/images removed from the model.
    nonisolated private static func pruneDirectory(_ directory: URL, keeping: Set<String>, manager: FileManager) {
        guard let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in urls where !keeping.contains(url.lastPathComponent) {
            try? manager.removeItem(at: url)
        }
    }
}

private struct SectionSidebarRow: View {
    let section: NoteSection
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onSetIcon: (String) -> Void
    let onExportPDF: () -> Void
    let onDrag: () -> NSItemProvider
    let onDrop: ([NSItemProvider]) -> Bool

    @State private var isHovered = false
    @State private var isShowingIconPicker = false
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 22)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
                .help("Drag to reorder section")

            Button {
                isShowingIconPicker.toggle()
            } label: {
                Image(systemName: section.iconSymbol)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(SectionIconPalette.tint)
            }
            .buttonStyle(.plain)
            .help("Choose section icon")
            .popover(isPresented: $isShowingIconPicker) {
                SectionIconPicker(selectedSymbol: section.iconSymbol) { symbol in
                    onSetIcon(symbol)
                    isShowingIconPicker = false
                }
            }

            Button(action: onSelect) {
                Text(section.name)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onRename) {
                Image(systemName: "pencil")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Rename section")
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Delete section")
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .frame(maxWidth: .infinity, minHeight: 24)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .onHover { isHovered = $0 }
        .onDrag(onDrag)
        .onDrop(of: [UTType.utf8PlainText], isTargeted: $isDropTargeted) { providers in
            onDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(.leading, 34)
                    .padding(.trailing, 17)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            Button("Export Section to PDF…", systemImage: "doc.richtext", action: onExportPDF)
            Button("Delete Section", systemImage: "trash", role: .destructive, action: onDelete)
                .tint(.red)
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.13) : Color.clear)
                .padding(.leading, 34)
                .padding(.trailing, 17)
        )
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

private struct NotebookSidebarLabel: View {
    let notebook: Notebook
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggleStar: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onOpenInFinder: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                Label(notebook.name, systemImage: "books.vertical")
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tint(SectionIconPalette.tint)

            HStack(spacing: 2) {
                Button(action: onToggleStar) {
                    Image(systemName: notebook.isStarred ? "star.fill" : "star")
                        .foregroundStyle(notebook.isStarred ? Color.yellow : Color.secondary)
                        .frame(width: 22, height: 22)
                }
                .help(notebook.isStarred ? "Unstar notebook" : "Star notebook")
                Button(action: onRename) {
                    Image(systemName: "pencil").frame(width: 22, height: 22)
                }
                .help("Rename notebook")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").foregroundStyle(.red).frame(width: 22, height: 22)
                }
                .help("Delete notebook")
            }
            .buttonStyle(.borderless)
            .opacity(isHovered || notebook.isStarred ? 1 : 0)
            .allowsHitTesting(isHovered || notebook.isStarred)
        }
        .frame(maxWidth: .infinity, minHeight: 24)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(notebook.isStarred ? "Unstar Notebook" : "Star Notebook", systemImage: notebook.isStarred ? "star.slash" : "star", action: onToggleStar)
            Button("Open in Finder", systemImage: "folder", action: onOpenInFinder)
            Button("Rename Notebook", systemImage: "pencil", action: onRename)
            Button("Delete Notebook", systemImage: "trash", role: .destructive, action: onDelete)
                .tint(.red)
        }
    }
}

struct JotvellaWindow: View {
    private struct SectionRenameTarget {
        let notebookID: UUID
        let sectionID: UUID
    }

    private enum DeleteConfirmation {
        case notebook(Notebook)
        case section(Notebook, NoteSection)
        case page(Notebook, NoteSection, NotePage)

        var title: String {
            switch self {
            case .notebook: "Delete Notebook?"
            case .section: "Delete Section?"
            case .page: "Delete Page?"
            }
        }
        var message: String {
            switch self {
            case .notebook(let notebook): "\(notebook.name) and its pages will be permanently deleted from this Mac."
            case .section(let notebook, let section): "\(section.name) and its pages in \(notebook.name) will be permanently deleted from this Mac."
            case .page(let notebook, let section, let page): "\(page.title) in \(section.name) (\(notebook.name)) will be permanently deleted from this Mac."
            }
        }
    }

    @EnvironmentObject private var store: NotebookStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appearance") private var appearance = "system"
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingRecent = false
    @State private var importError: String?
    @State private var importAlertTitle = "OneNote Import Failed"
    @State private var deleteConfirmation: DeleteConfirmation?
    @State private var expandedNotebookIDs: Set<UUID> = []
    @State private var notebookToRename: UUID?
    @State private var sectionToRename: SectionRenameTarget?
    @State private var notebookRenameText = ""
    @State private var hoveredPageID: UUID?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 205, ideal: 245, max: 300)
        } content: {
            pageList
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
        } detail: {
            editor
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.addPage() } label: { Label("New Page", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: [.command])
                    .help("Create a new page")
                Menu {
                    Button("OneNote Folder (.one files)…", systemImage: "square.and.arrow.down", action: importOneNoteSection)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Import OneNote sections from a folder")
                Menu {
                    Button("System", systemImage: "circle.lefthalf.filled") { appearance = "system" }
                    Button("Light", systemImage: "sun.max") { appearance = "light" }
                    Button("Dark", systemImage: "moon") { appearance = "dark" }
                } label: {
                    Image(systemName: appearance == "light" ? "sun.max" : appearance == "dark" ? "moon" : "circle.lefthalf.filled")
                }
                .help("Appearance")
            }
        }
        .searchable(text: $store.query, placement: .toolbar, prompt: "Search notes")
        .alert(importAlertTitle, isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.white)
        .onAppear { WindowLaunchCoordinator.openMainWindow = { openWindow(id: "main") } }
    }

    private func importOneNoteSection() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.folder]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder containing OneNote .one files. Each file will be imported as a section."
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        let hasFolderAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if hasFolderAccess { folderURL.stopAccessingSecurityScopedResource() } }

        let oneNoteFiles: [URL]
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "one" }
            oneNoteFiles = files.sorted { lhs, rhs in
                let lhsValues = try? lhs.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let rhsValues = try? rhs.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let lhsDate = lhsValues?.creationDate ?? lhsValues?.contentModificationDate ?? .distantPast
                let rhsDate = rhsValues?.creationDate ?? rhsValues?.contentModificationDate ?? .distantPast
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
        } catch {
            importAlertTitle = "OneNote Import Failed"
            importError = "Could not read the selected folder. \(error.localizedDescription)"
            return
        }

        guard !oneNoteFiles.isEmpty else {
            importAlertTitle = "No OneNote Files Found"
            importError = "The selected folder does not contain any .one files."
            return
        }

        var importedCount = 0
        var failures: [String] = []
        for fileURL in oneNoteFiles {
            do {
                try store.importOneNoteSection(at: fileURL)
                importedCount += 1
            } catch {
                failures.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            importAlertTitle = "Import Complete"
            importError = "Imported \(importedCount) OneNote \(importedCount == 1 ? "section" : "sections") from \(folderURL.lastPathComponent)."
        } else {
            importAlertTitle = importedCount == 0 ? "OneNote Import Failed" : "Import Finished with Errors"
            let details = failures.prefix(5).joined(separator: "\n")
            let remaining = failures.count > 5 ? "\n…and \(failures.count - 5) more." : ""
            importError = "Imported \(importedCount) of \(oneNoteFiles.count) files.\n\n\(details)\(remaining)"
        }
    }

    private func expandSelectedLocation() {
        if let selectedNotebook = store.selectedNotebook {
            expandedNotebookIDs.insert(selectedNotebook)
        }
        guard let selectedSection = store.selectedSection else { return }
        if let notebook = store.notebooks.first(where: { $0.sections.contains(where: { $0.id == selectedSection }) }) {
            expandedNotebookIDs.insert(notebook.id)
        }
    }

    private func exportSectionToPDF(_ section: NoteSection, in notebook: Notebook) {
        let content = NSMutableAttributedString()
        content.append(NSAttributedString(string: "\(section.name)\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ]))

        for (index, page) in section.pages.enumerated() {
            if index > 0 { content.append(NSAttributedString(string: "\n\n")) }
            content.append(NSAttributedString(string: "\(page.title.isEmpty ? "Untitled" : page.title)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]))

            let blocks = page.contentBlocks.isEmpty
                ? [PageContentBlock.textBlock(page.body, richTextData: page.richTextData)] + page.tables.map(PageContentBlock.tableBlock)
                : page.contentBlocks
            for block in blocks {
                if let text = block.text {
                    if let data = block.richTextData,
                       let richText = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                        content.append(richText)
                    } else if !text.isEmpty {
                        content.append(NSAttributedString(string: text, attributes: [
                            .font: NSFont.systemFont(ofSize: 12),
                            .foregroundColor: NSColor.labelColor
                        ]))
                    }
                    content.append(NSAttributedString(string: "\n"))
                } else if let table = block.table {
                    let rows = table.cells.map { $0.joined(separator: "     |     ") }.joined(separator: "\n")
                    content.append(NSAttributedString(string: "\(rows)\n", attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.labelColor
                    ]))
                }
            }

            for image in page.images {
                guard let nsImage = NSImage(contentsOf: store.imageURL(image)) else { continue }
                let attachment = NSTextAttachment()
                attachment.image = nsImage
                let imageSize = nsImage.size
                let scale = min(1, 500 / max(imageSize.width, 1))
                attachment.bounds = NSRect(x: 0, y: 0, width: imageSize.width * scale, height: imageSize.height * scale)
                content.append(NSAttributedString(attachment: attachment))
                content.append(NSAttributedString(string: "\n"))
            }
        }

        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 612, height: 792)
        printInfo.leftMargin = 48
        printInfo.rightMargin = 48
        printInfo.topMargin = 48
        printInfo.bottomMargin = 48
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.jobDisposition = .save

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 516, height: 1))
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: 516, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = .zero
        textView.textContainer?.containerSize = NSSize(width: 516, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(content)
        if let textContainer = textView.textContainer, let layoutManager = textView.layoutManager {
            layoutManager.ensureLayout(for: textContainer)
            let contentHeight = max(696, layoutManager.usedRect(for: textContainer).height)
            textContainer.containerSize = NSSize(width: 516, height: contentHeight)
            textView.setFrameSize(NSSize(width: 516, height: contentHeight))
        }

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.jobTitle = "\(notebook.name) — \(section.name)"
        operation.showsPrintPanel = true
        operation.run()
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Jotvella").font(.system(.headline).weight(.bold))
                    Text("Personal library").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { store.addNotebook() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New notebook")
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Button {
                showingRecent = false
                store.selectedNotebook = nil
                store.selectedSection = nil
            } label: {
                Label("All Notes", systemImage: "tray.full")
                    .font(.system(.body).weight(store.selectedNotebook == nil && !showingRecent ? .semibold : .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tint(SectionIconPalette.tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(store.selectedNotebook == nil && !showingRecent ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 3)

            Button {
                showingRecent = true
                store.selectedNotebook = nil
                store.selectedSection = nil
            } label: {
                Label("Recently Edited", systemImage: "clock")
                    .font(.system(.body).weight(showingRecent ? .semibold : .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tint(SectionIconPalette.tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(showingRecent ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            List {
                Section {
                    ForEach(store.notebooks) { notebook in
                        DisclosureGroup(isExpanded: Binding(get: {
                            expandedNotebookIDs.contains(notebook.id)
                        }, set: { expanded in
                            if expanded { expandedNotebookIDs.insert(notebook.id) }
                            else { expandedNotebookIDs.remove(notebook.id) }
                        })) {
                            ForEach(notebook.sections) { section in
                                SectionSidebarRow(
                                    section: section,
                                    isSelected: store.selectedSection == section.id,
                                    onSelect: {
                                        showingRecent = false
                                        store.selectedNotebook = notebook.id
                                        store.selectedSection = section.id
                                        store.selectedPage = section.pages.first?.id
                                    },
                                    onRename: {
                                        notebookRenameText = section.name
                                        notebookToRename = nil
                                        sectionToRename = SectionRenameTarget(notebookID: notebook.id, sectionID: section.id)
                                    },
                                    onDelete: {
                                        deleteConfirmation = .section(notebook, section)
                                    },
                                    onSetIcon: { symbol in store.setSectionIcon(section.id, in: notebook.id, to: symbol) },
                                    onExportPDF: { exportSectionToPDF(section, in: notebook) },
                                    onDrag: {
                                        return NSItemProvider(object: section.id.uuidString as NSString)
                                    },
                                    onDrop: { providers in
                                        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
                                        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                                            guard let rawID = item as? String, let draggedSectionID = UUID(uuidString: rawID) else { return }
                                            DispatchQueue.main.async {
                                                store.moveSection(draggedSectionID, in: notebook.id, relativeTo: section.id)
                                            }
                                        }
                                        return true
                                    }
                                )
                            }
                            Button { store.selectedNotebook = notebook.id; store.addSection() } label: {
                                Label("New Section", systemImage: "plus")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        } label: {
                            NotebookSidebarLabel(
                                notebook: notebook,
                                isSelected: notebook.id == store.selectedNotebook,
                                onSelect: {
                                    showingRecent = false
                                    store.selectedNotebook = notebook.id
                                    store.selectedSection = notebook.sections.first?.id
                                    store.selectedPage = notebook.sections.first?.pages.first?.id
                                },
                                onToggleStar: { store.toggleNotebookStar(notebook.id) },
                                onRename: {
                                    notebookRenameText = notebook.name
                                    sectionToRename = nil
                                    notebookToRename = notebook.id
                                },
                                onDelete: {
                                    deleteConfirmation = .notebook(notebook)
                                },
                                onOpenInFinder: { store.openNotebookInFinder(notebook.id) }
                            )
                        }
                    }
                } header: {
                    HStack {
                        Text("NOTEBOOKS").tracking(1.1)
                        Spacer()
                    }
                    .font(.caption2.weight(.semibold))
                }
            }
            .listStyle(.sidebar)
            .onAppear(perform: expandSelectedLocation)
            .onChange(of: store.selectedNotebook) { _ in expandSelectedLocation() }
            .onChange(of: store.selectedSection) { _ in expandSelectedLocation() }
            .alert(deleteConfirmation?.title ?? "Delete?", isPresented: Binding(get: { deleteConfirmation != nil }, set: { if !$0 { deleteConfirmation = nil } })) {
                Button("Cancel", role: .cancel) { deleteConfirmation = nil }
                Button("Delete", role: .destructive) {
                    guard let target = deleteConfirmation else { return }
                    switch target {
                    case .notebook(let notebook):
                        store.deleteNotebook(notebook.id)
                        expandedNotebookIDs.remove(notebook.id)
                    case .section(let notebook, let section):
                        store.deleteSection(section.id, from: notebook.id)
                    case .page(let notebook, let section, let page):
                        store.deletePage(page.id, from: section.id, in: notebook.id)
                    }
                    deleteConfirmation = nil
                }
            } message: {
                Text(deleteConfirmation?.message ?? "This item will be permanently deleted from this Mac.")
            }

            HStack(spacing: 7) {
                Image(systemName: "externaldrive.fill").font(.caption2)
                Text("Stored on this Mac").font(.caption2)
                Spacer()
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 17)
            .padding(.vertical, 11)
            .overlay(alignment: .top) { Divider() }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .alert(sectionToRename == nil ? "Rename Notebook" : "Rename Section", isPresented: Binding(get: { notebookToRename != nil || sectionToRename != nil }, set: { if !$0 { notebookToRename = nil; sectionToRename = nil } })) {
            TextField(sectionToRename == nil ? "Notebook name" : "Section name", text: $notebookRenameText)
            Button("Cancel", role: .cancel) { notebookToRename = nil; sectionToRename = nil }
            Button("Save") {
                if let notebookToRename { store.renameNotebook(notebookToRename, to: notebookRenameText) }
                if let sectionToRename {
                    store.renameSection(sectionToRename.sectionID, in: sectionToRename.notebookID, to: notebookRenameText)
                }
                notebookToRename = nil
                sectionToRename = nil
            }
        } message: {
            Text(sectionToRename == nil ? "Choose a name for this notebook." : "Choose a name for this section.")
        }
    }

    private var pageList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(showingRecent || store.selectedNotebook == nil ? "YOUR LIBRARY" : (store.currentSection?.name.uppercased() ?? "YOUR LIBRARY"))
                    .font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(!store.query.isEmpty ? "Search Results" : showingRecent ? "Recently Edited" : store.selectedNotebook == nil ? "All Notes" : (store.currentNotebook?.name ?? "All Notes"))
                        .font(.system(.title2).weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 5)
                    Button { store.addPage() } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.borderless).help("New page")
                }
                Text("\(filteredPages.count) \(filteredPages.count == 1 ? "page" : "pages")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 15)
            .overlay(alignment: .bottom) { Divider() }

            if filteredPages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: store.query.isEmpty ? "doc.text" : "magnifyingglass")
                        .font(.system(size: 23, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .frame(width: 52, height: 52)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    Text(store.query.isEmpty ? "Nothing here yet" : "No matching notes")
                        .font(.system(.subheadline).weight(.semibold))
                    Text(store.query.isEmpty ? "Create a page to start collecting your ideas." : "Try another title or keyword.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 205)
                    if store.query.isEmpty {
                        Button("Create Page") { store.addPage() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(.top, 3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                List {
                    ForEach(filteredPages, id: \.page.id) { item in
                        let selected = store.selectedPage == item.page.id
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(SectionIconPalette.tint)
                                .frame(width: 22, height: 24)
                            Text(item.page.title)
                                .font(.system(.body))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Spacer(minLength: 5)
                            Button(role: .destructive) {
                                deleteConfirmation = .page(item.notebook, item.section, item.page)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                                    .frame(width: 20, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .help("Delete page")
                            .opacity(hoveredPageID == item.page.id ? 1 : 0)
                            .allowsHitTesting(hoveredPageID == item.page.id)
                        }
                        .padding(.leading, 5)
                        .padding(.trailing, 4)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                        .listRowBackground(Color.clear)
                        .background {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(selected ? Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06) : Color.clear)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .onTapGesture { store.select(item.page, section: item.section, notebook: item.notebook) }
                        .onHover { hovering in
                            hoveredPageID = hovering ? item.page.id : (hoveredPageID == item.page.id ? nil : hoveredPageID)
                        }
                        .contextMenu {
                            Button("Delete Page", systemImage: "trash", role: .destructive) {
                                deleteConfirmation = .page(item.notebook, item.section, item.page)
                            }
                            .tint(.red)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }

    private struct PageItem: Identifiable { var id: UUID { page.id }; let page: NotePage; let section: NoteSection; let notebook: Notebook }
    private var filteredPages: [PageItem] {
        let pages = store.notebooks.flatMap { n in n.sections.flatMap { s in s.pages.filter { page in
            (!store.query.isEmpty || store.selectedNotebook == nil || (n.id == store.selectedNotebook && (store.selectedSection == nil || s.id == store.selectedSection))) && matches(page, query: store.query)
        }.map { PageItem(page: $0, section: s, notebook: n) } } }
        return showingRecent ? pages.sorted { $0.page.modified > $1.page.modified } : pages
    }
    private func matches(_ page: NotePage, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let tableText = (page.tables + page.contentBlocks.compactMap(\.table)).flatMap(\.cells).flatMap { $0 }.joined(separator: " ")
        let blockText = page.contentBlocks.compactMap(\.text).joined(separator: " ")
        return [page.title, page.body, blockText, tableText].contains { $0.localizedStandardContains(query) }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "books.vertical").foregroundStyle(.tertiary)
                Text(store.currentNotebook?.name ?? "Notes").foregroundStyle(.secondary)
                if let section = store.currentSection {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(section.name).foregroundStyle(.secondary)
                }
                Spacer()
                Label("On My Mac", systemImage: "externaldrive")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22).frame(height: 42)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            if let page = store.currentPage {
                FreeformPage(page: page)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text("A clear page to begin")
                        .font(.system(.title2).weight(.bold))
                    Text("Choose a page from your library, or create one for a new idea.")
                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Create a Page") { store.addPage() }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct FreeformPage: View {
    @EnvironmentObject private var store: NotebookStore
    @FocusState private var pageTitleIsFocused: Bool
    let page: NotePage
    @State private var canvasSize: CGSize = .zero
    @State private var legacyBlockID = UUID()
    @State private var dragOrigin: [UUID: CGPoint] = [:]
    @State private var imageDragOffset: [UUID: CGPoint] = [:]
    @State private var loadedImages: [UUID: NSImage] = [:]
    @State private var editorCommand: EditorCommand?
    @State private var bodyFocusTargetID: UUID?
    @State private var bodyFocusRequestID: UUID?
    @State private var showInsertMenu = false
    @State private var tableSize = (rows: 0, columns: 0)
    @State private var selectedTextBlock: UUID?
    @State private var caretOffset = 0
    @State private var selectedLength = 0
    @State private var caretCanvasPoint: CGPoint?
    @State private var selectedImageID: UUID?
    @State private var showLinkPrompt = false
    @State private var linkAddress = "https://"

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                formattingToolbar
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.065), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.12), radius: 22, y: 8)
                        .frame(width: min(980, max(620, geometry.size.width - 76)), height: pageCardHeight)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, 22)
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 8) {
                            Label("Edited \(page.modified.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                            Text("·").foregroundStyle(.quaternary)
                            Text("\(wordCount) words")
                            Spacer()
                            Label("Private", systemImage: "lock.fill")
                        }
                .font(.caption).foregroundStyle(.secondary)
                        TextField("Untitled", text: Binding(get: { page.title }, set: { value in store.updatePage { $0.title = value } }))
                            .font(.system(size: 36, weight: .bold))
                            .textFieldStyle(.plain)
                            .padding(.bottom, 3)
                            .focused($pageTitleIsFocused)
                            .onSubmit {
                                pageTitleIsFocused = false
                                DispatchQueue.main.async { moveFocusToBody() }
                            }
                        ForEach(renderedBlocks) { block in
                            if let table = block.table {
                                EditableTable(table: table, onChange: { cells in updateTable(blockID: block.id, cells: cells) }, onDelete: { deleteTable(blockID: block.id) })
                            } else {
                                GeometryReader { blockGeometry in
                                    ZStack(alignment: .topLeading) {
                                RichTextEditor(text: blockTextBinding(block), richData: blockRichDataBinding(block), command: editorCommand, focusRequest: bodyFocusTargetID == block.id ? bodyFocusRequestID : nil, blockID: block.id, onSelection: { range, localCaret in
                                            selectedImageID = nil
                                            selectedTextBlock = block.id
                                            caretOffset = range.location
                                            selectedLength = range.length
                                            let origin = blockGeometry.frame(in: .named("pageCanvas")).origin
                                            caretCanvasPoint = CGPoint(x: origin.x + localCaret.x, y: origin.y + localCaret.y)
                                        }, onPasteImage: { localCaret in
                                            selectedImageID = nil
                                            selectedTextBlock = block.id
                                            let origin = blockGeometry.frame(in: .named("pageCanvas")).origin
                                            let canvasCaret = CGPoint(x: origin.x + localCaret.x, y: origin.y + localCaret.y)
                                            caretCanvasPoint = canvasCaret
                                            return pasteClipboardImage(at: canvasCaret)
                                        }, onDeleteSelectedImage: deleteSelectedImage)
                                        if isBlankPage && block.text?.isEmpty == true {
                                            Text("Start writing here…  Add a table or drop in an image whenever you’re ready.")
                                                .font(.system(size: 15))
                                                .foregroundStyle(.tertiary)
                                                .padding(.leading, 5)
                                                .padding(.top, 6)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                }
                                .frame(width: max(480, min(920, geometry.size.width - 110)), height: textBlockHeight(block, availableWidth: geometry.size.width), alignment: .topLeading)
                                .onTapGesture { selectedTextBlock = block.id }
                            }
                        }
                    }
                    .frame(width: max(540, min(940, geometry.size.width - 100)), alignment: .leading)
                    .padding(.top, 62)
                    // Keep this stack at its intrinsic content height. Without this,
                    // the scroll view's tall viewport is reported as page content and
                    // the paper background grows to fill the unused space.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .zIndex(0)
                    ForEach(page.images) { image in
                        if let nsImage = loadedImages[image.id] ?? NSImage(contentsOf: store.imageURL(image)) {
                            Image(nsImage: nsImage).resizable().scaledToFit().frame(width: image.width)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selectedImageID == image.id ? Color.white : .clear, lineWidth: 2))
                                .overlay(alignment: .topTrailing) {
                                    if selectedImageID == image.id {
                                        Button { deleteImage(image.id) } label: {
                                            Image(systemName: "trash.fill")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(.red)
                                                .frame(width: 28, height: 28)
                                                .background(Color.red.opacity(0.14), in: Circle())
                                                .shadow(radius: 4)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Delete image")
                                        .offset(x: 10, y: -10)
                                    }
                                }
                                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedImageID = image.id }
                                .contextMenu {
                                    Button("Delete Image", role: .destructive) { deleteImage(image.id) }
                                        .tint(.red)
                                }
                                .simultaneousGesture(imageDragGesture(for: image))
                                .position(imagePosition(for: image))
                                .onAppear { loadedImages[image.id] = nsImage }
                        }
                    }
                }
                .coordinateSpace(name: "pageCanvas")
                .id("page-top")
                .frame(minWidth: max(700, geometry.size.width), minHeight: pageCanvasHeight(viewportHeight: geometry.size.height), alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .onDrop(of: [.fileURL], delegate: ImageDropDelegate { url, point in store.addImage(from: url, forPageID: page.id, at: CGPoint(x: point.x - 130, y: point.y - 90)) })
            }
                    .onAppear {
                        DispatchQueue.main.async {
                            proxy.scrollTo("page-top", anchor: .top)
                        }
                    }
                }
                .onAppear { canvasSize = geometry.size }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDeleteCommand { _ = deleteSelectedImage() }
        .onChange(of: page.id) { _ in
            selectedImageID = nil
            loadedImages.removeAll()
            legacyBlockID = UUID()
            selectedTextBlock = nil
            caretOffset = 0
            selectedLength = 0
            caretCanvasPoint = nil
            editorCommand = nil
            bodyFocusTargetID = nil
            bodyFocusRequestID = nil
        }
        .onPasteCommand(of: [.image]) { providers in
            guard let provider = providers.first else { return }
            let imageTypes = provider.registeredTypeIdentifiers.filter {
                UTType($0)?.conforms(to: .image) == true
            }
            loadImageData(from: provider, types: imageTypes) { data in
                guard let data else { return }
                Task { @MainActor in store.addImage(data: data, forPageID: page.id, at: insertionPoint()) }
            }
        }
    }

    private var formattingToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Menu {
                    Button("Normal") { issueEditorCommand(.heading(0)) }
                    Button("Heading 1") { issueEditorCommand(.heading(1)) }
                    Button("Heading 2") { issueEditorCommand(.heading(2)) }
                    Button("Heading 3") { issueEditorCommand(.heading(3)) }
                    Button("Heading 4") { issueEditorCommand(.heading(4)) }
                    Button("Heading 5") { issueEditorCommand(.heading(5)) }
                    Button("Heading 6") { issueEditorCommand(.heading(6)) }
                    Divider()
                    Button("Page Title") { issueEditorCommand(.heading(101)) }
                    Button("Citation") { issueEditorCommand(.heading(102)) }
                    Button("Quote") { issueEditorCommand(.heading(103)) }
                    Button("Code") { issueEditorCommand(.heading(104)) }
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(Color.primary.opacity(0.52)).frame(width: 7, height: 7)
                        Text("Normal").font(.system(size: 14, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 10).frame(height: 34)
                }
                .help("Paragraph style")
                .frame(width: 150, alignment: .leading)

                toolbarDivider
                toolbarIconButton("B", help: "Bold (⌘B)", font: .system(size: 15, weight: .bold)) { issueEditorCommand(.bold) }
                    .keyboardShortcut("b", modifiers: [.command])
                toolbarIconButton("I", help: "Italic (⌘I)", font: .system(size: 15).italic()) { issueEditorCommand(.italic) }
                    .keyboardShortcut("i", modifiers: [.command])
                toolbarIconButton("U̲", help: "Underline (⌘U)", font: .system(size: 15, weight: .medium)) { issueEditorCommand(.underline) }
                    .keyboardShortcut("u", modifiers: [.command])

                toolbarDivider
                Menu {
                    ForEach([9, 10, 11, 12, 14, 16, 18, 22, 28, 36], id: \.self) { size in
                        Button("\(size) pt") { issueEditorCommand(.fontSize(size)) }
                    }
                } label: {
                    HStack(spacing: 5) { Text("11"); Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                        .frame(width: 58, height: 34)
                }
                .help("Font size")

                toolbarDivider
                Menu {
                    colorChoice("Default", color: .labelColor)
                    colorChoice("Black", color: .black)
                    colorChoice("Blue", color: .systemBlue)
                    colorChoice("Red", color: .systemRed)
                    colorChoice("Purple", color: .systemPurple)
                    colorChoice("Green", color: .systemGreen)
                } label: { Text("A̲").font(.system(size: 17, weight: .medium)).frame(width: 42, height: 34) }
                    .help("Text color")

                Menu {
                    colorChoice("Yellow", color: .systemYellow, highlight: true)
                    colorChoice("Green", color: .systemGreen, highlight: true)
                    colorChoice("Blue", color: .systemBlue, highlight: true)
                    colorChoice("Pink", color: .systemPink, highlight: true)
                    Button("Remove Highlight") { issueEditorCommand(.highlightColor(.clear)) }
                } label: {
                    Text("A").font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 34, height: 30).background(Color(red: 0.62, green: 0.49, blue: 0.08), in: RoundedRectangle(cornerRadius: 3))
                        .frame(width: 42, height: 34)
                }
                .help("Text highlight")

                toolbarDivider
                toolbarIconButton("link", help: "Insert link (⌘K)") {
                    linkAddress = "https://"
                    showLinkPrompt = true
                }
                .keyboardShortcut("k", modifiers: [.command])

                toolbarDivider
                toolbarIconButton("text.alignleft", help: "Align left") { issueEditorCommand(.alignment(.left)) }
                toolbarIconButton("text.aligncenter", help: "Center") { issueEditorCommand(.alignment(.center)) }
                toolbarIconButton("text.alignright", help: "Align right") { issueEditorCommand(.alignment(.right)) }

                toolbarDivider
                toolbarIconButton("list.bullet", help: "Bulleted list") { issueEditorCommand(.linePrefix("• ")) }
                toolbarIconButton("list.number", help: "Numbered list") { issueEditorCommand(.linePrefix("1. ")) }

                Button { _ = pasteClipboardImage() } label: { Image(systemName: "document.on.clipboard") }
                    .buttonStyle(.plain).frame(width: 30, height: 34).help("Paste image from clipboard")
                Menu {
                    Button { showInsertMenu.toggle() } label: { Label("Table", systemImage: "tablecells") }
                    Button { chooseImage() } label: { Label("Picture…", systemImage: "photo") }
                    Button { _ = pasteClipboardImage() } label: { Label("Paste Image", systemImage: "document.on.clipboard") }
                } label: { Label("Insert", systemImage: "plus") }
                    .help("Insert content")
                    .padding(.horizontal, 8)
                    .popover(isPresented: $showInsertMenu, arrowEdge: .bottom) { tablePicker.padding(12) }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 5)
            .fixedSize(horizontal: true, vertical: false)

            compactFormattingControls
            ultraCompactFormattingControls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: 44)
        .padding(.horizontal, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .background {
            Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                .padding(.horizontal, 14).padding(.vertical, 4)
        }
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                .padding(.horizontal, 14).padding(.vertical, 4)
                .allowsHitTesting(false)
        }
        .alert("Insert Link", isPresented: $showLinkPrompt) {
            TextField("https://example.com", text: $linkAddress)
            Button("Insert") {
                let value = linkAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { issueEditorCommand(.link(value)) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Select text to attach the link, or insert at the cursor.") }
    }

    private var compactFormattingControls: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Normal") { issueEditorCommand(.heading(0)) }
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { issueEditorCommand(.heading(level)) }
                }
                Divider()
                Button("Page Title") { issueEditorCommand(.heading(101)) }
                Button("Citation") { issueEditorCommand(.heading(102)) }
                Button("Quote") { issueEditorCommand(.heading(103)) }
                Button("Code") { issueEditorCommand(.heading(104)) }
            } label: {
                HStack(spacing: 5) { Circle().fill(.secondary).frame(width: 6, height: 6); Text("Normal"); Image(systemName: "chevron.down").font(.caption2) }
                    .font(.system(size: 13, weight: .medium)).frame(height: 32).padding(.horizontal, 7)
            }
            .help("Paragraph style")

            HStack(spacing: 0) {
                toolbarIconButton("B", help: "Bold (⌘B)", font: .system(size: 14, weight: .bold)) { issueEditorCommand(.bold) }
                    .keyboardShortcut("b", modifiers: [.command])
                toolbarIconButton("I", help: "Italic (⌘I)", font: .system(size: 14).italic()) { issueEditorCommand(.italic) }
                    .keyboardShortcut("i", modifiers: [.command])
                toolbarIconButton("U̲", help: "Underline (⌘U)", font: .system(size: 14)) { issueEditorCommand(.underline) }
                    .keyboardShortcut("u", modifiers: [.command])
            }
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Menu {
                ForEach([9, 10, 11, 12, 14, 16, 18, 22, 28, 36], id: \.self) { size in
                    Button("\(size) pt") { issueEditorCommand(.fontSize(size)) }
                }
            } label: { HStack(spacing: 3) { Text("11"); Image(systemName: "chevron.down").font(.caption2) }.frame(width: 45, height: 32) }
                .help("Font size")

            Menu {
                Section("Text color") {
                    colorChoice("Default", color: .labelColor)
                    colorChoice("Black", color: .black)
                    colorChoice("Blue", color: .systemBlue)
                    colorChoice("Red", color: .systemRed)
                    colorChoice("Purple", color: .systemPurple)
                }
                Section("Highlight") {
                    colorChoice("Yellow", color: .systemYellow, highlight: true)
                    colorChoice("Green", color: .systemGreen, highlight: true)
                    colorChoice("Blue", color: .systemBlue, highlight: true)
                    Button("Remove Highlight") { issueEditorCommand(.highlightColor(.clear)) }
                }
            } label: { Text("A̲").font(.system(size: 16, weight: .medium)).frame(width: 32, height: 32) }
                .help("Text color and highlight")

            toolbarIconButton("link", help: "Insert link (⌘K)") { linkAddress = "https://"; showLinkPrompt = true }
                .keyboardShortcut("k", modifiers: [.command])

            Menu {
                Button("Align left", systemImage: "text.alignleft") { issueEditorCommand(.alignment(.left)) }
                Button("Center", systemImage: "text.aligncenter") { issueEditorCommand(.alignment(.center)) }
                Button("Align right", systemImage: "text.alignright") { issueEditorCommand(.alignment(.right)) }
            } label: { Image(systemName: "text.alignleft").frame(width: 30, height: 32) }.help("Text alignment")

            Menu {
                Button("Bulleted list", systemImage: "list.bullet") { issueEditorCommand(.linePrefix("• ")) }
                Button("Numbered list", systemImage: "list.number") { issueEditorCommand(.linePrefix("1. ")) }
            } label: { Image(systemName: "list.bullet").frame(width: 30, height: 32) }.help("Lists")

            Button { _ = pasteClipboardImage() } label: { Image(systemName: "document.on.clipboard") }
                .buttonStyle(.plain).frame(width: 30, height: 32).help("Paste image from clipboard")
            insertMenu(compact: true)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var ultraCompactFormattingControls: some View {
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                toolbarIconButton("B", help: "Bold (⌘B)", font: .system(size: 14, weight: .bold)) { issueEditorCommand(.bold) }
                    .keyboardShortcut("b", modifiers: [.command])
                toolbarIconButton("I", help: "Italic (⌘I)", font: .system(size: 14).italic()) { issueEditorCommand(.italic) }
                    .keyboardShortcut("i", modifiers: [.command])
                toolbarIconButton("U̲", help: "Underline (⌘U)", font: .system(size: 14)) { issueEditorCommand(.underline) }
                    .keyboardShortcut("u", modifiers: [.command])
            }
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Menu {
                Button("Normal") { issueEditorCommand(.heading(0)) }
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { issueEditorCommand(.heading(level)) }
                }
                Divider()
                Button("Page Title") { issueEditorCommand(.heading(101)) }
                Button("Citation") { issueEditorCommand(.heading(102)) }
                Button("Quote") { issueEditorCommand(.heading(103)) }
                Button("Code") { issueEditorCommand(.heading(104)) }
                Divider()
                ForEach([9, 10, 11, 12, 14, 16, 18, 22, 28, 36], id: \.self) { size in
                    Button("\(size) pt") { issueEditorCommand(.fontSize(size)) }
                }
                Divider()
                Section("Text color") {
                    colorChoice("Default", color: .labelColor)
                    colorChoice("Blue", color: .systemBlue)
                    colorChoice("Red", color: .systemRed)
                    colorChoice("Purple", color: .systemPurple)
                }
                Section("Highlight") {
                    colorChoice("Yellow", color: .systemYellow, highlight: true)
                    colorChoice("Green", color: .systemGreen, highlight: true)
                    Button("Remove Highlight") { issueEditorCommand(.highlightColor(.clear)) }
                }
                Divider()
                Button("Insert link…", systemImage: "link") { linkAddress = "https://"; showLinkPrompt = true }
                Button("Align left", systemImage: "text.alignleft") { issueEditorCommand(.alignment(.left)) }
                Button("Center", systemImage: "text.aligncenter") { issueEditorCommand(.alignment(.center)) }
                Button("Align right", systemImage: "text.alignright") { issueEditorCommand(.alignment(.right)) }
                Button("Bulleted list", systemImage: "list.bullet") { issueEditorCommand(.linePrefix("• ")) }
                Button("Numbered list", systemImage: "list.number") { issueEditorCommand(.linePrefix("1. ")) }
            } label: { Label("Format", systemImage: "textformat").labelStyle(.iconOnly).frame(width: 34, height: 32) }
                .help("More formatting")

            Button { _ = pasteClipboardImage() } label: { Image(systemName: "document.on.clipboard") }
                .buttonStyle(.plain).frame(width: 30, height: 32).help("Paste image from clipboard")
            insertMenu(compact: true)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func insertMenu(compact: Bool) -> some View {
        Menu {
            Button { showInsertMenu.toggle() } label: { Label("Table", systemImage: "tablecells") }
            Button { chooseImage() } label: { Label("Picture…", systemImage: "photo") }
            Button { _ = pasteClipboardImage() } label: { Label("Paste Image", systemImage: "document.on.clipboard") }
        } label: {
            if compact { Image(systemName: "plus").frame(width: 34, height: 32) }
            else { Label("Insert", systemImage: "plus").padding(.horizontal, 8) }
        }
        .help("Insert content")
        .popover(isPresented: $showInsertMenu, arrowEdge: .bottom) { tablePicker.padding(12) }
    }

    private func issueEditorCommand(_ kind: EditorCommand.Kind) {
        guard let selectedTextBlock else { return }
        editorCommand = EditorCommand(kind: kind, targetBlockID: selectedTextBlock, selection: NSRange(location: caretOffset, length: selectedLength))
    }

    private var toolbarDivider: some View { Divider().frame(height: 25).padding(.horizontal, 5) }

    private func toolbarIconButton(_ symbol: String, help: String, font: Font = .system(size: 16), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if symbol == "B" || symbol == "I" || symbol == "U̲" { Text(symbol).font(font) }
                else { Image(systemName: symbol).font(font) }
            }
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func colorChoice(_ name: String, color: NSColor, highlight: Bool = false) -> some View {
        Button(name) {
            issueEditorCommand(highlight ? .highlightColor(color) : .textColor(color))
        }
    }

    private var tablePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("INSERT TABLE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 3) {
                ForEach(1...8, id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach(1...8, id: \.self) { col in
                            Button { insertTable(rows: row, columns: col) } label: {
                                Rectangle().fill(row <= tableSize.rows && col <= tableSize.columns ? Color.white.opacity(0.65) : Color.clear)
                                    .frame(width: 19, height: 19).overlay(Rectangle().stroke(.secondary.opacity(0.6), lineWidth: 1))
                            }.buttonStyle(.plain).onHover { inside in if inside { tableSize = (row, col) } }
                        }
                    }
                }
            }
            Text(tableSize.rows == 0 ? "Choose a size" : "\(tableSize.rows) × \(tableSize.columns)").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }.padding(8).frame(width: 220).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func insertTable(rows: Int, columns: Int) {
        let table = PageTable(cells: Array(repeating: Array(repeating: "", count: columns), count: rows))
        store.updatePage { target in
            var blocks = target.contentBlocks
            if blocks.isEmpty {
                blocks.append(.textBlock(target.body, richTextData: target.richTextData))
                blocks.append(contentsOf: target.tables.map(PageContentBlock.tableBlock))
                target.tables = []
            }
            let textIndex = blocks.firstIndex(where: { $0.id == selectedTextBlock && $0.text != nil }) ?? blocks.firstIndex(where: { $0.text != nil })
            if let index = textIndex, let source = blocks[index].text {
                let utf16 = source.utf16
                let safeOffset = min(max(0, caretOffset), utf16.count)
                let split = String.Index(utf16Offset: safeOffset, in: source)
                let endOffset = min(safeOffset + selectedLength, utf16.count)
                let end = String.Index(utf16Offset: endOffset, in: source)
                let before = String(source[..<split]); let after = String(source[end...])
                let beforeID = blocks[index].id
                let oldData = blocks[index].richTextData
                let attributed = oldData.flatMap { try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) } ?? NSAttributedString(string: source, attributes: [.font: NSFont.systemFont(ofSize: 14)])
                let beforeData = rtfData(attributed.attributedSubstring(from: NSRange(location: 0, length: safeOffset)))
                let afterData = rtfData(attributed.attributedSubstring(from: NSRange(location: endOffset, length: max(0, attributed.length - endOffset))))
                let replacement = [PageContentBlock.textBlock(before, id: beforeID, richTextData: beforeData), .tableBlock(table), .textBlock(after, richTextData: afterData)]
                blocks.replaceSubrange(index...index, with: replacement)
            } else {
                blocks.append(.tableBlock(table))
            }
            target.contentBlocks = blocks
            target.body = blocks.compactMap(\.text).joined()
            target.richTextData = nil
        }
        showInsertMenu = false; tableSize = (0, 0); selectedLength = 0
    }

    private var renderedBlocks: [PageContentBlock] {
        if !page.contentBlocks.isEmpty { return page.contentBlocks }
        return [.textBlock(page.body, id: legacyBlockID, richTextData: page.richTextData)] + page.tables.map(PageContentBlock.tableBlock)
    }
    private func moveFocusToBody() {
        guard let textBlock = renderedBlocks.first(where: { $0.text != nil }) else { return }
        selectedImageID = nil
        selectedTextBlock = textBlock.id
        caretOffset = 0
        selectedLength = 0
        bodyFocusTargetID = textBlock.id
        bodyFocusRequestID = UUID()
    }
    private var wordCount: Int {
        let text = renderedBlocks.compactMap(\.text).joined(separator: " ")
        return text.split(whereSeparator: \.isWhitespace).count
    }
    private var isBlankPage: Bool {
        renderedBlocks.count == 1 && (renderedBlocks.first?.text?.isEmpty ?? true) && page.images.isEmpty
    }
    private var pageCardHeight: CGFloat {
        let imageBottomEdges: [CGFloat] = page.images.map { image in
            CGFloat(image.y) + 90 + (CGFloat(image.width) * 0.75 / 2) + 40
        }
        let lowestImageEdge = imageBottomEdges.max() ?? 0
        let blocks = renderedBlocks
        let blockHeights = blocks.reduce(CGFloat.zero) { height, block in
            if let table = block.table { return height + 60 + CGFloat(table.rows * 34) }
            return height + textBlockHeight(block, availableWidth: canvasSize.width)
        }
        // Metadata, title, top inset, VStack spacing, and a modest bottom inset.
        let contentHeight = 62 + 16 + 43 + CGFloat(blocks.count + 1) * 18 + blockHeights + 30
        return max(250, max(contentHeight, lowestImageEdge))
    }
    private func pageCanvasHeight(viewportHeight: CGFloat) -> CGFloat {
        max(800, max(viewportHeight, pageCardHeight + 50))
    }
    private func blockTextBinding(_ block: PageContentBlock) -> Binding<String> {
        Binding(get: { page.contentBlocks.isEmpty ? page.body : (page.contentBlocks.first(where: { $0.id == block.id })?.text ?? "") }, set: { value in
            store.updatePage { target in
                if target.contentBlocks.isEmpty { target.body = value }
                else if let index = target.contentBlocks.firstIndex(where: { $0.id == block.id }) { target.contentBlocks[index].text = value; target.body = target.contentBlocks.compactMap(\.text).joined() }
            }
        })
    }
    private func blockRichDataBinding(_ block: PageContentBlock) -> Binding<Data?> {
        Binding(get: { page.contentBlocks.isEmpty ? page.richTextData : page.contentBlocks.first(where: { $0.id == block.id })?.richTextData }, set: { value in
            store.updatePage { target in
                if target.contentBlocks.isEmpty { target.richTextData = value }
                else if let index = target.contentBlocks.firstIndex(where: { $0.id == block.id }) { target.contentBlocks[index].richTextData = value }
            }
        })
    }
    private func rtfData(_ attributed: NSAttributedString) -> Data? { try? attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) }
    private func textBlockHeight(_ block: PageContentBlock, availableWidth: CGFloat) -> CGFloat {
        let text = block.text ?? ""
        if text.isEmpty { return 180 }
        let charsPerLine = max(35, Int(max(480, min(920, availableWidth - 110)) / 8))
        let lines = text.components(separatedBy: .newlines).reduce(0) { partial, line in
            partial + max(1, Int(ceil(Double(line.count) / Double(charsPerLine))))
        }
        return min(1400, max(76, CGFloat(lines) * 24 + 14))
    }
    private func updateTable(blockID: UUID, cells: [[String]]) {
        store.updatePage { target in if let i = target.contentBlocks.firstIndex(where: { $0.id == blockID }), target.contentBlocks[i].table != nil { target.contentBlocks[i].table?.cells = cells } }
    }
    private func deleteTable(blockID: UUID) { store.updatePage { $0.contentBlocks.removeAll { $0.id == blockID } } }

    private func insertionPoint() -> CGPoint {
        if selectedTextBlock != nil, let caretCanvasPoint { return caretCanvasPoint }
        let blocks = renderedBlocks
        var y: CGFloat = 205
        let bodyWidth = max(480, min(920, canvasSize.width - 110))
        let cardWidth = min(980, max(620, canvasSize.width - 76))
        let columnWidth = max(540, min(940, canvasSize.width - 100))
        let textOriginX = max(0, (canvasSize.width - cardWidth) / 2 + (cardWidth - columnWidth) / 2)
        guard let targetIndex = blocks.firstIndex(where: { $0.id == selectedTextBlock && $0.text != nil }) else {
            if let firstText = blocks.first(where: { $0.text != nil }) { y += textBlockHeight(firstText, availableWidth: canvasSize.width) }
            return CGPoint(x: textOriginX, y: y)
        }
        for block in blocks[..<targetIndex] {
            if let table = block.table { y += CGFloat(58 + table.rows * 34) }
            else { y += textBlockHeight(block, availableWidth: canvasSize.width) }
        }
        let text = blocks[targetIndex].text ?? ""
        let safe = min(max(0, caretOffset), text.utf16.count)
        let index = String.Index(utf16Offset: safe, in: text)
        let prefix = String(text[..<index])
        let font = NSFont.systemFont(ofSize: 15)
        let lines = prefix.components(separatedBy: .newlines)
        let lineCount = lines.reduce(0) { count, line in
            let measuredWidth = (line as NSString).size(withAttributes: [.font: font]).width
            return count + max(1, Int(ceil(measuredWidth / bodyWidth)))
        }
        let currentLine = lines.last ?? ""
        let currentLineWidth = (currentLine as NSString).size(withAttributes: [.font: font]).width
        let lineOffset = currentLineWidth.truncatingRemainder(dividingBy: bodyWidth)
        let lineX = lineOffset >= bodyWidth - 1 ? 0 : lineOffset
        return CGPoint(x: textOriginX + lineX, y: y + CGFloat(lineCount) * 21 + 8)
    }
    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { store.addImage(from: url, forPageID: page.id, at: insertionPoint()) }
    }
    private func pasteClipboardImage(at point: CGPoint? = nil) -> Bool {
        guard let imageData = NotebookStore.clipboardImageData() else { return false }
        store.addImage(data: imageData, forPageID: page.id, at: point ?? insertionPoint())
        return true
    }
    private func deleteImage(_ imageID: UUID) {
        store.deleteImage(imageID, fromPageID: page.id)
        loadedImages[imageID] = nil
        if selectedImageID == imageID { selectedImageID = nil }
    }
    @discardableResult
    private func deleteSelectedImage() -> Bool {
        guard let selectedImageID else { return false }
        deleteImage(selectedImageID)
        return true
    }
    private func imageDragGesture(for image: PageImage) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                selectedImageID = image.id
                if dragOrigin[image.id] == nil {
                    let initialPoint = CGPoint(x: image.x, y: max(180, image.y))
                    dragOrigin[image.id] = initialPoint
                }
                imageDragOffset[image.id] = CGPoint(x: value.translation.width, y: value.translation.height)
            }
            .onEnded { value in
                let initialPoint = dragOrigin[image.id] ?? CGPoint(x: image.x, y: max(180, image.y))
                let finalPoint = CGPoint(x: initialPoint.x + value.translation.width, y: initialPoint.y + value.translation.height)
                store.moveImage(image.id, to: finalPoint)
                dragOrigin[image.id] = nil
                imageDragOffset[image.id] = nil
            }
    }
    private func imagePosition(for image: PageImage) -> CGPoint {
        let offset = imageDragOffset[image.id] ?? .zero
        return CGPoint(x: image.x + image.width / 2 + offset.x, y: image.y + 90 + offset.y)
    }

    private func loadImageData(from provider: NSItemProvider, types: [String], index: Int = 0, completion: @escaping (Data?) -> Void) {
        guard index < types.count else {
            provider.loadObject(ofClass: NSImage.self) { object, _ in
                Task { @MainActor in
                    completion((object as? NSImage).flatMap(NotebookStore.pngData(from:)))
                }
            }
            return
        }

        provider.loadDataRepresentation(forTypeIdentifier: types[index]) { data, _ in
            Task { @MainActor in
                if let data, let png = NotebookStore.pngData(from: data) {
                    completion(png)
                } else {
                    self.loadImageData(from: provider, types: types, index: index + 1, completion: completion)
                }
            }
        }
    }

}

struct ImageDropDelegate: DropDelegate {
    var add: (URL, CGPoint) -> Void
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func performDrop(info: DropInfo) -> Bool {
        let point = info.location
        guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in add(url, point) } } }
        return true
    }
}

struct EditableTable: View {
    let table: PageTable
    let onChange: ([[String]]) -> Void
    let onDelete: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(table.rows) × \(table.columns) table").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { var cells = table.cells; cells.append(Array(repeating: "", count: table.columns)); onChange(cells) } label: { Label("Add row", systemImage: "plus.rectangle") }.buttonStyle(.plain).help("Add row")
                Button { var cells = table.cells; for i in cells.indices { cells[i].append("") }; onChange(cells) } label: { Label("Add column", systemImage: "rectangle.split.3x1") }.buttonStyle(.plain).help("Add column")
                Button(role: .destructive, action: onDelete) { Label("Delete table", systemImage: "trash").foregroundStyle(.red) }
                    .labelStyle(.iconOnly).buttonStyle(.plain).help("Delete table")
            }
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<table.columns, id: \.self) { col in
                        Button { if table.columns > 1 { onChange(table.cells.map { row in row.enumerated().filter { $0.offset != col }.map(\.element) }) } }
                            label: { Text("×").foregroundStyle(.secondary).frame(minWidth: 110, minHeight: 22) }
                            .buttonStyle(.plain).help("Delete column \(col + 1)")
                    }
                    Color.clear.frame(width: 26, height: 22)
                }
                ForEach(table.cells.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.cells[row].indices, id: \.self) { col in
                            TextField("", text: Binding(get: { table.cells[row][col] }, set: { value in
                                var cells = table.cells; cells[row][col] = value; onChange(cells)
                            })).textFieldStyle(.plain).padding(7).frame(minWidth: 110, minHeight: 34, alignment: .leading)
                                .overlay(Rectangle().stroke(Color.secondary.opacity(0.28), lineWidth: 0.6))
                        }
                        Button { if table.rows > 1 { onChange(table.cells.enumerated().filter { $0.offset != row }.map(\.element)) } }
                            label: { Image(systemName: "minus.circle").foregroundStyle(.secondary).frame(width: 26, height: 34) }
                            .buttonStyle(.plain).help("Delete row \(row + 1)")
                    }
                }
            }
        }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
    }
}

struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var richData: Data?
    var command: EditorCommand?
    var focusRequest: UUID?
    var blockID: UUID
    var onSelection: (NSRange, CGPoint) -> Void
    var onPasteImage: (CGPoint) -> Bool
    var onDeleteSelectedImage: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = false
        let view = JotvellaTextView(); view.isRichText = true; view.allowsUndo = true; view.drawsBackground = false; view.delegate = context.coordinator
        view.pasteImage = { localCaret in context.coordinator.pasteImage(at: localCaret) }
        view.deleteSelectedImage = { context.coordinator.deleteSelectedImage() }
        view.textContainerInset = NSSize(width: 0, height: 4); view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true; view.font = .systemFont(ofSize: 15); view.textColor = .labelColor
        view.typingAttributes[.foregroundColor] = NSColor.labelColor
        if let data = richData, let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { view.textStorage?.setAttributedString(appearanceCompatible(attributed)) }
        else { view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])) }
        applyDetectedURLLinks(to: view)
        scroll.documentView = view; return scroll
    }
    private func applyDetectedURLLinks(to view: NSTextView) {
        guard let storage = view.textStorage, storage.length > 0,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        for match in detector.matches(in: view.string, range: NSRange(location: 0, length: storage.length)) {
            guard let url = match.url else { continue }
            storage.addAttribute(.link, value: url, range: match.range)
        }
    }
    private func appearanceCompatible(_ source: NSAttributedString) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: source)
        var replacements: [(NSRange, NSColor)] = []
        value.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: value.length)) { color, range, _ in
            guard let color = color as? NSColor else { replacements.append((range, .labelColor)); return }
            guard let components = color.usingColorSpace(.deviceRGB)?.cgColor.components, components.count >= 3 else { return }
            let isNeutral = abs(components[0] - components[1]) < 0.02 && abs(components[1] - components[2]) < 0.02
            if isNeutral && (components[0] < 0.08 || components[0] > 0.92) { replacements.append((range, .labelColor)) }
        }
        for (range, color) in replacements { value.addAttribute(.foregroundColor, value: color, range: range) }
        return value
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if let focusRequest, context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            view.setSelectedRange(NSRange(location: 0, length: 0))
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window != nil else { return }
                view.window?.makeFirstResponder(view)
            }
        }
        if context.coordinator.lastCommand != command?.id,
           let command,
           command.targetBlockID == blockID {
            let length = (view.string as NSString).length
            let location = min(command.selection.location, length)
            let selectionLength = min(command.selection.length, length - location)
            view.setSelectedRange(NSRange(location: location, length: selectionLength))
            context.coordinator.apply(command.kind, to: view)
            context.coordinator.lastCommand = command.id
            context.coordinator.lastText = view.string
            if text != view.string { text = view.string }
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window != nil else { return }
                view.window?.makeFirstResponder(view)
            }
        }
        if view.string != text && context.coordinator.lastText != text {
            view.string = text
            applyDetectedURLLinks(to: view)
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor; var lastCommand: UUID?; var lastFocusRequest: UUID?; var lastText = ""
        private var pendingTextProcessing: DispatchWorkItem?
        init(_ parent: RichTextEditor) { self.parent = parent }
        func pasteImage(at localCaret: CGPoint) -> Bool { parent.onPasteImage(localCaret) }
        func deleteSelectedImage() -> Bool { parent.onDeleteSelectedImage() }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            lastText = view.string; parent.text = view.string
            pendingTextProcessing?.cancel()
            let work = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view else { return }
                self.flushRichTextChanges(in: view)
            }
            pendingTextProcessing = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
        }
        func textDidEndEditing(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            flushRichTextChanges(in: view)
        }
        private func flushRichTextChanges(in view: NSTextView) {
            pendingTextProcessing?.cancel()
            pendingTextProcessing = nil
            synchronizeURLLinks(in: view)
            if let data = try? view.textStorage?.data(from: NSRange(location: 0, length: view.textStorage?.length ?? 0), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) { parent.richData = data }
        }
        private func synchronizeURLLinks(in view: NSTextView) {
            guard let storage = view.textStorage, storage.length > 0 else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            var pastedURLRanges: [NSRange] = []
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard value != nil, range.length > 0 else { return }
                let visibleText = storage.attributedSubstring(from: range).string
                if visibleText.hasPrefix("https://") || visibleText.hasPrefix("http://") {
                    pastedURLRanges.append(range)
                }
            }
            for range in pastedURLRanges { storage.removeAttribute(.link, range: range) }

            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
            for match in detector.matches(in: view.string, range: fullRange) {
                guard let url = match.url else { continue }
                storage.addAttribute(.link, value: url, range: match.range)
            }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.onSelection(view.selectedRange(), caretPoint(in: view))
        }
        private func caretPoint(in view: NSTextView) -> CGPoint {
            let origin = view.textContainerOrigin
            guard let layout = view.layoutManager, let container = view.textContainer else { return origin }
            let length = (view.string as NSString).length
            guard length > 0 else { return origin }
            let range = view.selectedRange()
            let characterIndex = min(max(0, range.location), length - 1)
            let glyphIndex = layout.glyphIndexForCharacter(at: characterIndex)
            let line = layout.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
            let x = range.location >= length ? glyphRect.maxX : glyphRect.minX
            return CGPoint(x: origin.x + x, y: origin.y + line.minY)
        }
        func apply(_ kind: EditorCommand.Kind, to view: NSTextView) {
            let range = view.selectedRange(); guard range.location != NSNotFound else { return }
            let storage = view.textStorage
            let attributedTextBefore = storage.map { NSAttributedString(attributedString: $0) }
            switch kind {
            case .bold, .italic, .underline:
                let key: NSAttributedString.Key = kind == .underline ? .underlineStyle : .font
                if range.length == 0 {
                    let current = view.typingAttributes
                    if kind == .underline { view.typingAttributes[.underlineStyle] = ((current[.underlineStyle] as? NSNumber)?.intValue == NSUnderlineStyle.single.rawValue) ? 0 : NSUnderlineStyle.single.rawValue }
                    else {
                        let old = (current[.font] as? NSFont) ?? .systemFont(ofSize: 15)
                        let trait: NSFontTraitMask = kind == .bold ? .boldFontMask : .italicFontMask
                        let hasTrait = old.fontDescriptor.symbolicTraits.contains(kind == .bold ? .bold : .italic)
                        view.typingAttributes[.font] = hasTrait ? NSFontManager.shared.convert(old, toNotHaveTrait: trait) : NSFontManager.shared.convert(old, toHaveTrait: trait)
                    }
                } else if kind == .underline {
                    var allUnderlined = true
                    storage?.enumerateAttribute(key, in: range) { value, _, _ in
                        if (value as? NSNumber)?.intValue != NSUnderlineStyle.single.rawValue { allUnderlined = false }
                    }
                    storage?.addAttribute(key, value: allUnderlined ? 0 : NSUnderlineStyle.single.rawValue, range: range)
                }
                else { storage?.enumerateAttribute(.font, in: range) { value, subrange, _ in
                    let old = (value as? NSFont) ?? .systemFont(ofSize: 15); let trait: NSFontTraitMask = kind == .bold ? .boldFontMask : .italicFontMask
                    let remove = old.fontDescriptor.symbolicTraits.contains(kind == .bold ? .bold : .italic)
                    let updated = remove ? NSFontManager.shared.convert(old, toNotHaveTrait: trait) : NSFontManager.shared.convert(old, toHaveTrait: trait)
                    storage?.addAttribute(.font, value: updated, range: subrange)
                } }
            case .heading(let value):
                let font: NSFont
                let color: NSColor?
                switch value {
                case 0: font = .systemFont(ofSize: 15); color = .labelColor
                case 1...6: font = .systemFont(ofSize: CGFloat(29 - value * 3), weight: .semibold); color = .labelColor
                case 101: font = .systemFont(ofSize: 32, weight: .bold); color = .labelColor
                case 102: font = .systemFont(ofSize: 13); color = .secondaryLabelColor
                case 103: font = NSFontManager.shared.convert(.systemFont(ofSize: 17, weight: .medium), toHaveTrait: .italicFontMask); color = .labelColor
                case 104: font = .monospacedSystemFont(ofSize: 14, weight: .regular); color = .labelColor
                default: font = .systemFont(ofSize: 15); color = .labelColor
                }
                if range.length == 0 {
                    view.typingAttributes[.font] = font
                    view.typingAttributes[.foregroundColor] = color
                } else {
                    storage?.addAttribute(.font, value: font, range: range)
                    if let color { storage?.addAttribute(.foregroundColor, value: color, range: range) }
                }
            case .fontSize(let size):
                if range.length == 0 {
                    let old = (view.typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: 15)
                    view.typingAttributes[.font] = NSFontManager.shared.convert(old, toSize: CGFloat(size))
                } else {
                    storage?.enumerateAttribute(.font, in: range) { value, subrange, _ in
                        let old = (value as? NSFont) ?? .systemFont(ofSize: 15)
                        storage?.addAttribute(.font, value: NSFontManager.shared.convert(old, toSize: CGFloat(size)), range: subrange)
                    }
                }
            case .alignment(let alignment):
                let style = NSMutableParagraphStyle()
                if let current = view.typingAttributes[.paragraphStyle] as? NSParagraphStyle { style.setParagraphStyle(current) }
                style.alignment = alignment
                view.typingAttributes[.paragraphStyle] = style
                if range.length == 0 {
                    if let storage, storage.length > 0 {
                        let nsString = storage.string as NSString
                        let paragraph = nsString.lineRange(for: NSRange(location: min(range.location, nsString.length), length: 0))
                        view.setAlignment(alignment, range: paragraph)
                    }
                } else {
                    let nsString = (storage?.string ?? "") as NSString
                    view.setAlignment(alignment, range: nsString.paragraphRange(for: range))
                }
            case .textColor(let color):
                if range.length == 0 { view.typingAttributes[.foregroundColor] = color } else { storage?.addAttribute(.foregroundColor, value: color, range: range) }
            case .highlightColor(let color):
                if range.length == 0 {
                    if color == .clear { view.typingAttributes.removeValue(forKey: .backgroundColor) }
                    else { view.typingAttributes[.backgroundColor] = color }
                } else if color == .clear {
                    storage?.removeAttribute(.backgroundColor, range: range)
                } else {
                    storage?.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.45), range: range)
                }
            case .link(let address):
                let normalized = address.contains("://") ? address : "https://\(address)"
                guard let url = URL(string: normalized) else { return }
                if range.length == 0 {
                    let linkedText = NSAttributedString(string: normalized, attributes: [.link: url, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue])
                    storage?.replaceCharacters(in: range, with: linkedText)
                    view.setSelectedRange(NSRange(location: range.location + linkedText.length, length: 0))
                } else {
                    storage?.addAttribute(.link, value: url, range: range)
                    storage?.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
                    storage?.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            case .linePrefix(let prefix):
                applyLinePrefix(prefix, to: view, selection: range)
            }
            if let attributedTextBefore, let storage, !attributedTextBefore.isEqual(to: storage), let jotvellaView = view as? JotvellaTextView {
                jotvellaView.registerRichTextUndo(attributedTextBefore, selection: range, actionName: "Format Text")
            }
            view.didChangeText()
            if let data = try? storage?.data(from: NSRange(location: 0, length: storage?.length ?? 0), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) { parent.richData = data }
        }

        private func applyLinePrefix(_ prefix: String, to view: NSTextView, selection: NSRange) {
            guard let storage = view.textStorage else { return }
            let source = storage.string as NSString
            let start = min(selection.location, source.length)
            let end = min(selection.location + selection.length, source.length)
            var lineRanges: [NSRange] = []
            var cursor = start
            repeat {
                let probe = min(cursor, max(0, source.length - 1))
                let line = source.lineRange(for: NSRange(location: probe, length: 0))
                if !lineRanges.contains(where: { $0.location == line.location }) { lineRanges.append(line) }
                if selection.length == 0 || NSMaxRange(line) > end || NSMaxRange(line) <= cursor { break }
                cursor = NSMaxRange(line)
            } while cursor <= source.length

            var changes: [(location: Int, delta: Int)] = []
            for (index, line) in lineRanges.enumerated().reversed() {
                let actual = NSRange(location: line.location, length: line.length)
                let lineText = (storage.string as NSString).substring(with: actual)
                let marker = prefix == "1. " ? "\(index + 1). " : prefix
                let existingMarker: String?
                if lineText.hasPrefix("• ") { existingMarker = "• " }
                else if let match = lineText.range(of: #"^\d+\. "#, options: .regularExpression) { existingMarker = String(lineText[match]) }
                else { existingMarker = nil }
                let attributes = storage.length > line.location ? storage.attributes(at: line.location, effectiveRange: nil) : view.typingAttributes
                let existingIsNumber = existingMarker.map { $0.range(of: #"^\d+\. $"#, options: .regularExpression) != nil } ?? false
                let requestedIsNumber = prefix == "1. "
                let sameListType = requestedIsNumber ? existingIsNumber : existingMarker == prefix
                let replacement = sameListType ? "" : marker
                let replacedLength = (existingMarker as NSString?)?.length ?? 0
                storage.replaceCharacters(in: NSRange(location: line.location, length: replacedLength), with: NSAttributedString(string: replacement, attributes: attributes))
                changes.append((line.location, (replacement as NSString).length - replacedLength))
            }
            let selectionEnd = selection.location + selection.length
            let beforeStart = changes.filter { $0.location <= selection.location }.reduce(0) { $0 + $1.delta }
            let withinSelection = changes.filter { $0.location >= selection.location && $0.location < selectionEnd }.reduce(0) { $0 + $1.delta }
            let newLocation = max(0, min(storage.length, selection.location + beforeStart))
            let newLength = max(0, min(storage.length - newLocation, selection.length + withinSelection))
            view.setSelectedRange(NSRange(location: newLocation, length: newLength))
        }
    }
}

private final class JotvellaTextView: NSTextView {
    var pasteImage: ((CGPoint) -> Bool)?
    var deleteSelectedImage: (() -> Bool)?

    func registerRichTextUndo(_ snapshot: NSAttributedString, selection: NSRange, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreRichText(snapshot, selection: selection, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    private func restoreRichText(_ snapshot: NSAttributedString, selection: NSRange, actionName: String) {
        guard let textStorage else { return }
        let current = NSAttributedString(attributedString: textStorage)
        let currentSelection = selectedRange()
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreRichText(current, selection: currentSelection, actionName: actionName)
        }
        textStorage.setAttributedString(snapshot)
        let safeLocation = min(selection.location, textStorage.length)
        let safeLength = min(selection.length, textStorage.length - safeLocation)
        setSelectedRange(NSRange(location: safeLocation, length: safeLength))
        didChangeText()
        undoManager?.setActionName(actionName)
    }

    override func deleteBackward(_ sender: Any?) {
        if deleteSelectedImage?() == true { return }
        super.deleteBackward(sender)
    }
    override func deleteForward(_ sender: Any?) {
        if deleteSelectedImage?() == true { return }
        super.deleteForward(sender)
    }
    override func paste(_ sender: Any?) {
        if pasteImage?(caretPoint()) == true { return }
        let oldSelection = selectedRange()
        let oldLength = textStorage?.length ?? 0
        super.paste(sender)

        guard let storage = textStorage else { return }
        let insertedLength = storage.length - oldLength + oldSelection.length
        guard insertedLength > 0, oldSelection.location != NSNotFound,
              oldSelection.location + insertedLength <= storage.length else { return }

        let insertedRange = NSRange(location: oldSelection.location, length: insertedLength)
        var replacements: [(NSRange, NSColor)] = []
        storage.enumerateAttribute(.foregroundColor, in: insertedRange) { value, range, _ in
            guard let color = value as? NSColor,
                  let components = color.usingColorSpace(.deviceRGB)?.cgColor.components,
                  components.count >= 3 else {
                replacements.append((range, .labelColor))
                return
            }
            let isNeutral = abs(components[0] - components[1]) < 0.02 && abs(components[1] - components[2]) < 0.02
            if isNeutral && (components[0] < 0.08 || components[0] > 0.92) {
                replacements.append((range, .labelColor))
            }
        }
        for (range, color) in replacements {
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
        typingAttributes[.foregroundColor] = NSColor.labelColor
        if !replacements.isEmpty { didChangeText() }
    }
    private func caretPoint() -> CGPoint {
        let origin = textContainerOrigin
        guard let layout = layoutManager, let container = textContainer else { return origin }
        let length = (string as NSString).length
        guard length > 0 else { return origin }
        let range = selectedRange()
        let characterIndex = min(max(0, range.location), length - 1)
        let glyphIndex = layout.glyphIndexForCharacter(at: characterIndex)
        let line = layout.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
        let x = range.location >= length ? glyphRect.maxX : glyphRect.minX
        return CGPoint(x: origin.x + x, y: origin.y + line.minY)
    }
}

private extension View {
    func tagStyle() -> some View { self.font(.caption).foregroundStyle(Color.white).padding(.horizontal, 8).padding(.vertical, 5).background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5)) }
}
