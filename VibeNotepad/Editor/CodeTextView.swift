import AppKit
import VibeCore

/// The editor's text view: current-line highlight, smart typing (auto-indent, list
/// continuation, soft tabs, bracket pairing) and file drops.
final class CodeTextView: NSTextView {
    weak var controller: EditorController?

    var lineHighlightColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    var highlightsCurrentLine = true {
        didSet { needsDisplay = true }
    }
    var language: LanguageID = .plainText
    var indentation = Indentation(usesTabs: false, width: 4)
    var autoCloseBrackets = true

    private var nsText: NSString { textStorage?.mutableString ?? "" }

    // MARK: Current line

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard highlightsCurrentLine, selectedRange().length == 0 else { return }
        let lineRect = currentLineRect()
        guard !lineRect.isEmpty, lineRect.intersects(rect) else { return }
        lineHighlightColor.setFill()
        lineRect.intersection(rect).fill(using: .sourceOver)
    }

    /// The full-width rect of the line fragment holding the caret (in view coordinates).
    func currentLineRect() -> NSRect {
        guard let layoutManager, let storage = textStorage else { return .zero }
        let length = storage.length
        let location = min(selectedRange().location, length)
        var rect: NSRect
        if length == 0 || (location == length && storage.mutableString.character(at: length - 1) == 0x0A) {
            rect = layoutManager.extraLineFragmentRect
            if rect.isEmpty, length > 0 {
                let glyph = layoutManager.glyphIndexForCharacter(at: length - 1)
                rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
                rect.origin.y += rect.height
            }
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: location == length ? location - 1 : location)
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
        }
        guard !rect.isEmpty || length == 0 else { return .zero }
        if rect.height == 0 { rect.size.height = controller?.lineHeight ?? 18 }
        rect.origin.x = 0
        rect.size.width = bounds.width
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let old = highlightsCurrentLine ? currentLineRect() : .zero
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard highlightsCurrentLine else { return }
        let new = currentLineRect()
        if old != new {
            setNeedsDisplay(old.insetBy(dx: 0, dy: -2))
            setNeedsDisplay(new.insetBy(dx: 0, dy: -2))
        }
    }

    // MARK: Typing

    override func insertNewline(_ sender: Any?) {
        guard let controller, !hasMarkedText() else {
            super.insertNewline(sender)
            return
        }
        let edit = TextTransforms.newline(nsText, selection: selectedRange(), indentUnit: indentation.unit,
                                          language: language, continueLists: true)
        let insertsAtCaret = edit.range == selectedRange()
            && edit.selection == NSRange(location: edit.range.location + (edit.replacement as NSString).length, length: 0)
        if insertsAtCaret {
            insertText(edit.replacement, replacementRange: edit.range)
        } else {
            controller.apply(edit)
        }
        scrollRangeToVisible(selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0, nsText.substring(with: selection).contains("\n") {
            controller?.indent()
            return
        }
        guard !indentation.usesTabs else {
            super.insertTab(sender)
            return
        }
        let width = indentation.width
        let spaces = width - (visualColumn(at: selection.location) % width)
        insertText(String(repeating: " ", count: spaces), replacementRange: selection)
    }

    override func insertBacktab(_ sender: Any?) {
        controller?.outdent()
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0, selection.location > 0, !hasMarkedText() else {
            super.deleteBackward(sender)
            return
        }
        let text = nsText
        let location = selection.location
        // Remove an auto-inserted pair: (|) → |
        if autoCloseBrackets, location < text.length,
           let close = Self.pairs[Character(UnicodeScalar(text.character(at: location - 1)) ?? " ")],
           text.character(at: location) == close.utf16.first {
            setSelectedRange(NSRange(location: location - 1, length: 2))
            super.deleteBackward(sender)
            return
        }
        // Soft tabs: delete back to the previous tab stop inside leading whitespace.
        if !indentation.usesTabs {
            let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
            let leading = text.substring(with: NSRange(location: lineStart, length: location - lineStart))
            if !leading.isEmpty, leading.allSatisfy({ $0 == " " }) {
                let width = indentation.width
                let remove = leading.count % width == 0 ? min(width, leading.count) : leading.count % width
                if remove > 1 {
                    setSelectedRange(NSRange(location: location - remove, length: remove))
                    super.deleteBackward(sender)
                    return
                }
            }
        }
        super.deleteBackward(sender)
    }

    private static let pairs: [Character: String] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
    private static let closers: Set<Character> = [")", "]", "}", "\"", "'", "`"]
    private static let markdownWrappers: [Character: String] = ["*": "*", "_": "_", "~": "~"]

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard autoCloseBrackets, !hasMarkedText() else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard typed.count == 1, let ch = typed.first else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let selection = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let text = nsText
        let nextChar: Character? = NSMaxRange(selection) < text.length
            ? Character(UnicodeScalar(text.character(at: NSMaxRange(selection))) ?? " ") : nil
        let previousChar: Character? = selection.location > 0
            ? Character(UnicodeScalar(text.character(at: selection.location - 1)) ?? " ") : nil
        let isProse = language == .markdown || language == .plainText

        // Wrap the selection.
        if selection.length > 0 {
            let close = Self.pairs[ch] ?? (language == .markdown ? Self.markdownWrappers[ch] : nil)
            if let close, !(isProse && ch == "'") {
                let inner = text.substring(with: selection)
                super.insertText(String(ch) + inner + close, replacementRange: selection)
                setSelectedRange(NSRange(location: selection.location + 1, length: (inner as NSString).length))
                return
            }
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        // Type over an existing closer.
        if Self.closers.contains(ch), nextChar == ch {
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }

        // Insert a pair.
        if let close = Self.pairs[ch] {
            let isQuote = ch == "\"" || ch == "'" || ch == "`"
            let nextIsFree = nextChar == nil || nextChar!.isWhitespace || Self.closers.contains(nextChar!) || nextChar == "," || nextChar == ";" || nextChar == ":"
            var shouldPair = nextIsFree
            if isQuote {
                let previousIsWord = previousChar.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == ch } ?? false
                shouldPair = nextIsFree && !previousIsWord && !(isProse && ch != "\"") && !(language == .markdown && ch == "`" && previousChar == "`")
            }
            if shouldPair {
                super.insertText(String(ch) + close, replacementRange: selection)
                setSelectedRange(NSRange(location: selection.location + 1, length: 0))
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Column at `location` with tabs expanded.
    func visualColumn(at location: Int) -> Int {
        let text = nsText
        let lineStart = text.lineRange(for: NSRange(location: min(location, text.length), length: 0)).location
        var column = 0
        for i in lineStart..<min(location, text.length) {
            column = text.character(at: i) == 0x09 ? (column / indentation.width + 1) * indentation.width : column + 1
        }
        return column
    }

    // MARK: Pasting

    /// Normalizes pasted line endings so the buffer always uses `\n`.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == .string, let string = pboard.string(forType: .string), string.contains("\r") {
            insertText(TextFileCodec.normalizeLineEndings(string), replacementRange: selectedRange())
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string] + super.readablePasteboardTypes.filter { $0 != .string }
    }

    // MARK: Dropping files

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if !NSEvent.modifierFlags.contains(.option),
           let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !urls.isEmpty {
            Workspace.shared.open(urls: urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    // MARK: Zoom with the trackpad

    override func magnify(with event: NSEvent) {
        let settings = AppSettings.shared
        let delta = event.magnification * 8
        if abs(delta) > 0.01 { settings.fontSize = min(48, max(8, settings.fontSize + delta)) }
    }
}
