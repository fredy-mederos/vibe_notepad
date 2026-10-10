import Foundation

/// Incremental, line-based syntax state for one document.
///
/// The engine keeps the offset of every line start and the lexer state at the start of
/// every line. After an edit it re-lexes from the first touched line and stops as soon as
/// the state at a line start matches what it was before the edit, so typing usually costs
/// a single line of lexing no matter how large the document is.
///
/// Tokens are not stored: clients ask for the tokens of the lines they want to paint
/// (`enumerateTokens`) and use the `needsStyling`/`markStyled` bookkeeping to only paint
/// lines that changed or scrolled into view.
public final class SyntaxEngine {
    public private(set) var language: LanguageID
    private var lexer: any SyntaxLexer

    /// UTF-16 offset of the first character of each line. Never empty; `lineStarts[0] == 0`.
    public private(set) var lineStarts: [Int] = [0]
    private var states: [LineState]
    private var styled: [Bool] = [false]

    /// Length (UTF-16) of the text the engine is synchronized with.
    public private(set) var textLength = 0

    /// Lines longer than this are left unhighlighted (minified files, data blobs).
    public var maxLineLength = 20_000
    /// Documents larger than this (UTF-16 units) are not highlighted at all.
    public var highlightLimit = 24_000_000
    public private(set) var isHighlightingEnabled = true

    private var scratch: UnsafeMutablePointer<UInt16>
    private var scratchCapacity: Int
    private var tokenBuffer = TokenBuffer()

    public init(language: LanguageID) {
        self.language = language
        self.lexer = language.lexer
        self.states = [language.lexer.initialState]
        self.scratchCapacity = 1024
        self.scratch = .allocate(capacity: 1024)
    }

    deinit {
        scratch.deallocate()
    }

    // MARK: Lines

    public var lineCount: Int { lineStarts.count }

    /// Index of the line containing the UTF-16 `offset` (offsets past the end map to the last line).
    public func lineIndex(containing offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public func lineStart(_ line: Int) -> Int {
        lineStarts[min(max(line, 0), lineStarts.count - 1)]
    }

    /// End of the line's content, excluding the line feed.
    public func lineContentEnd(_ line: Int) -> Int {
        line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : textLength
    }

    /// The line's range including its line feed.
    public func lineRange(_ line: Int) -> NSRange {
        let s = lineStart(line)
        let e = line + 1 < lineStarts.count ? lineStarts[line + 1] : textLength
        return NSRange(location: s, length: max(0, e - s))
    }

    /// Range covering `lines` including the final line feed.
    public func characterRange(lines: Range<Int>) -> NSRange {
        guard !lines.isEmpty else { return NSRange(location: lineStart(lines.lowerBound), length: 0) }
        let s = lineStart(lines.lowerBound)
        let last = min(lines.upperBound, lineStarts.count)
        let e = last < lineStarts.count ? lineStarts[last] : textLength
        return NSRange(location: s, length: max(0, e - s))
    }

    /// Lines intersecting `range`.
    public func lines(intersecting range: NSRange) -> Range<Int> {
        let first = lineIndex(containing: range.location)
        let last = lineIndex(containing: max(range.location, range.location + range.length))
        return first..<(last + 1)
    }

    /// Whether some line is longer than `maxLineLength` and so is left unhighlighted.
    public var hasOverlongLines: Bool {
        var start = 0
        for next in lineStarts.dropFirst() {
            if next - 1 - start > maxLineLength { return true }
            start = next
        }
        return textLength - start > maxLineLength
    }

    // MARK: Synchronization

    /// Re-reads the whole text (initial load, language change, external replacement).
    public func reset(text: NSString, language: LanguageID? = nil) {
        if let language {
            self.language = language
            self.lexer = language.lexer
        }
        textLength = text.length
        isHighlightingEnabled = textLength <= highlightLimit && self.language != .plainText
        lineStarts = Self.computeLineStarts(text, scratch: &scratch, capacity: &scratchCapacity)
        styled = Array(repeating: false, count: lineStarts.count)
        let initial = lexer.initialState
        guard isHighlightingEnabled else {
            states = Array(repeating: initial, count: lineStarts.count)
            return
        }
        states = []
        states.reserveCapacity(lineStarts.count)
        var state = initial
        for line in 0..<lineStarts.count {
            states.append(state)
            lexLine(line, text: text, state: &state)
        }
    }

    /// Changes the language and re-lexes.
    public func setLanguage(_ language: LanguageID, text: NSString) {
        reset(text: text, language: language)
    }

    /// Updates bookkeeping after an edit and re-lexes until line states converge.
    ///
    /// - Parameters:
    ///   - editedRange: The edited range in the *new* text (as reported by `NSTextStorage`).
    ///   - delta: The change in length.
    /// - Returns: The lines whose tokens may have changed (they are also marked as needing styling).
    @discardableResult
    public func applyEdit(text: NSString, editedRange: NSRange, changeInLength delta: Int) -> Range<Int> {
        let newLength = text.length
        let editStart = editedRange.location
        let newEditEnd = editedRange.location + editedRange.length
        let oldEditEnd = newEditEnd - delta
        guard textLength + delta == newLength, editStart >= 0, editStart <= oldEditEnd, oldEditEnd <= textLength, newEditEnd <= newLength else {
            reset(text: text)
            return 0..<lineCount
        }

        let firstLine = lineIndex(containing: editStart)
        let lastOldLine = lineIndex(containing: oldEditEnd)

        // Line starts introduced by the inserted text.
        var newStarts: [Int] = []
        if newEditEnd > editStart {
            var position = editStart
            let chunk = 16_384
            while position < newEditEnd {
                let count = min(chunk, newEditEnd - position)
                ensureScratch(count)
                text.getCharacters(scratch, range: NSRange(location: position, length: count))
                for k in 0..<count where scratch[k] == Ch.newline {
                    newStarts.append(position + k + 1)
                }
                position += count
            }
        }

        let removed = (firstLine + 1)..<(lastOldLine + 1)
        lineStarts.replaceSubrange(removed, with: newStarts)
        states.replaceSubrange(removed, with: repeatElement(LineState(), count: newStarts.count))
        styled.replaceSubrange(removed, with: repeatElement(false, count: newStarts.count))
        if delta != 0 {
            var i = firstLine + 1 + newStarts.count
            while i < lineStarts.count {
                lineStarts[i] += delta
                i += 1
            }
        }
        textLength = newLength

        let lastEditedLine = firstLine + newStarts.count
        let shouldHighlight = textLength <= highlightLimit && language != .plainText
        if shouldHighlight != isHighlightingEnabled {
            reset(text: text)
            return 0..<lineCount
        }
        guard isHighlightingEnabled else {
            for i in firstLine...lastEditedLine { styled[i] = false }
            return firstLine..<(lastEditedLine + 1)
        }

        var line = firstLine
        var state = states[firstLine]
        while true {
            lexLine(line, text: text, state: &state)
            styled[line] = false
            let next = line + 1
            if next >= lineStarts.count { break }
            if next > lastEditedLine, states[next] == state { break }
            states[next] = state
            line = next
        }
        return firstLine..<(line + 1)
    }

    // MARK: Styling bookkeeping

    public func needsStyling(_ line: Int) -> Bool {
        line >= 0 && line < styled.count && !styled[line]
    }

    public func markStyled(_ lines: Range<Int>) {
        let lo = max(0, lines.lowerBound), hi = min(styled.count, lines.upperBound)
        guard lo < hi else { return }
        for i in lo..<hi { styled[i] = true }
    }

    /// Forces every line to be repainted (theme or font changes).
    public func invalidateStyling() {
        for i in styled.indices { styled[i] = false }
    }

    /// Contiguous runs of lines in `lines` that still need styling.
    public func unstyledRuns(in lines: Range<Int>) -> [Range<Int>] {
        let lo = max(0, lines.lowerBound), hi = min(styled.count, lines.upperBound)
        guard lo < hi else { return [] }
        var runs: [Range<Int>] = []
        var runStart: Int?
        for i in lo..<hi {
            if !styled[i] {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                runs.append(s..<i)
                runStart = nil
            }
        }
        if let s = runStart { runs.append(s..<hi) }
        return runs
    }

    // MARK: Tokens

    /// Calls `body` with the absolute range and kind of every token on `lines`, in order.
    public func enumerateTokens(lines: Range<Int>, text: NSString, _ body: (NSRange, TokenKind) -> Void) {
        guard isHighlightingEnabled else { return }
        let lo = max(0, lines.lowerBound), hi = min(lineStarts.count, lines.upperBound)
        guard lo < hi else { return }
        for line in lo..<hi {
            var state = states[line]
            lexLine(line, text: text, state: &state)
            let base = lineStarts[line]
            let length = lineContentEnd(line) - base
            for token in tokenBuffer.tokens {
                let s = max(0, token.start), e = min(length, token.start + token.length)
                if e > s { body(NSRange(location: base + s, length: e - s), token.kind) }
            }
        }
    }

    /// The lexer state at the start of `line` (used for context-aware editing, e.g. comments).
    public func state(atLine line: Int) -> LineState {
        states[min(max(line, 0), states.count - 1)]
    }

    // MARK: Internals

    private func lexLine(_ line: Int, text: NSString, state: inout LineState) {
        tokenBuffer.removeAll()
        let start = lineStarts[line]
        let length = lineContentEnd(line) - start
        guard length >= 0, length <= maxLineLength else { return }
        ensureScratch(length)
        if length > 0 {
            text.getCharacters(scratch, range: NSRange(location: start, length: length))
        }
        lexer.lex(LineBuffer(base: scratch, start: 0, end: length), state: &state, tokens: &tokenBuffer)
    }

    private func ensureScratch(_ count: Int) {
        guard count > scratchCapacity else { return }
        scratch.deallocate()
        scratchCapacity = max(count, scratchCapacity * 2)
        scratch = .allocate(capacity: scratchCapacity)
    }

    private static func computeLineStarts(_ text: NSString, scratch: inout UnsafeMutablePointer<UInt16>, capacity: inout Int) -> [Int] {
        var starts = [0]
        let length = text.length
        let chunk = 65_536
        if capacity < chunk {
            scratch.deallocate()
            capacity = chunk
            scratch = .allocate(capacity: chunk)
        }
        var position = 0
        while position < length {
            let count = min(chunk, length - position)
            text.getCharacters(scratch, range: NSRange(location: position, length: count))
            for k in 0..<count where scratch[k] == Ch.newline {
                starts.append(position + k + 1)
            }
            position += count
        }
        return starts
    }
}

// MARK: - One-shot helpers

public enum SyntaxHighlighter {
    /// Tokens for every line of `text` (offsets relative to each line). Handy for tests and previews.
    public static func tokenize(_ text: String, language: LanguageID) -> [[Token]] {
        let units = Array(text.utf16)
        let lexer = language.lexer
        var state = lexer.initialState
        var result: [[Token]] = []
        var buffer = TokenBuffer()
        units.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress ?? UnsafePointer<UInt16>(bitPattern: 1) else { return }
            var lineStart = 0
            var i = 0
            while i <= units.count {
                if i == units.count || units[i] == Ch.newline {
                    buffer.removeAll()
                    if i - lineStart <= 20_000 {
                        let line = LineBuffer(base: base, start: lineStart, end: i)
                        lexer.lex(line, state: &state, tokens: &buffer)
                    }
                    result.append(buffer.tokens.map { Token(start: $0.start - lineStart, length: $0.length, kind: $0.kind) })
                    lineStart = i + 1
                }
                i += 1
            }
        }
        return result
    }

    /// HTML for a code block: escaped text with `<span class="tk-…">` around tokens.
    public static func html(_ code: String, language: LanguageID) -> String {
        let units = Array(code.utf16)
        let lexer = language.lexer
        var state = lexer.initialState
        var out = String()
        out.reserveCapacity(units.count * 2)
        var buffer = TokenBuffer()
        var kinds: [TokenKind] = []
        units.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress ?? UnsafePointer<UInt16>(bitPattern: 1) else { return }
            var lineStart = 0
            var i = 0
            while i <= units.count {
                guard i == units.count || units[i] == Ch.newline else { i += 1; continue }
                let lineLength = i - lineStart
                buffer.removeAll()
                if lineLength <= 20_000 {
                    lexer.lex(LineBuffer(base: base, start: lineStart, end: i), state: &state, tokens: &buffer)
                }
                // Later tokens win where tokens overlap.
                kinds.removeAll(keepingCapacity: true)
                kinds.append(contentsOf: repeatElement(.plain, count: lineLength))
                for t in buffer.tokens {
                    let s = max(0, t.start - lineStart), e = min(lineLength, t.start - lineStart + t.length)
                    if e > s { for k in s..<e { kinds[k] = t.kind } }
                }
                var runStart = 0
                while runStart < lineLength {
                    let kind = kinds[runStart]
                    var runEnd = runStart + 1
                    while runEnd < lineLength, kinds[runEnd] == kind { runEnd += 1 }
                    let piece = String(decoding: UnsafeBufferPointer(start: base + lineStart + runStart, count: runEnd - runStart), as: UTF16.self)
                    if kind == .plain {
                        out += escapeHTML(piece)
                    } else {
                        out += "<span class=\"\(kind.cssClass)\">"
                        out += escapeHTML(piece)
                        out += "</span>"
                    }
                    runStart = runEnd
                }
                if i < units.count { out += "\n" }
                lineStart = i + 1
                i += 1
            }
        }
        return out
    }

    public static func escapeHTML(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
