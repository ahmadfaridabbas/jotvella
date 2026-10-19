import AppKit

/// An `NSTextView` subclass that adds rich-text undo, image paste/delete hooks,
/// and appearance-safe pasted text colors for the Jotvella editor.
final class JotvellaTextView: NSTextView {
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
