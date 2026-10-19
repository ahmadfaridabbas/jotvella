import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The app's central observable state: the notebook library, the current
/// selection, search query, and all mutation + file-package persistence logic.
///
/// The on-disk `.jotpkg` packages are the source of truth; this store loads them
/// on launch, debounces writes, and prunes orphaned files on save.
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
        let page = NotePage(title: "", body: "")
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
    static func pngData(from data: Data) -> Data? {
        if let bitmap = NSBitmapImageRep(data: data) { return bitmap.representation(using: .png, properties: [:]) }
        guard let image = NSImage(data: data) else { return nil }
        return pngData(from: image)
    }
    static func pngData(from image: NSImage) -> Data? {
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
