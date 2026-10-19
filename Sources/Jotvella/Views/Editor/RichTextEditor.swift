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
