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
    @State private var measuredHeights: [UUID: CGFloat] = [:]
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    @State private var findScrollToken = UUID()
    @FocusState private var findFieldFocused: Bool
    @State private var showPagePicker = false
    @State private var pageSearch = ""
    @State private var imageDrag: (id: UUID, translation: CGSize)?
    @State private var imageResize: (id: UUID, width: Double)?
    @State private var isDropTargeted = false
    @State private var pageSelectAll = false
    @State private var selectionMonitor: Any?
    /// True only when the title is focused on purpose (a new, untitled page). Anything else is macOS handing the first field focus.
    @State private var titleFocusIsIntended = false
    @State private var bodyFocusAtEnd = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                formattingToolbar
                    .frame(width: min(980, max(620, geometry.size.width - 76)) + 28)
                    .frame(maxWidth: .infinity)
                if showFind {
                    findBar
                        .frame(width: min(980, max(620, geometry.size.width - 76)))
                        .frame(maxWidth: .infinity)
                }
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
                        TagBar(tags: page.tags ?? [], onChange: { newTags in store.updatePage { $0.tags = newTags.isEmpty ? nil : newTags } })
                            .padding(.top, -8)
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
                                    onTableChange: { updated in updateWholeTable(blockID: block.id, table: updated) },
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
                                        }, onDeleteSelectedImage: deleteSelectedImage,
                                        isCode: block.isCode == true,
                                        findQuery: showFind ? findQuery : "",
                                        activeFindRange: activeFindMatch?.blockID == block.id ? activeFindMatch?.range : nil,
                                        onHeightChange: { height in
                                            if abs((measuredHeights[block.id] ?? 0) - height) > 0.5 { measuredHeights[block.id] = height }
                                        },
                                        onBlockAction: { action in handleBlockAction(action) },
                                        onOpenPageLink: { id in store.openPage(id) },
                                        onSelectAllPage: { setPageSelection(true) },
                                        focusAtEnd: bodyFocusAtEnd)
                                        if isBlankPage && block.text?.isEmpty == true {
                                            Text("Start writing here…  Add a table or insert an image whenever you’re ready.")
                                                .font(.system(size: 15)).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 6).allowsHitTesting(false)
                                        }
                                    }
                                }
                                .frame(width: size.width, height: size.height, alignment: .topLeading)
                                .background {
                                    if block.isCode == true {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(Color.primary.opacity(0.06))
                                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                                            .padding(.vertical, 2)
                                    }
                                }
                                .onTapGesture { selectedTextBlock = block.id }
                            }
                        }
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .overlay {
                            if pageSelectAll && (block.table != nil || !(block.text ?? "").isEmpty) {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.22))
                                    .allowsHitTesting(false)
                            }
                        }
                        .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
                        .transaction { $0.animation = nil }
                    }
                    ForEach(page.images) { image in
                        if let nsImage = loadedImages[image.id] ?? NSImage(contentsOf: store.imageURL(image)) {
                            let displayWidth = imageResize.flatMap { $0.id == image.id ? $0.width : nil } ?? image.width
                            Image(nsImage: nsImage).resizable().scaledToFit().frame(width: displayWidth)
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
                                .overlay(alignment: .bottomTrailing) {
                                    if selectedImageID == image.id {
                                        Circle().fill(Color.accentColor)
                                            .frame(width: 13, height: 13)
                                            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                                            .padding(8)
                                            .contentShape(Rectangle())
                                            .offset(x: 12, y: 12)
                                            .help("Drag to resize")
                                            .accessibilityLabel("Resize image")
                                            .gesture(
                                                DragGesture(minimumDistance: 1, coordinateSpace: .named("pageCanvas"))
                                                    .onChanged { value in imageResize = (image.id, clampedImageWidth(image.width + value.translation.width)) }
                                                    .onEnded { value in
                                                        let width = clampedImageWidth(image.width + value.translation.width)
                                                        imageResize = nil
                                                        commitImageResize(image, nsImage: nsImage, width: width)
                                                    }
                                            )
                                    }
                                }
                                .overlay {
                                    if pageSelectAll {
                                        RoundedRectangle(cornerRadius: 7)
                                            .fill(Color.accentColor.opacity(0.28))
                                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 2))
                                            .allowsHitTesting(false)
                                    }
                                }
                                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedImageID = image.id }
                                .gesture(
                                    DragGesture(minimumDistance: 4, coordinateSpace: .named("pageCanvas"))
                                        .onChanged { value in
                                            selectedImageID = image.id
                                            imageDrag = (image.id, value.translation)
                                        }
                                        .onEnded { value in
                                            imageDrag = nil
                                            store.moveImage(image.id, to: CGPoint(x: image.x + value.translation.width, y: image.y + value.translation.height))
                                        }
                                )
                                .contextMenu {
                                    Button("Delete Image", role: .destructive) { deleteImage(image.id) }
                                        .tint(.red)
                                }
                                .position(displayedImagePosition(image, nsImage: nsImage, width: displayWidth))
                                .onAppear { loadedImages[image.id] = nsImage }
                        }
                    }
                    Color.clear.frame(width: 1, height: 1)
                        .alignmentGuide(.top) { _ in -findAnchorY(pageWidth: geometry.size.width) }
                        .allowsHitTesting(false)
                        .id("find-anchor")
                }
                .coordinateSpace(name: "pageCanvas")
                .id("page-top")
                .frame(minWidth: max(700, geometry.size.width), minHeight: pageCanvasHeight(viewportHeight: geometry.size.height), alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                            .padding(10).allowsHitTesting(false)
                    }
                }
                .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers, location in
                    handleDrop(providers, at: location)
                }
                .popover(isPresented: $showPagePicker, attachmentAnchor: .rect(.rect(CGRect(x: caretCanvasPoint?.x ?? 320, y: caretCanvasPoint?.y ?? 220, width: 1, height: 22))), arrowEdge: .bottom) {
                    pagePicker
                }
            }
                    .onAppear {
                        DispatchQueue.main.async {
                            proxy.scrollTo("page-top", anchor: .top)
                        }
                    }
                    .onChange(of: findScrollToken) { _ in
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("find-anchor", anchor: .center) }
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
        .overlay { shortcutButtons }
        .onChange(of: findQuery) { _ in
            findIndex = 0
            findScrollToken = UUID()
        }
        .onAppear { dropAccidentalTitleFocus() }
        .onDisappear { setPageSelection(false) }
        .onChange(of: page.id) { _ in
            setPageSelection(false)
            titleFocusIsIntended = false
            pageTitleIsFocused = false
            dropAccidentalTitleFocus()
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
                titleFocusIsIntended = true
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
                Menu { moreFormatItems } label: { Image(systemName: "ellipsis.circle").frame(width: 30, height: 34) }
                    .help("More formatting")
                    .menuIndicator(.hidden)

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

            Menu { moreFormatItems } label: { Image(systemName: "ellipsis.circle").frame(width: 30, height: 32) }
                .help("More formatting")
                .menuIndicator(.hidden)

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
                Divider()
                moreFormatItems
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

    private func insertTable(rows requestedRows: Int, columns requestedColumns: Int) {
        let rows = min(max(1, requestedRows), PageTable.maxRows)
        let columns = min(max(1, requestedColumns), PageTable.maxColumns)
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
        bodyFocusAtEnd = false
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
        let desired = max(300, naturalBottom + 28, imageBottom + 28)
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
        // A lone empty block is the page's typing area. Any other block is only as tall as its
        // text, so a table inserted at the caret sits right at the caret instead of far below it.
        let isOnlyBlock = renderedBlocks.count == 1
        let minimum: CGFloat = (text.isEmpty && isOnlyBlock && block.isCode != true) ? 180 : 32
        // Prefer the height the text view actually laid out; fall back to an estimate until it reports.
        if let measured = measuredHeights[block.id] { return max(minimum, measured + 6) }
        if text.isEmpty { return minimum }
        let charsPerLine = max(35, Int(max(480, min(920, availableWidth - 110)) / 8))
        let lines = text.components(separatedBy: .newlines).reduce(0) { partial, line in
            partial + max(1, Int(ceil(Double(line.count) / Double(charsPerLine))))
        }
        return min(1400, max(minimum, CGFloat(lines) * 22 + 10))
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
            y += contentBlockSize(candidate, pageWidth: pageWidth).height + 12
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
    private func updateWholeTable(blockID: UUID, table: PageTable) {
        store.updatePage { target in
            guard let i = target.contentBlocks.firstIndex(where: { $0.id == blockID }), target.contentBlocks[i].table != nil else { return }
            target.contentBlocks[i].table = table
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
    private func imagePosition(for image: PageImage, width: Double? = nil) -> CGPoint {
        CGPoint(x: image.x + (width ?? image.width) / 2, y: image.y + 90)
    }
    private func clampedImageWidth(_ width: Double) -> Double { min(900, max(60, width)) }
    /// Where an image is drawn right now, including an in-progress drag or resize.
    private func displayedImagePosition(_ image: PageImage, nsImage: NSImage, width: Double) -> CGPoint {
        var point = imagePosition(for: image, width: width)
        // Images are centered 90pt below their stored y, so a resize would move the top edge.
        // Shift the center by half the height change to keep the top-left corner fixed.
        let aspect = nsImage.size.width > 0 ? nsImage.size.height / nsImage.size.width : 0.75
        point.y += (CGFloat(width) - CGFloat(image.width)) * aspect / 2
        if let drag = imageDrag, drag.id == image.id {
            point.x += drag.translation.width
            point.y += drag.translation.height
        }
        return point
    }
    private func commitImageResize(_ image: PageImage, nsImage: NSImage, width: Double) {
        let aspect = nsImage.size.width > 0 ? Double(nsImage.size.height / nsImage.size.width) : 0.75
        store.updatePage { target in
            guard let index = target.images.firstIndex(where: { $0.id == image.id }) else { return }
            target.images[index].y = max(180, image.y + (width - image.width) * aspect / 2)
            target.images[index].width = width
        }
    }

    // MARK: - Block actions, code blocks, links

    private func handleBlockAction(_ action: EditorBlockAction) {
        // The text view calls this mid-edit, so wait for its selection updates to land first.
        DispatchQueue.main.async {
            switch action {
            case .toggleCode: insertCodeBlock()
            case .removeBlock: removeEmptyBlock()
            case .insertTable: insertTable(rows: 2, columns: 3)
            case .insertImage: chooseImage()
            case .linkPage:
                pageSearch = ""
                showPagePicker = true
            }
        }
    }

    /// Splits the current text block at the caret and puts an empty code block between the halves.
    /// If the caret is already in a code block, turns that block back into normal text.
    private func insertCodeBlock() {
        let newID = UUID()
        var focusID = newID
        store.updatePage { target in
            var blocks = target.contentBlocks
            if blocks.isEmpty {
                blocks.append(.textBlock(target.body, id: legacyBlockID, richTextData: target.richTextData))
                blocks.append(contentsOf: target.tables.map(PageContentBlock.tableBlock))
                target.tables = []
            }
            let code = PageContentBlock(id: newID, text: "", table: nil, richTextData: nil, isCode: true)
            let textIndex = blocks.firstIndex(where: { $0.id == selectedTextBlock && $0.text != nil }) ?? blocks.firstIndex(where: { $0.text != nil })
            if let index = textIndex, blocks[index].isCode == true {
                blocks[index].isCode = nil
                focusID = blocks[index].id
            } else if let index = textIndex, let source = blocks[index].text {
                let length = source.utf16.count
                let safeOffset = min(max(0, caretOffset), length)
                let endOffset = min(safeOffset + selectedLength, length)
                let before = String(source[..<String.Index(utf16Offset: safeOffset, in: source)])
                let after = String(source[String.Index(utf16Offset: endOffset, in: source)...])
                let attributed = blocks[index].richTextData.flatMap { try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
                    ?? NSAttributedString(string: source, attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])
                let safeBefore = min(safeOffset, attributed.length)
                let safeAfter = min(endOffset, attributed.length)
                let beforeData = rtfData(attributed.attributedSubstring(from: NSRange(location: 0, length: safeBefore)))
                let afterData = rtfData(attributed.attributedSubstring(from: NSRange(location: safeAfter, length: attributed.length - safeAfter)))
                let beforeID = blocks[index].id
                blocks.replaceSubrange(index...index, with: [.textBlock(before, id: beforeID, richTextData: beforeData), code, .textBlock(after, richTextData: afterData)])
            } else {
                blocks.append(code)
            }
            target.contentBlocks = blocks
            target.body = blocks.compactMap(\.text).joined()
            target.richTextData = nil
        }
        selectedTextBlock = focusID
        caretOffset = 0
        selectedLength = 0
        bodyFocusAtEnd = false
        bodyFocusTargetID = focusID
        bodyFocusRequestID = UUID()
    }

    /// Removes the empty text block the caret is in (Backspace in an empty block) and moves the
    /// caret to the end of the nearest text block before it, or after it if there is none before.
    private func removeEmptyBlock() {
        guard let id = selectedTextBlock else { return }
        var focus: UUID?
        store.updatePage { target in
            var blocks = target.contentBlocks
            guard blocks.count > 1,
                  let index = blocks.firstIndex(where: { $0.id == id && $0.table == nil && ($0.text ?? "").isEmpty }) else { return }
            focus = blocks[..<index].last(where: { $0.text != nil })?.id ?? blocks[(index + 1)...].first(where: { $0.text != nil })?.id
            blocks.remove(at: index)
            target.contentBlocks = blocks
            target.body = blocks.compactMap(\.text).joined()
        }
        guard let focus else { return }
        selectedTextBlock = focus
        bodyFocusAtEnd = true
        bodyFocusTargetID = focus
        bodyFocusRequestID = UUID()
    }

    private struct PageChoice: Identifiable {
        let id: UUID
        let title: String
        let location: String
    }

    private var pageChoices: [PageChoice] {
        store.notebooks.flatMap { notebook in
            notebook.sections.flatMap { section in
                section.pages.filter { $0.id != page.id }.map {
                    PageChoice(id: $0.id, title: $0.title.isEmpty ? "Untitled" : $0.title, location: "\(notebook.name) › \(section.name)")
                }
            }
        }
        .filter { pageSearch.isEmpty || $0.title.localizedStandardContains(pageSearch) }
    }

    private var pagePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Link to page").font(.headline)
            TextField("Search pages", text: $pageSearch).textFieldStyle(.roundedBorder)
            if pageChoices.isEmpty {
                Text("No matching pages").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(pageChoices) { choice in
                            Button { insertPageLink(choice) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(choice.title).lineLimit(1)
                                    Text(choice.location).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 220)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func insertPageLink(_ choice: PageChoice) {
        if selectedTextBlock == nil { selectedTextBlock = renderedBlocks.first(where: { $0.text != nil })?.id }
        issueEditorCommand(.pageLink(choice.id, choice.title))
        showPagePicker = false
        pageSearch = ""
    }

    // MARK: - Find in page

    private var findMatches: [(blockID: UUID, range: NSRange)] {
        guard showFind, !findQuery.isEmpty else { return [] }
        return renderedBlocks.flatMap { block -> [(blockID: UUID, range: NSRange)] in
            guard let text = block.text else { return [] }
            return FindMatches.ranges(in: text, query: findQuery).map { (blockID: block.id, range: $0) }
        }
    }

    private var activeFindMatch: (blockID: UUID, range: NSRange)? {
        let matches = findMatches
        guard !matches.isEmpty else { return nil }
        return matches[((findIndex % matches.count) + matches.count) % matches.count]
    }

    private var findStatus: String {
        if findQuery.isEmpty { return "" }
        let count = findMatches.count
        guard count > 0 else { return "No results" }
        return "\(((findIndex % count) + count) % count + 1) of \(count)"
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in page", text: $findQuery)
                .textFieldStyle(.plain)
                .focused($findFieldFocused)
                .onSubmit { stepFind(1) }
            Text(findStatus).font(.caption).foregroundStyle(.secondary)
            Button { stepFind(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).disabled(findMatches.isEmpty).help("Previous match")
            Button { stepFind(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).disabled(findMatches.isEmpty).help("Next match")
            Button("Done") { closeFind() }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .padding(.vertical, 2)
    }

    private func openFind() {
        showFind = true
        DispatchQueue.main.async { findFieldFocused = true }
    }

    private func closeFind() {
        showFind = false
        findQuery = ""
    }

    private func stepFind(_ delta: Int) {
        guard !findMatches.isEmpty else { return }
        findIndex += delta
        findScrollToken = UUID()
    }

    private func findAnchorY(pageWidth: CGFloat) -> CGFloat {
        guard let match = activeFindMatch, let block = renderedBlocks.first(where: { $0.id == match.blockID }) else { return 0 }
        return displayedBlockOrigin(block, pageWidth: pageWidth).y
    }

    // MARK: - Extra formatting menu and shortcuts

    @ViewBuilder
    private var moreFormatItems: some View {
        Button("Strikethrough", systemImage: "strikethrough") { issueEditorCommand(.strikethrough) }
        Button("Inline code", systemImage: "chevron.left.forwardslash.chevron.right") { issueEditorCommand(.inlineCode) }
        Button("Clear formatting", systemImage: "eraser") { issueEditorCommand(.clearFormatting) }
        Divider()
        Button("Checklist", systemImage: "checklist") { issueEditorCommand(.linePrefix(ListMarker.unchecked)) }
        Button("Code block", systemImage: "curlybraces") { handleBlockAction(.toggleCode) }
        Button("Link to page…", systemImage: "link.badge.plus") { handleBlockAction(.linkPage) }
        Divider()
        Button("Find in page", systemImage: "magnifyingglass") { openFind() }
        Button("Select all on page", systemImage: "selection.pin.in.out") { setPageSelection(true) }
    }

    /// Invisible buttons that carry the keyboard shortcuts for the extra commands, so they work
    /// whichever toolbar size is showing.
    private var shortcutButtons: some View {
        ZStack {
            Button("Strikethrough") { issueEditorCommand(.strikethrough) }.keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Inline Code") { issueEditorCommand(.inlineCode) }.keyboardShortcut("e", modifiers: [.command])
            Button("Clear Formatting") { issueEditorCommand(.clearFormatting) }.keyboardShortcut("\\", modifiers: [.command])
            Button("Find in Page") { openFind() }.keyboardShortcut("f", modifiers: [.command])
            Button("Select All on Page") { setPageSelection(true) }.keyboardShortcut("a", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Opening a page must not leave the title field focused with its text selected. The first text
    /// field in the window can take focus a moment after the page appears, so check a few times.
    private func dropAccidentalTitleFocus() {
        for delay in [0.0, 0.12, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard pageTitleIsFocused, !titleFocusIsIntended else { return }
                // A real click on the title is not accidental.
                if let type = NSApp.currentEvent?.type, type == .leftMouseDown || type == .leftMouseUp { return }
                pageTitleIsFocused = false
            }
        }
    }

    // MARK: - Select all on page

    /// Turns whole-page selection on or off. While it is on, a local event monitor handles
    /// Copy, Cut, Delete and Escape for the whole page, and any click or other key ends it.
    private func setPageSelection(_ on: Bool) {
        pageSelectAll = on
        if on {
            selectedImageID = nil
            guard selectionMonitor == nil else { return }
            selectionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
                guard pageSelectAll else { return event }
                if event.type == .leftMouseDown { setPageSelection(false); return event }
                let command = event.modifierFlags.contains(.command)
                let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
                if command && key == "a" { return event }
                if command && key == "c" { copyWholePage(); return nil }
                if command && key == "x" { copyWholePage(); deleteWholePage(); return nil }
                if event.keyCode == 51 || event.keyCode == 117 { deleteWholePage(); return nil }
                if event.keyCode == 53 { setPageSelection(false); return nil }
                if command { return event }
                setPageSelection(false)
                return event
            }
        } else if let monitor = selectionMonitor {
            NSEvent.removeMonitor(monitor)
            selectionMonitor = nil
        }
    }

    private func copyWholePage() {
        // Read the live page from the store: the monitor may hold an older copy of this view.
        guard let live = store.currentPage else { return }
        let images = live.images.compactMap { loadedImages[$0.id] ?? NSImage(contentsOf: store.imageURL($0)) }
        PageClipboard.write(live, images: images)
    }

    /// Clears the body, tables and pictures, leaving one empty text block. Title and tags stay.
    private func deleteWholePage() {
        guard let live = store.currentPage else { return }
        let keepID = live.contentBlocks.first(where: { $0.text != nil })?.id ?? legacyBlockID
        // Registered with the window's undo manager, so Command-Z brings everything back.
        store.clearPageContent(pageID: live.id, keeping: keepID, undoManager: (NSApp.keyWindow?.firstResponder)?.undoManager ?? NSApp.keyWindow?.undoManager)
        loadedImages.removeAll()
        selectedImageID = nil
        selectedTextBlock = keepID
        caretOffset = 0
        selectedLength = 0
        setPageSelection(false)
    }

    // MARK: - Drag and drop

    private func handleDrop(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        var handled = false
        for (offset, provider) in providers.enumerated() {
            // Images are centered 90pt below their stored y, and default to 260pt wide.
            let point = CGPoint(x: location.x - 130 + CGFloat(offset) * 24, y: location.y - 90 + CGFloat(offset) * 24)
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) } else { url = item as? URL }
                    guard let url, UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return }
                    Task { @MainActor in store.addImage(from: url, forPageID: page.id, at: point) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                let imageTypes = provider.registeredTypeIdentifiers.filter { UTType($0)?.conforms(to: .image) == true }
                loadImageData(from: provider, types: imageTypes) { data in
                    guard let data else { return }
                    Task { @MainActor in store.addImage(data: data, forPageID: page.id, at: point) }
                }
            }
        }
        return handled
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
