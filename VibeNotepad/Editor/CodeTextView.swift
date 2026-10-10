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

    private var editorLayout: EditorLayoutManager? { layoutManager as? EditorLayoutManager }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var ranges = ranges
        // Carets and selection edges can't sit inside folded text: skip over the fold.
        if ranges.count == 1, let layout = editorLayout, !layout.foldSpans.isEmpty {
            ranges = [NSValue(range: outsideFolds(ranges[0].rangeValue, from: selectedRange(), layout: layout))]
        }
        let old = highlightsCurrentLine ? currentLineRect() : .zero
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard highlightsCurrentLine else { return }
        let new = currentLineRect()
        if old != new {
            setNeedsDisplay(old.insetBy(dx: 0, dy: -2))
            setNeedsDisplay(new.insetBy(dx: 0, dy: -2))
        }
    }

    /// `range` with its ends moved out of folded text, in the direction they were moving.
    func outsideFolds(_ range: NSRange, from old: NSRange, layout: EditorLayoutManager) -> NSRange {
        func visible(_ index: Int, forward: Bool) -> Int {
            guard let span = layout.spanHidingCaret(at: index) else { return index }
            return forward && !span.hidesToEnd ? NSMaxRange(span.hidden) : span.lineEnd
        }
        if range.length == 0 {
            let location = visible(range.location, forward: range.location > old.location)
            return NSRange(location: location, length: 0)
        }
        let start = visible(range.location, forward: range.location > old.location)
        let end = max(start, visible(NSMaxRange(range), forward: NSMaxRange(range) >= NSMaxRange(old)))
        return NSRange(location: start, length: end - start)
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

    /// ⇧↩ would insert a Unicode line separator (U+2028), which code files don't want.
    override func insertLineBreak(_ sender: Any?) {
        insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0, nsText.substring(with: selection).contains("\n") {
            controller?.indent()
            return
        }
        // Makefile recipes must be indented with real tabs.
        guard !indentation.usesTabs, language != .makefile else {
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
        // Backspacing into a fold unfolds it instead of deleting hidden text.
        if selection.length == 0, selection.location > 0, let span = editorLayout?.hiddenSpan(at: selection.location - 1) {
            controller?.unfold(range: span.fold)
            return
        }
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
            var start = location
            while start > 0, text.character(at: start - 1) == 0x20 { start -= 1 }
            let spaces = location - start
            if spaces > 1, start == 0 || text.character(at: start - 1) == 0x0A {
                let width = indentation.width
                let remove = spaces % width == 0 ? min(width, spaces) : spaces % width
                if remove > 1 {
                    setSelectedRange(NSRange(location: location - remove, length: remove))
                    super.deleteBackward(sender)
                    return
                }
            }
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, let span = editorLayout?.span(endingLineAt: selection.location) {
            controller?.unfold(range: span.fold)
            return
        }
        super.deleteForward(sender)
    }

    // MARK: Folding

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let document = controller?.document { Workspace.shared.documentDidTakeFocus(document) }
        return became
    }

    override func mouseDown(with event: NSEvent) {
        if let layout = editorLayout, !layout.foldSpans.isEmpty, let span = foldPill(at: event, layout: layout) {
            controller?.unfold(range: span.fold)
            return
        }
        super.mouseDown(with: event)
    }

    /// The fold whose `⋯` pill (or closing preview) is under the mouse.
    private func foldPill(at event: NSEvent, layout: EditorLayoutManager) -> FoldSpan? {
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let text = nsText
        let index = min(characterIndexForInsertion(at: point), text.length)
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
        guard let span = layout.span(endingLineAt: contentsEnd), let hit = layout.foldHitRect(for: span),
              hit.insetBy(dx: -3, dy: -3).contains(containerPoint) else { return nil }
        return span
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
        let location = min(location, text.length)
        var lineStart: Int
        if let engine = controller?.engine, engine.textLength == text.length {
            lineStart = engine.lineStart(engine.lineIndex(containing: location))
        } else {
            lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        }
        // Only the position relative to tab stops matters; on huge lines the tail is enough.
        lineStart = max(lineStart, location - 4096)
        var column = 0
        for i in lineStart..<location {
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
