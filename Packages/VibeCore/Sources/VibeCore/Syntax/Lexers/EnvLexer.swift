import Foundation

/// `.env` files: `KEY=value`, `export KEY="value with ${INTERPOLATION}"`, comments.
///
/// Keys are properties, `=` an operator, values strings (with numbers/booleans picked out),
/// `${VAR}`/`$VAR` references variables — similar to Sublime's DotENV highlighting.
public struct EnvLexer: SyntaxLexer {
    public init() {}

    private enum Mode {
        static let normal: UInt8 = 0
        /// Inside a multi-line double-quoted value.
        static let doubleQuoted: UInt8 = 1
        /// Inside a multi-line single-quoted value.
        static let singleQuoted: UInt8 = 2
    }

    private static let export = u16("export")
    private static let constants: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "nil", "none", "TRUE", "FALSE", "True", "False", "YES", "NO"]

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        var i = line.start
        switch state.main.mode {
        case Mode.doubleQuoted:
            if let end = scanQuoted(line, from: i, tokenStart: i, quote: Ch.quote, tokens: &tokens) {
                state.main = .initial
                i = end
                lexTrailing(line, from: i, tokens: &tokens)
            }
            return
        case Mode.singleQuoted:
            if let end = scanQuoted(line, from: i, tokenStart: i, quote: Ch.apostrophe, tokens: &tokens) {
                state.main = .initial
                i = end
                lexTrailing(line, from: i, tokens: &tokens)
            }
            return
        default:
            break
        }

        i = line.firstNonSpace
        guard i < line.end else { return }
        if line[i] == Ch.hash {
            tokens.add(i, line.end, .comment)
            return
        }

        if line.matches(Self.export, at: i), Ch.isSpace(line[i + Self.export.count]) {
            tokens.add(i, i + Self.export.count, .keyword)
            i = line.skipSpaces(i + Self.export.count)
        }

        // Key
        let keyStart = i
        while i < line.end, line[i] != Ch.equals, line[i] != Ch.colon || line[i + 1] != Ch.space, !Ch.isSpace(line[i]) { i += 1 }
        let keyEnd = i
        i = line.skipSpaces(i)
        guard i < line.end, line[i] == Ch.equals || line[i] == Ch.colon else {
            // Not an assignment: `export KEY` or junk. Color the word as a key anyway.
            tokens.add(keyStart, keyEnd, keyEnd > keyStart ? .property : .plain)
            if i < line.end, line[i] == Ch.hash { tokens.add(i, line.end, .comment) }
            return
        }
        tokens.add(keyStart, keyEnd, .property)
        tokens.add(i, i + 1, .operator)
        i = line.skipSpaces(i + 1)
        guard i < line.end else { return }

        // Value
        let c = line[i]
        if c == Ch.quote || c == Ch.apostrophe || c == Ch.backtick {
            if let end = scanQuoted(line, from: i + 1, tokenStart: i, quote: c, tokens: &tokens) {
                lexTrailing(line, from: end, tokens: &tokens)
            } else if c != Ch.backtick {
                state.main = LexState(mode: c == Ch.quote ? Mode.doubleQuoted : Mode.singleQuoted)
            }
            return
        }
        lexUnquoted(line, from: i, tokens: &tokens)
    }

    /// Unquoted value: runs until an inline comment (` #`).
    private func lexUnquoted(_ line: LineBuffer, from start: Int, tokens: inout TokenBuffer) {
        var end = start
        while end < line.end {
            if line[end] == Ch.hash, end > start, Ch.isSpace(line[end - 1]) { break }
            end += 1
        }
        var valueEnd = end
        while valueEnd > start, Ch.isSpace(line[valueEnd - 1]) { valueEnd -= 1 }

        let word = line.string(start, valueEnd)
        if Self.constants.contains(word) {
            tokens.add(start, valueEnd, .constant)
        } else if isNumber(line, start, valueEnd) {
            tokens.add(start, valueEnd, .number)
        } else {
            emitWithInterpolation(line, start, valueEnd, kind: .string, tokens: &tokens)
        }
        if end < line.end { tokens.add(end, line.end, .comment) }
    }

    /// After a closing quote: only an inline comment is meaningful.
    private func lexTrailing(_ line: LineBuffer, from i: Int, tokens: inout TokenBuffer) {
        let j = line.skipSpaces(i)
        if line[j] == Ch.hash { tokens.add(j, line.end, .comment) }
    }

    /// Scans a quoted value starting at `from` (just after the opening quote). Returns the index
    /// after the closing quote, or nil when the line ends inside the value.
    private func scanQuoted(_ line: LineBuffer, from: Int, tokenStart: Int, quote: UInt16, tokens: inout TokenBuffer) -> Int? {
        var segment = tokenStart
        var j = from
        let interpolates = quote != Ch.apostrophe
        while j < line.end {
            let c = line[j]
            if c == Ch.backslash, quote != Ch.apostrophe {
                tokens.add(segment, j, .string)
                tokens.add(j, min(j + 2, line.end), .escape)
                j += 2
                segment = j
                continue
            }
            if c == quote {
                tokens.add(segment, j + 1, .string)
                return j + 1
            }
            if interpolates, c == Ch.dollar, let end = variableEnd(line, at: j) {
                tokens.add(segment, j, .string)
                tokens.add(j, end, .variable)
                j = end
                segment = j
                continue
            }
            j += 1
        }
        tokens.add(segment, line.end, .string)
        return nil
    }

    private func emitWithInterpolation(_ line: LineBuffer, _ s: Int, _ e: Int, kind: TokenKind, tokens: inout TokenBuffer) {
        var segment = s
        var j = s
        while j < e {
            if line[j] == Ch.dollar, let end = variableEnd(line, at: j) {
                tokens.add(segment, j, kind)
                tokens.add(j, min(end, e), .variable)
                j = min(end, e)
                segment = j
                continue
            }
            j += 1
        }
        tokens.add(segment, e, kind)
    }

    /// End of `$NAME` or `${…}` starting at `i`.
    private func variableEnd(_ line: LineBuffer, at i: Int) -> Int? {
        let n = line[i + 1]
        if n == Ch.lbrace {
            if let close = line.find(Ch.rbrace, from: i + 2) { return close + 1 }
            return nil
        }
        if Ch.isIdentStart(n) { return line.scanIdentifier(i + 1) }
        return nil
    }

    private func isNumber(_ line: LineBuffer, _ s: Int, _ e: Int) -> Bool {
        guard e > s else { return false }
        var j = s
        if line[j] == Ch.minus || line[j] == Ch.plus { j += 1 }
        guard j < e, Ch.isDigit(line[j]) else { return false }
        var dots = 0
        while j < e {
            let c = line[j]
            if c == Ch.dot { dots += 1 } else if !Ch.isDigit(c) && c != Ch.underscore { return false }
            j += 1
        }
        return dots <= 1
    }
}
