import Foundation

/// YAML: keys, scalars by type, anchors/aliases/tags, block scalars (`|`, `>`), flow collections.
public struct YAMLLexer: SyntaxLexer {
    public init() {}

    private enum Mode {
        static let normal: UInt8 = 0
        /// Inside a `|`/`>` block scalar; `data` holds the indentation of the owning line.
        static let blockScalar: UInt8 = 1
        static let doubleQuoted: UInt8 = 2
        static let singleQuoted: UInt8 = 3
    }

    private static let constants: Set<String> = [
        "true", "false", "True", "False", "TRUE", "FALSE", "yes", "no", "Yes", "No", "YES", "NO",
        "on", "off", "On", "Off", "ON", "OFF", "null", "Null", "NULL", "~",
    ]
    private static let specialFloats: Set<String> = [".inf", ".Inf", ".INF", "-.inf", "+.inf", "-.Inf", "+.Inf", ".nan", ".NaN", ".NAN"]

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        let first = line.firstNonSpace
        let indent = first - line.start

        switch state.main.mode {
        case Mode.blockScalar:
            if first >= line.end { return } // blank lines belong to the scalar
            if indent > Int(state.main.data) {
                tokens.add(first, line.end, .string)
                return
            }
            state.main = .initial
        case Mode.doubleQuoted, Mode.singleQuoted:
            let quote = state.main.mode == Mode.doubleQuoted ? Ch.quote : Ch.apostrophe
            if let end = scanQuoted(line, from: line.start, tokenStart: line.start, quote: quote, tokens: &tokens) {
                state.main = .initial
                lexAfterValue(line, from: end, tokens: &tokens)
            }
            return
        default:
            break
        }

        guard first < line.end else { return }
        var i = first

        if line[i] == Ch.hash {
            tokens.add(i, line.end, .comment)
            return
        }
        // Directives and document markers.
        if indent == 0, line[i] == Ch.percent {
            tokens.add(i, line.end, .meta)
            return
        }
        if indent == 0, (line.matches(u16("---"), at: i) || line.matches(u16("..."), at: i)), Ch.isSpace(line[i + 3]) || i + 3 >= line.end {
            tokens.add(i, i + 3, .meta)
            i = line.skipSpaces(i + 3)
            if i >= line.end { return }
        }

        // Sequence entries (`- `, possibly nested `- - `).
        var ownerIndent = indent
        while line[i] == Ch.minus, Ch.isSpace(line[i + 1]) || i + 1 >= line.end {
            tokens.add(i, i + 1, .punctuation)
            ownerIndent = i - line.start
            i = line.skipSpaces(i + 1)
        }
        if i >= line.end { return }
        if line[i] == Ch.hash {
            tokens.add(i, line.end, .comment)
            return
        }
        // Complex key indicator.
        if line[i] == Ch.question, Ch.isSpace(line[i + 1]) {
            tokens.add(i, i + 1, .punctuation)
            i = line.skipSpaces(i + 1)
        }

        // Mapping key.
        if let (keyEnd, colon) = findKey(line, from: i) {
            tokens.add(i, keyEnd, .property)
            tokens.add(colon, colon + 1, .punctuation)
            i = line.skipSpaces(colon + 1)
        }
        lexValue(line, from: i, ownerIndent: ownerIndent, state: &state, tokens: &tokens)
    }

    // MARK: Keys

    /// If a mapping key starts at `i`, returns the end of the key and the index of its `:`.
    private func findKey(_ line: LineBuffer, from i: Int) -> (Int, Int)? {
        let c = line[i]
        if c == Ch.quote || c == Ch.apostrophe {
            var j = i + 1
            while j < line.end {
                if line[j] == Ch.backslash, c == Ch.quote { j += 2; continue }
                if line[j] == c {
                    if c == Ch.apostrophe, line[j + 1] == Ch.apostrophe { j += 2; continue }
                    break
                }
                j += 1
            }
            let after = line.skipSpaces(j + 1)
            if j < line.end, line[after] == Ch.colon, Ch.isSpace(line[after + 1]) || after + 1 >= line.end {
                return (j + 1, after)
            }
            return nil
        }
        // Plain keys can't start with indicators.
        switch c {
        case Ch.lbracket, Ch.lbrace, Ch.rbracket, Ch.rbrace, Ch.comma, Ch.hash, Ch.amp, Ch.star, Ch.bang,
             Ch.pipe, Ch.gt, Ch.percent, Ch.at, Ch.backtick:
            return nil
        default:
            break
        }
        var j = i
        while j < line.end {
            let d = line[j]
            if d == Ch.colon, Ch.isSpace(line[j + 1]) || j + 1 >= line.end {
                var keyEnd = j
                while keyEnd > i, Ch.isSpace(line[keyEnd - 1]) { keyEnd -= 1 }
                return keyEnd > i ? (keyEnd, j) : nil
            }
            if d == Ch.hash, j > i, Ch.isSpace(line[j - 1]) { return nil }
            j += 1
        }
        return nil
    }

    // MARK: Values

    private func lexValue(_ line: LineBuffer, from start: Int, ownerIndent: Int, state: inout LineState, tokens: inout TokenBuffer) {
        var i = start
        // Node properties: anchors, aliases and tags may precede the value.
        while i < line.end {
            let c = line[i]
            if c == Ch.amp || c == Ch.star, i + 1 < line.end, !Ch.isSpace(line[i + 1]) {
                let end = scanUntilSpace(line, from: i)
                tokens.add(i, end, .variable)
                i = line.skipSpaces(end)
            } else if c == Ch.bang {
                let end = scanUntilSpace(line, from: i)
                tokens.add(i, end, .type)
                i = line.skipSpaces(end)
            } else {
                break
            }
        }
        guard i < line.end else { return }
        let c = line[i]

        switch c {
        case Ch.hash:
            tokens.add(i, line.end, .comment)
        case Ch.pipe, Ch.gt:
            // Block scalar header: |, >, |-, >+, |2 …
            var j = i + 1
            while j < line.end, line[j] == Ch.minus || line[j] == Ch.plus || Ch.isDigit(line[j]) { j += 1 }
            tokens.add(i, j, .operator)
            lexAfterValue(line, from: j, tokens: &tokens)
            state.main = LexState(mode: Mode.blockScalar, data: Int32(ownerIndent))
        case Ch.quote, Ch.apostrophe:
            if let end = scanQuoted(line, from: i + 1, tokenStart: i, quote: c, tokens: &tokens) {
                lexAfterValue(line, from: end, tokens: &tokens)
            } else {
                state.main = LexState(mode: c == Ch.quote ? Mode.doubleQuoted : Mode.singleQuoted)
            }
        case Ch.lbracket, Ch.lbrace:
            lexFlow(line, from: i, tokens: &tokens)
        default:
            lexPlainScalar(line, from: i, tokens: &tokens)
        }
    }

    /// A plain scalar runs to the end of the line or an inline comment.
    private func lexPlainScalar(_ line: LineBuffer, from i: Int, tokens: inout TokenBuffer) {
        var end = i
        while end < line.end {
            if line[end] == Ch.hash, end > i, Ch.isSpace(line[end - 1]) { break }
            end += 1
        }
        var valueEnd = end
        while valueEnd > i, Ch.isSpace(line[valueEnd - 1]) { valueEnd -= 1 }
        tokens.add(i, valueEnd, classifyScalar(line, i, valueEnd))
        if end < line.end { tokens.add(end, line.end, .comment) }
    }

    private func classifyScalar(_ line: LineBuffer, _ s: Int, _ e: Int) -> TokenKind {
        guard e > s else { return .plain }
        if e - s <= 5 {
            let word = line.string(s, e)
            if Self.constants.contains(word) { return .constant }
            if Self.specialFloats.contains(word) { return .number }
        }
        if looksNumeric(line, s, e) { return .number }
        return .string
    }

    /// Integers, floats, hex/octal, and dates/timestamps (2024-01-31, 2024-01-31T10:00:00Z).
    private func looksNumeric(_ line: LineBuffer, _ s: Int, _ e: Int) -> Bool {
        var j = s
        if line[j] == Ch.minus || line[j] == Ch.plus { j += 1 }
        guard j < e, Ch.isDigit(line[j]) || (line[j] == Ch.dot && Ch.isDigit(line[j + 1])) else { return false }
        if line[j] == Ch.zero, Ch.lower(line[j + 1]) == Ch.x || Ch.lower(line[j + 1]) == Ch.o {
            j += 2
            while j < e, Ch.isHexDigit(line[j]) || line[j] == Ch.underscore { j += 1 }
            return j == e
        }
        var sawSeparator = false
        var dots = 0
        while j < e {
            let c = line[j]
            if c == Ch.dot {
                dots += 1
                j += 1
            } else if Ch.isDigit(c) || c == Ch.underscore {
                j += 1
            } else if c == Ch.e || c == 0x45, j + 1 < e, Ch.isDigit(line[j + 1]) || line[j + 1] == Ch.minus || line[j + 1] == Ch.plus {
                j += 2
            } else if c == Ch.minus || c == Ch.colon || c == 0x54 /* T */ || c == 0x74 || c == Ch.space || c == Ch.plus || c == 0x5A /* Z */ {
                // Dates and times.
                sawSeparator = true
                j += 1
            } else {
                return false
            }
        }
        if sawSeparator {
            // Require a date-like shape so "1-2-3 go" or version ranges stay strings.
            let text = line.string(s, e)
            return text.range(of: #"^\d{4}-\d{2}-\d{2}([Tt ]\d{1,2}:\d{2}(:\d{2}(\.\d+)?)?\s*(Z|[+-]\d{1,2}(:\d{2})?)?)?$|^\d{1,2}:\d{2}(:\d{2}(\.\d+)?)?$"#, options: .regularExpression) != nil
        }
        return dots <= 1
    }

    /// Flow collections on a single line: `[a, b]`, `{ key: value }`.
    private func lexFlow(_ line: LineBuffer, from start: Int, tokens: inout TokenBuffer) {
        var i = start
        while i < line.end {
            let c = line[i]
            if Ch.isSpace(c) { i += 1; continue }
            switch c {
            case Ch.lbracket, Ch.rbracket, Ch.lbrace, Ch.rbrace, Ch.comma:
                tokens.add(i, i + 1, .punctuation)
                i += 1
            case Ch.hash where i > start && Ch.isSpace(line[i - 1]):
                tokens.add(i, line.end, .comment)
                return
            case Ch.quote, Ch.apostrophe:
                let end = scanQuoted(line, from: i + 1, tokenStart: i, quote: c, tokens: &tokens) ?? line.end
                let after = line.skipSpaces(end)
                if line[after] == Ch.colon {
                    tokens.removeTokens(from: i)
                    tokens.add(i, end, .property)
                }
                i = end
            case Ch.colon:
                tokens.add(i, i + 1, .punctuation)
                i += 1
            case Ch.amp, Ch.star:
                let end = scanFlowWord(line, from: i)
                tokens.add(i, end, .variable)
                i = end
            case Ch.bang:
                let end = scanFlowWord(line, from: i)
                tokens.add(i, end, .type)
                i = end
            default:
                let end = scanFlowWord(line, from: i)
                var valueEnd = end
                while valueEnd > i, Ch.isSpace(line[valueEnd - 1]) { valueEnd -= 1 }
                if line[end] == Ch.colon {
                    tokens.add(i, valueEnd, .property)
                } else {
                    tokens.add(i, valueEnd, classifyScalar(line, i, valueEnd))
                }
                i = max(end, i + 1)
            }
        }
    }

    private func scanFlowWord(_ line: LineBuffer, from i: Int) -> Int {
        var j = i
        while j < line.end {
            let c = line[j]
            if c == Ch.comma || c == Ch.rbracket || c == Ch.rbrace || c == Ch.lbracket || c == Ch.lbrace { break }
            if c == Ch.colon, Ch.isSpace(line[j + 1]) || line[j + 1] == Ch.comma || line[j + 1] == Ch.rbrace || j + 1 >= line.end { break }
            if c == Ch.hash, j > i, Ch.isSpace(line[j - 1]) { break }
            j += 1
        }
        return j
    }

    private func scanUntilSpace(_ line: LineBuffer, from i: Int) -> Int {
        var j = i
        while j < line.end, !Ch.isSpace(line[j]) { j += 1 }
        return j
    }

    private func lexAfterValue(_ line: LineBuffer, from i: Int, tokens: inout TokenBuffer) {
        let j = line.skipSpaces(i)
        if line[j] == Ch.hash { tokens.add(j, line.end, .comment) }
    }

    /// Returns the index after the closing quote, or nil if the scalar continues on the next line.
    private func scanQuoted(_ line: LineBuffer, from start: Int, tokenStart: Int, quote: UInt16, tokens: inout TokenBuffer) -> Int? {
        var segment = tokenStart
        var j = start
        while j < line.end {
            let c = line[j]
            if quote == Ch.quote, c == Ch.backslash {
                tokens.add(segment, j, .string)
                tokens.add(j, min(j + 2, line.end), .escape)
                j += 2
                segment = j
                continue
            }
            if c == quote {
                if quote == Ch.apostrophe, line[j + 1] == Ch.apostrophe {
                    j += 2
                    continue
                }
                tokens.add(segment, j + 1, .string)
                return j + 1
            }
            j += 1
        }
        tokens.add(segment, line.end, .string)
        return nil
    }
}
