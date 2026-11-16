import AppKit

/// An `NSTextView` subclass that adds rich-text undo, image paste/delete hooks,
/// and appearance-safe pasted text colors for the Jotvella editor.
final class JotvellaTextView: NSTextView {
    var pasteImage: ((CGPoint) -> Bool)?
    var deleteSelectedImage: (() -> Bool)?
    /// Applies a formatting command to the current selection (used by shortcuts and the slash menu).
    var onFormat: ((EditorCommand.Kind) -> Void)?
    /// Asks the page to change the block structure (code block, table, picture, page link).
    var onBlockAction: ((EditorBlockAction) -> Void)?
    /// Code blocks keep their text literal, so typing shortcuts are switched off there.
    var isCodeBlock = false
    /// When set, Select All selects the whole page (text, tables and pictures) instead of this block only.
    var onSelectAllPage: (() -> Void)?

    override func selectAll(_ sender: Any?) {
        if let onSelectAllPage { onSelectAllPage() } else { super.selectAll(sender) }
    }

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

    // MARK: - Lists, shortcuts and slash menu

    private struct LineContext {
        let caret: Int
        let lineStart: Int
        /// Text from the start of the line up to the caret.
        let beforeCaret: String
        /// True when nothing follows the caret on the line.
        let atLineEnd: Bool
    }

    private func lineContext() -> LineContext? {
        let selection = selectedRange()
        guard selection.location != NSNotFound, selection.length == 0 else { return nil }
        let source = string as NSString
        let caret = min(selection.location, source.length)
        let line = source.lineRange(for: NSRange(location: caret, length: 0))
        let before = source.substring(with: NSRange(location: line.location, length: caret - line.location))
        let after = source.substring(with: NSRange(location: caret, length: NSMaxRange(line) - caret))
        return LineContext(caret: caret, lineStart: line.location, beforeCaret: before, atLineEnd: after.trimmingCharacters(in: .newlines).isEmpty)
    }

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), !isCodeBlock, let context = lineContext() else { super.insertNewline(sender); return }

        if context.atLineEnd, context.beforeCaret == "```" {
            super.insertText("", replacementRange: NSRange(location: context.lineStart, length: 3))
            onBlockAction?(.toggleCode)
            return
        }

        if let match = ListMarker.parse(context.beforeCaret), (context.beforeCaret as NSString).length >= match.prefixLength {
            let content = (context.beforeCaret as NSString).substring(from: match.prefixLength)
            if content.isEmpty && context.atLineEnd {
                // Enter on an empty item ends the list.
                super.insertText("", replacementRange: NSRange(location: context.lineStart, length: match.prefixLength))
            } else {
                typingAttributes.removeValue(forKey: .strikethroughStyle)
                typingAttributes[.foregroundColor] = NSColor.labelColor
                super.insertText("\n" + ListMarker.continuation(of: match), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            return
        }

        // A heading should not carry on into the next paragraph.
        let source = string as NSString
        var endedLargeHeading = false
        if context.atLineEnd, context.caret > 0, context.caret <= source.length,
           let font = textStorage?.attribute(.font, at: context.caret - 1, effectiveRange: nil) as? NSFont, font.pointSize >= 20 {
            endedLargeHeading = true
        }
        super.insertNewline(sender)
        if endedLargeHeading {
            typingAttributes[.font] = NSFont.systemFont(ofSize: 15)
            typingAttributes[.foregroundColor] = NSColor.labelColor
        }
    }

    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText(), let context = lineContext(), let match = ListMarker.parse(context.beforeCaret),
              (context.beforeCaret as NSString).length >= match.prefixLength, match.indent < 8 else { super.insertTab(sender); return }
        super.insertText("  ", replacementRange: NSRange(location: context.lineStart, length: 0))
        setSelectedRange(NSRange(location: context.caret + 2, length: 0))
    }

    override func insertBacktab(_ sender: Any?) {
        guard !hasMarkedText(), let context = lineContext(), let match = ListMarker.parse(context.beforeCaret), match.indent > 0,
              (context.beforeCaret as NSString).length >= match.prefixLength else { super.insertBacktab(sender); return }
        let remove = min(2, match.indent)
        super.insertText("", replacementRange: NSRange(location: context.lineStart, length: remove))
        setSelectedRange(NSRange(location: max(context.lineStart, context.caret - remove), length: 0))
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let typed = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        guard let typed, !isCodeBlock, !hasMarkedText(), replacementRange.location == NSNotFound,
              let context = lineContext() else { super.insertText(insertString, replacementRange: replacementRange); return }

        if typed == " ", let kind = MarkdownShortcut.kind(forLineBeforeSpace: context.beforeCaret) {
            super.insertText("", replacementRange: NSRange(location: context.lineStart, length: (context.beforeCaret as NSString).length))
            onFormat?(kind)
            return
        }

        if typed == "[", context.beforeCaret.hasSuffix("[") {
            super.insertText("", replacementRange: NSRange(location: context.caret - 1, length: 1))
            onBlockAction?(.linkPage)
            return
        }

        super.insertText(insertString, replacementRange: replacementRange)

        if typed == "/", context.beforeCaret.trimmingCharacters(in: .whitespaces).isEmpty {
            let slashLocation = context.caret
            DispatchQueue.main.async { [weak self] in self?.showSlashMenu(slashLocation: slashLocation) }
        }
    }

    private final class MenuAction: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }
    private var menuActions: [MenuAction] = []

    private func showSlashMenu(slashLocation: Int) {
        guard window != nil, let layout = layoutManager, let container = textContainer else { return }
        let source = string as NSString
        guard slashLocation < source.length, source.character(at: slashLocation) == 0x2F else { return }

        let menu = NSMenu(title: "Insert")
        menuActions = []
        func add(_ title: String, symbol: String, _ action: @escaping () -> Void) {
            let handler = MenuAction { [weak self] in
                guard let self else { return }
                let current = self.string as NSString
                if slashLocation < current.length, current.character(at: slashLocation) == 0x2F {
                    self.superInsertText("", replacementRange: NSRange(location: slashLocation, length: 1))
                }
                action()
            }
            menuActions.append(handler)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
            item.target = handler
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            menu.addItem(item)
        }
        add("Heading 1", symbol: "textformat.size.larger") { [weak self] in self?.onFormat?(.heading(1)) }
        add("Heading 2", symbol: "textformat.size") { [weak self] in self?.onFormat?(.heading(2)) }
        add("Heading 3", symbol: "textformat.size.smaller") { [weak self] in self?.onFormat?(.heading(3)) }
        menu.addItem(.separator())
        add("Bulleted list", symbol: "list.bullet") { [weak self] in self?.onFormat?(.linePrefix(ListMarker.bullet)) }
        add("Numbered list", symbol: "list.number") { [weak self] in self?.onFormat?(.linePrefix("1. ")) }
        add("Checklist", symbol: "checklist") { [weak self] in self?.onFormat?(.linePrefix(ListMarker.unchecked)) }
        add("Quote", symbol: "text.quote") { [weak self] in self?.onFormat?(.heading(103)) }
        menu.addItem(.separator())
        add("Code block", symbol: "chevron.left.forwardslash.chevron.right") { [weak self] in self?.onBlockAction?(.toggleCode) }
        add("Table", symbol: "tablecells") { [weak self] in self?.onBlockAction?(.insertTable) }
        add("Picture…", symbol: "photo") { [weak self] in self?.onBlockAction?(.insertImage) }
        add("Link to page…", symbol: "link") { [weak self] in self?.onBlockAction?(.linkPage) }

        let glyph = layout.glyphIndexForCharacter(at: slashLocation)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let origin = textContainerOrigin
        menu.popUp(positioning: nil, at: NSPoint(x: origin.x + rect.minX, y: origin.y + rect.maxY + 2), in: self)
    }

    private func superInsertText(_ text: String, replacementRange: NSRange) {
        super.insertText(text, replacementRange: replacementRange)
    }

    // MARK: - Checklist toggling

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, toggleChecklistBox(at: convert(event.locationInWindow, from: nil)) { return }
        super.mouseDown(with: event)
    }

    private func toggleChecklistBox(at point: NSPoint) -> Bool {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return false }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layout.numberOfGlyphs else { return false }
        let box = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard box.contains(local) else { return false }
        let index = layout.characterIndexForGlyph(at: glyph)
        let source = storage.string as NSString
        guard index + 1 < source.length else { return false }
        let character = source.substring(with: NSRange(location: index, length: 2))
        guard character == ListMarker.unchecked || character == ListMarker.checked else { return false }
        let line = source.lineRange(for: NSRange(location: index, length: 0))
        guard source.substring(with: NSRange(location: line.location, length: index - line.location)).allSatisfy({ $0 == " " }) else { return false }

        let snapshot = NSAttributedString(attributedString: storage)
        let selection = selectedRange()
        let nowChecked = character == ListMarker.unchecked
        let boxRange = NSRange(location: index, length: 1)
        let attributes = storage.attributes(at: index, effectiveRange: nil)
        storage.replaceCharacters(in: boxRange, with: NSAttributedString(string: nowChecked ? "☑" : "☐", attributes: attributes))
        var contentEnd = NSMaxRange(line)
        while contentEnd > index + 2, source.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
        let content = NSRange(location: index + 2, length: max(0, contentEnd - (index + 2)))
        if content.length > 0 {
            if nowChecked {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: content)
            } else {
                storage.removeAttribute(.strikethroughStyle, range: content)
                storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: content)
            }
        }
        registerRichTextUndo(snapshot, selection: selection, actionName: "Toggle Checkbox")
        setSelectedRange(selection)
        didChangeText()
        return true
    }

    override func deleteBackward(_ sender: Any?) {
        if deleteSelectedImage?() == true { return }
        // Backspace in an empty block removes the block, so stray empty blocks can be cleared.
        if string.isEmpty, selectedRange().location == 0, selectedRange().length == 0, onBlockAction != nil {
            onBlockAction?(.removeBlock)
            return
        }
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
