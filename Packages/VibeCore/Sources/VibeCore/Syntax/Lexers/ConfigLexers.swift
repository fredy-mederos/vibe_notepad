import Foundation

// MARK: - INI

/// INI-style files: `.ini`, `.cfg`, `.gitconfig`, `.editorconfig`, `.npmrc`, systemd units, `.desktop`…
///
/// State: `mode == 1` after `key =` with an empty value, where the indented lines that follow are
/// the value (setup.cfg `install_requires =` lists). A non-indented or blank line ends it.
public struct INILexer: SyntaxLexer {
    public init() {}

    enum Mode {
        static let normal: UInt8 = 0
        static let multilineValue: UInt8 = 1
    }

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        let first = line.firstNonSpace
        let end = line.trimmedEnd
        guard first < end else {
            state.main = .initial
            return
        }
        let c = line[first]
        if c == Ch.semicolon || c == Ch.hash {
            // Whole-line comments keep a multi-line value going.
            tokens.add(first, end, .comment)
            return
        }
        let inMultiline = state.main.mode == Mode.multilineValue && first > line.start
        if inMultiline, separator(line, from: first, to: end, strict: true) == nil {
            lexValue(line, from: first, to: end, tokens: &tokens)
            return
        }
        state.main = .initial
        if c == Ch.lbracket {
            lexSection(line, from: first, to: end, tokens: &tokens)
            return
        }
        guard let sep = separator(line, from: first, to: end, strict: false) else {
            // A bare key (`skip-name-resolve`), possibly followed by an inline comment.
            let commentStart = inlineComment(line, from: first, to: end) ?? end
            var keyEnd = commentStart
            while keyEnd > first, Ch.isSpace(line[keyEnd - 1]) { keyEnd -= 1 }
            tokens.add(first, keyEnd, .property)
            tokens.add(commentStart, end, .comment)
            return
        }
        var keyEnd = sep.start
        while keyEnd > first, Ch.isSpace(line[keyEnd - 1]) { keyEnd -= 1 }
        tokens.add(first, keyEnd, .property)
        tokens.add(sep.start, sep.end, .operator)
        let valueStart = line.skipSpaces(sep.end)
        if valueStart >= end {
            state.main.mode = Mode.multilineValue
        } else {
            lexValue(line, from: valueStart, to: end, tokens: &tokens)
            if inMultiline { state.main.mode = Mode.multilineValue }
        }
    }

    /// `[section]`, `[section.sub]`, `[remote "origin"]`.
    private func lexSection(_ line: LineBuffer, from i: Int, to end: Int, tokens: inout TokenBuffer) {
        tokens.add(i, i + 1, .punctuation)
        let close = line.find(Ch.rbracket, from: i + 1).map { min($0, end) } ?? end
        var j = i + 1
        while j < close {
            let c = line[j]
            if Ch.isSpace(c) { j += 1; continue }
            if c == Ch.quote || c == Ch.apostrophe {
                let e = ConfigLexKit.closingQuote(line, from: j, limit: close) ?? close
                ConfigLexKit.addEscaped(line, j, e, tokens: &tokens)
                j = e
                continue
            }
            var e = j
            while e < close, line[e] != Ch.quote, line[e] != Ch.apostrophe { e += 1 }
            var trimmed = e
            while trimmed > j, Ch.isSpace(line[trimmed - 1]) { trimmed -= 1 }
            tokens.add(j, trimmed, .section)
            j = e
        }
        guard close < end else { return }
        tokens.add(close, close + 1, .punctuation)
        let rest = line.skipSpaces(close + 1)
        if rest < end, line[rest] == Ch.semicolon || line[rest] == Ch.hash {
            tokens.add(rest, end, .comment)
        }
    }

    /// Start of an inline comment (`;` or `#` preceded by whitespace) in `[from, to)`.
    private func inlineComment(_ line: LineBuffer, from: Int, to: Int) -> Int? {
        var j = from
        while j < to {
            let c = line[j]
            if (c == Ch.semicolon || c == Ch.hash), j > from, Ch.isSpace(line[j - 1]) { return j }
            j += 1
        }
        return nil
    }

    /// Finds the key/value separator. `=` wins unless a `: ` style colon comes first; a bare colon
    /// counts only when the line has no `=`. In `strict` mode (continuation lines of a multi-line
    /// value) only `name = …` with a plain name is accepted.
    private func separator(_ line: LineBuffer, from: Int, to: Int, strict: Bool) -> (start: Int, end: Int)? {
        var j = from
        var firstEquals: Int?
        var spacedColon: Int?
        var anyColon: Int?
        if line[j] == Ch.quote || line[j] == Ch.apostrophe {
            j = ConfigLexKit.closingQuote(line, from: j, limit: to) ?? to
        }
        while j < to {
            let c = line[j]
            if (c == Ch.semicolon || c == Ch.hash), j > from, Ch.isSpace(line[j - 1]) { break }
            if c == Ch.equals {
                firstEquals = j
                break
            }
            if c == Ch.colon, anyColon == nil || spacedColon == nil {
                let n = line[j + 1]
                if j + 1 >= to || Ch.isSpace(n) {
                    if spacedColon == nil { spacedColon = j }
                } else if !(n == Ch.slash && line[j + 2] == Ch.slash), anyColon == nil {
                    anyColon = j
                }
            }
            j += 1
        }
        if strict {
            guard let eq = firstEquals, spacedColon == nil, line[eq + 1] != Ch.equals else { return nil }
            var k = from
            while k < eq, Ch.isAlnum(line[k]) || line[k] == Ch.underscore || line[k] == Ch.minus || line[k] == Ch.dot { k += 1 }
            guard k > from, line.skipSpaces(k) == eq else { return nil }
            return (eq, eq + 1)
        }
        if let colon = spacedColon, firstEquals.map({ colon < $0 }) ?? true { return (colon, colon + 1) }
        if let eq = firstEquals { return (eq, eq + 1) }
        if let colon = anyColon { return (colon, colon + 1) }
        return nil
    }

    /// Values: quoted strings, numbers, booleans and `${var}`/`%(var)s` references; any other text
    /// is an unquoted string (Sublime-like). Inline comments need whitespace before `;`/`#`.
    private func lexValue(_ line: LineBuffer, from s: Int, to e: Int, tokens: inout TokenBuffer) {
        var i = s
        var runStart = -1
        var runEnd = -1
        func flush(_ tokens: inout TokenBuffer) {
            if runStart >= 0 { tokens.add(runStart, runEnd, .string) }
            runStart = -1
        }
        while i < e {
            let c = line[i]
            if Ch.isSpace(c) { i += 1; continue }
            if (c == Ch.semicolon || c == Ch.hash), i == s || Ch.isSpace(line[i - 1]) {
                flush(&tokens)
                tokens.add(i, e, .comment)
                return
            }
            if c == Ch.quote || c == Ch.apostrophe {
                flush(&tokens)
                let close = ConfigLexKit.closingQuote(line, from: i, limit: e, escapes: c == Ch.quote) ?? e
                if c == Ch.quote {
                    ConfigLexKit.addInterpolated(line, i, close, tokens: &tokens)
                } else {
                    tokens.add(i, close, .string)
                }
                i = close
                continue
            }
            if c == Ch.dollar, line[i + 1] == Ch.lbrace, let r = ConfigLexKit.dollarReferenceEnd(line, at: i, limit: e, parens: false) {
                flush(&tokens)
                tokens.add(i, r, .variable)
                i = r
                continue
            }
            if c == Ch.percent, line[i + 1] == Ch.lparen,
               let close = ConfigLexKit.find(line, Ch.rparen, from: i + 2, limit: min(e, i + ConfigLexKit.referenceWindow)) {
                flush(&tokens)
                var r = close + 1
                if r < e, Ch.isAlpha(line[r]) { r += 1 }
                tokens.add(i, r, .variable)
                i = r
                continue
            }
            if c == Ch.percent, line[i + 1] == Ch.percent {
                flush(&tokens)
                tokens.add(i, i + 2, .escape)
                i += 2
                continue
            }
            var j = i
            while j < e {
                let d = line[j]
                if Ch.isSpace(d) || d == Ch.quote || d == Ch.apostrophe { break }
                if d == Ch.dollar, line[j + 1] == Ch.lbrace { break }
                if d == Ch.percent, line[j + 1] == Ch.lparen || line[j + 1] == Ch.percent { break }
                j += 1
            }
            if j == i { j = i + 1 }
            if ConfigLexKit.isNumberWord(line, i, j) {
                flush(&tokens)
                tokens.add(i, j, .number)
            } else if ConfigLexKit.lowercasedWord(line, i, j, in: ConfigLexKit.booleans) {
                flush(&tokens)
                tokens.add(i, j, .constant)
            } else {
                if runStart < 0 { runStart = i }
                runEnd = j
            }
            i = j
        }
        flush(&tokens)
    }
}

// MARK: - Java properties

/// Java `.properties` files.
///
/// State: `mode == 1` when the previous line ended with an odd number of backslashes, so this line
/// continues the value (its leading whitespace is ignored, as in `java.util.Properties`).
public struct PropertiesLexer: SyntaxLexer {
    public init() {}

    enum Mode {
        static let normal: UInt8 = 0
        static let continuation: UInt8 = 1
    }

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        let end = ConfigLexKit.contentEnd(line)
        let first = line.skipSpaces(line.start)
        if state.main.mode == Mode.continuation {
            let continues = lexValue(line, from: min(first, end), to: end, tokens: &tokens)
            state.main.mode = continues ? Mode.continuation : Mode.normal
            return
        }
        state.main = .initial
        guard first < end else { return }
        let c = line[first]
        if c == Ch.hash || c == Ch.bang {
            tokens.add(first, end, .comment)
            return
        }
        // Key: up to an unescaped `=`, `:` or whitespace.
        var k = first
        while k < end {
            let d = line[k]
            if d == Ch.backslash { k += 2; continue }
            if d == Ch.equals || d == Ch.colon || Ch.isSpace(d) { break }
            k += 1
        }
        if k >= end, line[end - 1] == Ch.backslash, trailingBackslashes(line, from: first, to: end) % 2 == 1 {
            // `key\` continues on the next line.
            ConfigLexKit.addEscaped(line, first, end - 1, .property, tokens: &tokens)
            tokens.add(end - 1, end, .escape)
            state.main.mode = Mode.continuation
            return
        }
        k = min(k, end)
        ConfigLexKit.addEscaped(line, first, k, .property, tokens: &tokens)
        var j = k
        while j < end, Ch.isSpace(line[j]) { j += 1 }
        if j < end, line[j] == Ch.equals || line[j] == Ch.colon {
            tokens.add(j, j + 1, .operator)
            j += 1
            while j < end, Ch.isSpace(line[j]) { j += 1 }
        }
        if lexValue(line, from: j, to: end, tokens: &tokens) {
            state.main.mode = Mode.continuation
        }
    }

    private func trailingBackslashes(_ line: LineBuffer, from s: Int, to e: Int) -> Int {
        var count = 0
        var t = e
        while t > s, line[t - 1] == Ch.backslash {
            count += 1
            t -= 1
        }
        return count
    }

    /// Lexes a value; returns whether it continues on the next line.
    private func lexValue(_ line: LineBuffer, from s: Int, to e: Int, tokens: inout TokenBuffer) -> Bool {
        guard s < e else { return false }
        let continues = trailingBackslashes(line, from: s, to: e) % 2 == 1
        let valueEnd = continues ? e - 1 : e
        var seg = s
        var j = s
        while j < valueEnd {
            let c = line[j]
            if c == Ch.backslash, j + 1 < valueEnd {
                tokens.add(seg, j, .string)
                let k = ConfigLexKit.escapeEnd(line, j, limit: valueEnd)
                tokens.add(j, k, .escape)
                j = k
                seg = k
                continue
            }
            if c == Ch.dollar, line[j + 1] == Ch.lbrace,
               let close = ConfigLexKit.find(line, Ch.rbrace, from: j + 2, limit: min(valueEnd, j + ConfigLexKit.referenceWindow)) {
                tokens.add(seg, j, .string)
                tokens.add(j, close + 1, .variable)
                j = close + 1
                seg = j
                continue
            }
            // MessageFormat arguments: {0}, {1,number}
            if c == Ch.lbrace, Ch.isDigit(line[j + 1]),
               let close = ConfigLexKit.find(line, Ch.rbrace, from: j + 2, limit: min(valueEnd, j + 64)) {
                tokens.add(seg, j, .string)
                tokens.add(j, close + 1, .variable)
                j = close + 1
                seg = j
                continue
            }
            j += 1
        }
        tokens.add(seg, valueEnd, .string)
        if continues { tokens.add(e - 1, e, .escape) }
        return continues
    }
}
