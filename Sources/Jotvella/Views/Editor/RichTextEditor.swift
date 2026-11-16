import SwiftUI
import AppKit

/// SwiftUI wrapper around `JotvellaTextView` providing rich-text editing with
/// toolbar command application, URL link detection, and image paste support.
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var richData: Data?
    var command: EditorCommand?
    var focusRequest: UUID?
    var blockID: UUID
    var onSelection: (NSRange, CGPoint) -> Void
    var onPasteImage: (CGPoint) -> Bool
    var onDeleteSelectedImage: () -> Bool
    var isCode: Bool = false
    /// Text to highlight for Find in Page, and the single match to emphasize.
    var findQuery: String = ""
    var activeFindRange: NSRange? = nil
    /// Reports the laid-out text height so the page can size the block exactly.
    var onHeightChange: (CGFloat) -> Void = { _ in }
    var onBlockAction: (EditorBlockAction) -> Void = { _ in }
    var onOpenPageLink: (UUID) -> Void = { _ in }
    var onSelectAllPage: () -> Void = {}
    /// When true, a focus request puts the caret at the end of the text instead of the start.
    var focusAtEnd: Bool = false

    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = false
        // The page sizes each block to its text, so a block never needs to scroll internally.
        scroll.contentView = TopPinnedClipView()
        scroll.contentView.drawsBackground = false
        scroll.postsFrameChangedNotifications = true
        let view = JotvellaTextView(); view.isRichText = true; view.allowsUndo = true; view.drawsBackground = false; view.delegate = context.coordinator
        view.pasteImage = { localCaret in context.coordinator.pasteImage(at: localCaret) }
        view.deleteSelectedImage = { context.coordinator.deleteSelectedImage() }
        view.onFormat = { [weak view] kind in guard let view else { return }; context.coordinator.apply(kind, to: view) }
        view.onBlockAction = { action in context.coordinator.parent.onBlockAction(action) }
        view.isCodeBlock = isCode
        view.onSelectAllPage = { context.coordinator.parent.onSelectAllPage() }
        view.textContainerInset = isCode ? NSSize(width: 10, height: 8) : NSSize(width: 0, height: 4); view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true; view.font = isCode ? Self.codeFont : Self.bodyFont; view.textColor = .labelColor
        view.typingAttributes[.foregroundColor] = NSColor.labelColor
        if isCode { view.typingAttributes[.font] = Self.codeFont }
        if let data = richData, let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { view.textStorage?.setAttributedString(appearanceCompatible(attributed)) }
        else { view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: isCode ? Self.codeFont : Self.bodyFont, .foregroundColor: NSColor.labelColor])) }
        applyDetectedURLLinks(to: view)
        scroll.documentView = view
        context.coordinator.lastIsCode = isCode
        context.coordinator.attach(scroll: scroll, textView: view)
        return scroll
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
            view.setSelectedRange(NSRange(location: focusAtEnd ? (view.string as NSString).length : 0, length: 0))
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
            // The model changed from outside the text view (a split, a clear, an undo). Keep the
            // saved formatting when it matches the text.
            if let data = richData,
               let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
               attributed.string == text {
                view.textStorage?.setAttributedString(appearanceCompatible(attributed))
            } else {
                view.string = text
            }
            context.coordinator.lastText = text
            applyDetectedURLLinks(to: view)
        }
        context.coordinator.syncCodeStyle(view)
        context.coordinator.refreshFindHighlights(view)
        context.coordinator.scheduleHeightReport()
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor; var lastCommand: UUID?; var lastFocusRequest: UUID?; var lastText = ""
        private var pendingTextProcessing: DispatchWorkItem?
        var lastIsCode = false
        private weak var textView: NSTextView?
        private var frameObserver: NSObjectProtocol?
        private var lastReportedHeight: CGFloat = -1
        private var heightReportPending = false
        private var lastFindKey = ""
        init(_ parent: RichTextEditor) { self.parent = parent }
        deinit { if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) } }

        func attach(scroll: NSScrollView, textView: NSTextView) {
            self.textView = textView
            frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
                self?.scheduleHeightReport()
            }
        }

        // MARK: Height

        func scheduleHeightReport() {
            guard !heightReportPending else { return }
            heightReportPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightReportPending = false
                self.reportHeight()
            }
        }
        private func reportHeight() {
            guard let view = textView, let layout = view.layoutManager, let container = view.textContainer, view.bounds.width > 40 else { return }
            layout.ensureLayout(for: container)
            // The empty last line (after a trailing Enter) is the "extra" fragment, which usedRect may omit.
            let textHeight = max(layout.usedRect(for: container).height, layout.extraLineFragmentRect.maxY)
            let height = ceil(textHeight + view.textContainerInset.height * 2)
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            parent.onHeightChange(height)
        }

        // MARK: Code block styling

        /// Switches a block between normal text and monospaced code text when its flag changes.
        func syncCodeStyle(_ view: NSTextView) {
            guard lastIsCode != parent.isCode else { return }
            lastIsCode = parent.isCode
            (view as? JotvellaTextView)?.isCodeBlock = parent.isCode
            view.textContainerInset = parent.isCode ? NSSize(width: 10, height: 8) : NSSize(width: 0, height: 4)
            let font = parent.isCode ? RichTextEditor.codeFont : RichTextEditor.bodyFont
            if let storage = view.textStorage, storage.length > 0 {
                storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
            }
            view.typingAttributes[.font] = font
            view.didChangeText()
            flushRichTextChanges(in: view)
            lastReportedHeight = -1
        }

        // MARK: Find highlights

        func refreshFindHighlights(_ view: NSTextView) {
            guard let layout = view.layoutManager else { return }
            let active = parent.activeFindRange.map { "\($0.location),\($0.length)" } ?? "-"
            let key = parent.findQuery.isEmpty ? "" : "\(parent.findQuery)|\(active)|\(view.string.hashValue)"
            guard key != lastFindKey else { return }
            lastFindKey = key
            let full = NSRange(location: 0, length: (view.string as NSString).length)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            for range in FindMatches.ranges(in: view.string, query: parent.findQuery) {
                let isActive = parent.activeFindRange == range
                layout.addTemporaryAttribute(.backgroundColor, value: (isActive ? NSColor.systemOrange : NSColor.systemYellow).withAlphaComponent(isActive ? 0.7 : 0.45), forCharacterRange: range)
            }
        }

        // MARK: Page links

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, url.scheme == "jotvella", url.host == "page", let id = UUID(uuidString: url.lastPathComponent) else { return false }
            parent.onOpenPageLink(id)
            return true
        }
        func pasteImage(at localCaret: CGPoint) -> Bool { parent.onPasteImage(localCaret) }
        func deleteSelectedImage() -> Bool { parent.onDeleteSelectedImage() }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            lastText = view.string; parent.text = view.string
            scheduleHeightReport()
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
            case .strikethrough:
                if range.length == 0 {
                    let on = (view.typingAttributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0
                    view.typingAttributes[.strikethroughStyle] = on == 0 ? NSUnderlineStyle.single.rawValue : 0
                } else {
                    var allStruck = true
                    storage?.enumerateAttribute(.strikethroughStyle, in: range) { value, _, _ in
                        if ((value as? NSNumber)?.intValue ?? 0) == 0 { allStruck = false }
                    }
                    storage?.addAttribute(.strikethroughStyle, value: allStruck ? 0 : NSUnderlineStyle.single.rawValue, range: range)
                }
            case .inlineCode:
                let tint = NSColor.secondaryLabelColor.withAlphaComponent(0.16)
                let mono = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                if range.length == 0 {
                    let isMono = ((view.typingAttributes[.font] as? NSFont)?.isFixedPitch) ?? false
                    view.typingAttributes[.font] = isMono ? RichTextEditor.bodyFont : mono
                    if isMono { view.typingAttributes.removeValue(forKey: .backgroundColor) } else { view.typingAttributes[.backgroundColor] = tint }
                } else {
                    var allMono = true
                    storage?.enumerateAttribute(.font, in: range) { value, _, _ in
                        if !(((value as? NSFont)?.isFixedPitch) ?? false) { allMono = false }
                    }
                    storage?.addAttribute(.font, value: allMono ? RichTextEditor.bodyFont : mono, range: range)
                    if allMono { storage?.removeAttribute(.backgroundColor, range: range) } else { storage?.addAttribute(.backgroundColor, value: tint, range: range) }
                }
            case .clearFormatting:
                if range.length == 0 {
                    view.typingAttributes[.font] = RichTextEditor.bodyFont
                    view.typingAttributes[.foregroundColor] = NSColor.labelColor
                    for key in [NSAttributedString.Key.underlineStyle, .strikethroughStyle, .backgroundColor, .link] { view.typingAttributes.removeValue(forKey: key) }
                } else {
                    for key in [NSAttributedString.Key.underlineStyle, .strikethroughStyle, .backgroundColor, .link] { storage?.removeAttribute(key, range: range) }
                    storage?.addAttributes([.font: RichTextEditor.bodyFont, .foregroundColor: NSColor.labelColor], range: range)
                }
            case .pageLink(let pageID, let title):
                guard let url = URL(string: "jotvella://page/\(pageID.uuidString)") else { return }
                let name = title.isEmpty ? "Untitled" : title
                if range.length == 0 {
                    let font = (view.typingAttributes[.font] as? NSFont) ?? RichTextEditor.bodyFont
                    let linked = NSAttributedString(string: name, attributes: [.font: font, .link: url, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue])
                    storage?.replaceCharacters(in: range, with: linked)
                    view.setSelectedRange(NSRange(location: range.location + linked.length, length: 0))
                    view.typingAttributes[.foregroundColor] = NSColor.labelColor
                    for key in [NSAttributedString.Key.link, .underlineStyle] { view.typingAttributes.removeValue(forKey: key) }
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
                let parsed = ListMarker.parse(lineText)
                let existingMarker = parsed?.marker
                let replaceLocation = line.location + (parsed?.indent ?? 0)
                let attributes = storage.length > line.location ? storage.attributes(at: line.location, effectiveRange: nil) : view.typingAttributes
                let requestedIsNumber = prefix == "1. "
                let requestedIsChecklist = prefix == ListMarker.unchecked
                let sameListType: Bool
                if requestedIsNumber { sameListType = parsed?.number != nil }
                else if requestedIsChecklist { sameListType = parsed?.isChecklist ?? false }
                else { sameListType = existingMarker == prefix }
                let replacement = sameListType ? "" : marker
                let replacedLength = (existingMarker as NSString?)?.length ?? 0
                storage.replaceCharacters(in: NSRange(location: replaceLocation, length: replacedLength), with: NSAttributedString(string: replacement, attributes: attributes))
                changes.append((replaceLocation, (replacement as NSString).length - replacedLength))
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


/// A clip view that always shows the top-left of its text. When Enter adds a line, the text view
/// is briefly taller than its block until the page re-measures. A normal scroll view scrolls the
/// caret into view in that moment and stays scrolled, which pushes the earlier lines out of sight.
final class TopPinnedClipView: NSClipView {
    // A replacement clip view paints the window background unless told not to, which showed as
    // dark bands over the page. Text blocks must stay transparent.
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); drawsBackground = false }
    required init?(coder: NSCoder) { super.init(coder: coder); drawsBackground = false }
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        rect.origin = .zero
        return rect
    }
    override func scroll(to newOrigin: NSPoint) { super.scroll(to: .zero) }
    override func setBoundsOrigin(_ newOrigin: NSPoint) { super.setBoundsOrigin(.zero) }
}
