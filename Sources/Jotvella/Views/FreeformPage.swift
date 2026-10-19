import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The free-canvas page editor: title, a formatting toolbar, positioned text and
/// table blocks, and draggable images. This is the heart of the "type anywhere"
/// editing model.
struct FreeformPage: View {
    @EnvironmentObject private var store: NotebookStore
    @FocusState private var pageTitleIsFocused: Bool
    let page: NotePage
    @State private var canvasSize: CGSize = .zero
    @State private var legacyBlockID = UUID()
    @State private var loadedImages: [UUID: NSImage] = [:]
    @State private var editorCommand: EditorCommand?
    @State private var bodyFocusTargetID: UUID?
    @State private var bodyFocusRequestID: UUID?
    @State private var showInsertMenu = false
    @State private var tableSize = (rows: 2, columns: 3)
    @State private var focusTableID: UUID?
    @State private var selectedTextBlock: UUID?
    @State private var caretOffset = 0
    @State private var selectedLength = 0
    @State private var caretCanvasPoint: CGPoint?
    @State private var selectedImageID: UUID?
    @State private var showLinkPrompt = false
    @State private var linkAddress = "https://"
    @State private var hoveredToolbarButton: String?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                formattingToolbar
                    .frame(width: min(980, max(620, geometry.size.width - 76)) + 28)
                    .frame(maxWidth: .infinity)
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
                    }
                    .frame(width: max(540, min(940, geometry.size.width - 100)), alignment: .leading)
                    .padding(.top, 62)
                    // Keep this stack at its intrinsic content height. Without this,
                    // the scroll view's tall viewport is reported as page content and
                    // the paper background grows to fill the unused space.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .zIndex(0)
                    ForEach(renderedBlocks) { block in
                        let size = contentBlockSize(block, pageWidth: geometry.size.width)
                        let origin = displayedBlockOrigin(block, pageWidth: geometry.size.width)
                        Group {
                            if let table = block.table {
                                EditableTable(
                                    table: table,
                                    focusFirstCell: focusTableID == block.id,
                                    maxWidth: min(920, max(280, min(980, max(620, geometry.size.width - 76)) - 120)),
                                    onChange: { cells in updateTable(blockID: block.id, cells: cells) },
                                    onColumnWidthsChange: { widths in updateTableColumnWidths(blockID: block.id, widths: widths) },
                                    onRowHeightsChange: { heights in updateTableRowHeights(blockID: block.id, heights: heights) },
                                    onDelete: { deleteTable(blockID: block.id) }
                                )
                            } else {
                                GeometryReader { blockGeometry in
                                    ZStack(alignment: .topLeading) {
                                        RichTextEditor(text: blockTextBinding(block), richData: blockRichDataBinding(block), command: editorCommand, focusRequest: bodyFocusTargetID == block.id ? bodyFocusRequestID : nil, blockID: block.id, onSelection: { range, localCaret in
                                            selectedImageID = nil; selectedTextBlock = block.id; caretOffset = range.location; selectedLength = range.length
                                            let frame = blockGeometry.frame(in: .named("pageCanvas"))
                                            caretCanvasPoint = CGPoint(x: frame.minX + localCaret.x, y: frame.minY + localCaret.y)
                                        }, onPasteImage: { localCaret in
                                            selectedImageID = nil; selectedTextBlock = block.id
                                            let frame = blockGeometry.frame(in: .named("pageCanvas"))
                                            let point = CGPoint(x: frame.minX + localCaret.x, y: frame.minY + localCaret.y)
                                            caretCanvasPoint = point
                                            return pasteClipboardImage(at: point)
                                        }, onDeleteSelectedImage: deleteSelectedImage)
                                        if isBlankPage && block.text?.isEmpty == true {
                                            Text("Start writing here…  Add a table or insert an image whenever you’re ready.")
                                                .font(.system(size: 15)).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 6).allowsHitTesting(false)
                                        }
                                    }
                                }
                                .frame(width: size.width, height: size.height, alignment: .topLeading)
                                .onTapGesture { selectedTextBlock = block.id }
                            }
                        }
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
                        .transaction { $0.animation = nil }
                    }
                    ForEach(page.images) { image in
                        if let nsImage = loadedImages[image.id] ?? NSImage(contentsOf: store.imageURL(image)) {
                            Image(nsImage: nsImage).resizable().scaledToFit().frame(width: image.width)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selectedImageID == image.id ? Color.white : .clear, lineWidth: 2))
                                .overlay(alignment: .topTrailing) {
                                    if selectedImageID == image.id {
                                        Button(role: .destructive) { deleteImage(image.id) } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.primary)
                                                .frame(width: 25, height: 25)
                                                .background(.regularMaterial, in: Circle())
                                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                                                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Remove image")
                                        .help("Remove image")
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
                                .position(imagePosition(for: image))
                                .onAppear { loadedImages[image.id] = nsImage }
                        }
                    }
                }
                .coordinateSpace(name: "pageCanvas")
                .id("page-top")
                .frame(minWidth: max(700, geometry.size.width), minHeight: pageCanvasHeight(viewportHeight: geometry.size.height), alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
            }
                    .onAppear {
                        DispatchQueue.main.async {
                            proxy.scrollTo("page-top", anchor: .top)
                        }
                    }
                    .onChange(of: page.id) { _ in
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo("page-top", anchor: .top)
                            }
                        }
                    }
                }
                .onAppear { canvasSize = geometry.size }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDeleteCommand { _ = deleteSelectedImage() }
        .onChange(of: page.id) { _ in
            pageTitleIsFocused = false
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
            if page.title.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    pageTitleIsFocused = true
                }
            }
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
                        Text("A").font(.system(size: 16, weight: .medium)).foregroundStyle(.primary)
                        .frame(width: 34, height: 30).background(Color.yellow.opacity(0.30), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78))
                .padding(.horizontal, 14).padding(.vertical, 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
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

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 6)
    }

    private func toolbarIconButton(_ symbol: String, help: String, font: Font = .system(size: 16), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if symbol == "B" || symbol == "I" || symbol == "U̲" { Text(symbol).font(font) }
                else { Image(systemName: symbol).font(font) }
            }
            .frame(width: 32, height: 32)
            .background(hoveredToolbarButton == symbol ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in hoveredToolbarButton = hovering ? symbol : nil }
    }

    @ViewBuilder
    private func colorChoice(_ name: String, color: NSColor, highlight: Bool = false) -> some View {
        Button(name) {
            issueEditorCommand(highlight ? .highlightColor(color) : .textColor(color))
        }
    }

    private var tablePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Insert table").font(.headline)
                Text("Choose the number of rows and columns.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 5) {
                ForEach(1...8, id: \.self) { row in
                    HStack(spacing: 5) {
                        ForEach(1...8, id: \.self) { col in
                            Button { insertTable(rows: row, columns: col) } label: {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(row <= tableSize.rows && col <= tableSize.columns
                                          ? Color.accentColor.opacity(0.72)
                                          : Color.primary.opacity(0.035))
                                    .frame(width: 25, height: 25)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .strokeBorder(row <= tableSize.rows && col <= tableSize.columns
                                                          ? Color.accentColor
                                                          : Color.primary.opacity(0.16), lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .help("Insert \(row) rows by \(col) columns")
                            .accessibilityLabel("\(row) rows by \(col) columns")
                            .onHover { inside in if inside { tableSize = (row, col) } }
                        }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\(tableSize.rows) rows × \(tableSize.columns) columns")
                    .font(.system(.caption, weight: .semibold))
                Spacer()
                Text("Click to insert")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func insertTable(rows: Int, columns: Int) {
        let defaultColumnWidth = min(150, max(70, 920 / Double(columns)))
        let table = PageTable(
            cells: Array(repeating: Array(repeating: "", count: columns), count: rows),
            columnWidths: Array(repeating: defaultColumnWidth, count: columns),
            rowHeights: Array(repeating: 42, count: rows)
        )
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
        focusTableID = table.id
        showInsertMenu = false; tableSize = (2, 3); selectedLength = 0
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
        let naturalBottom = renderedBlocks.map { block -> CGFloat in
            let origin = displayedBlockOrigin(block, pageWidth: canvasSize.width)
            return origin.y + contentBlockSize(block, pageWidth: canvasSize.width).height
        }.max() ?? 250
        let imageBottom = page.images.map { CGFloat($0.y) + 90 + CGFloat($0.width) * 0.75 }.max() ?? 0
        let desired = max(420, naturalBottom + 80, imageBottom + 80)
        return desired
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
    private func contentBlockSize(_ block: PageContentBlock, pageWidth: CGFloat) -> CGSize {
        let maxTableWidth = min(920, max(280, min(980, pageWidth - 76) - 120))
        let width: CGFloat
        if let table = block.table {
            let defaultColumnWidth = min(150, maxTableWidth / CGFloat(max(1, table.columns)))
            var storedWidth = defaultColumnWidth * CGFloat(table.columns)
            if let columnWidths = table.columnWidths { storedWidth = CGFloat(columnWidths.reduce(0, +)) }
            width = min(maxTableWidth, storedWidth)
        } else { width = max(480, min(920, pageWidth - 110)) }
        let height: CGFloat
        if let table = block.table {
            let rowsHeight: CGFloat
            if let rowHeights = table.rowHeights { rowsHeight = CGFloat(rowHeights.reduce(0, +)) }
            else { rowsHeight = CGFloat(table.rows) * 40 }
            height = 48 + rowsHeight
        } else { height = textBlockHeight(block, availableWidth: pageWidth) }
        return CGSize(width: width, height: height)
    }
    private func displayedBlockOrigin(_ block: PageContentBlock, pageWidth: CGFloat) -> CGPoint {
        let textColumnWidth = max(540, min(940, pageWidth - 100))
        let textOriginX = max(0, (pageWidth - textColumnWidth) / 2)
        var y: CGFloat = 180
        for candidate in renderedBlocks {
            if candidate.id == block.id { break }
            y += contentBlockSize(candidate, pageWidth: pageWidth).height + 24
        }
        return CGPoint(x: textOriginX, y: y)
    }
    private func updateTable(blockID: UUID, cells: [[String]]) {
        store.updatePage { target in
            guard let i = target.contentBlocks.firstIndex(where: { $0.id == blockID }), var table = target.contentBlocks[i].table else { return }
            table.cells = cells
            if table.columnWidths?.count != (cells.first?.count ?? 0) { table.columnWidths = nil }
            if table.rowHeights?.count != cells.count { table.rowHeights = nil }
            target.contentBlocks[i].table = table
        }
    }
    private func updateTableColumnWidths(blockID: UUID, widths: [Double]) {
        store.updatePage { target in
            guard let i = target.contentBlocks.firstIndex(where: { $0.id == blockID }), target.contentBlocks[i].table != nil else { return }
            target.contentBlocks[i].table?.columnWidths = widths
        }
    }
    private func updateTableRowHeights(blockID: UUID, heights: [Double]) {
        store.updatePage { target in
            guard let i = target.contentBlocks.firstIndex(where: { $0.id == blockID }), target.contentBlocks[i].table != nil else { return }
            target.contentBlocks[i].table?.rowHeights = heights
        }
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
    private func imagePosition(for image: PageImage) -> CGPoint {
        CGPoint(x: image.x + image.width / 2, y: image.y + 90)
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
