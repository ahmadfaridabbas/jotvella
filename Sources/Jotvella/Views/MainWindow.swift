import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The app's three-pane main window: notebook/section sidebar, page list, and the
/// freeform page editor. Also owns OneNote import and section-to-PDF export flows.
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
                            Text(item.page.title.isEmpty ? "Untitled" : item.page.title)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
