import Foundation

/// TOML.
///
/// State: `mode` 1/2 inside a multi-line basic (`"""`) / literal (`'''`) string; `depth` counts the
/// open arrays and inline tables (arrays may span lines) and bit `k` of `data` is set when nesting
/// level `k` is an inline table, where keys are expected.
public struct TOMLLexer: SyntaxLexer {
    public init() {}

    enum Mode {
        static let normal: UInt8 = 0
        static let multilineBasic: UInt8 = 1
        static let multilineLiteral: UInt8 = 2
    }

    private static let inf = u16("inf")
    private static let nan = u16("nan")
    private static let notHeaderNames: Set<String> = ["true", "false", "inf", "nan"]

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        var st = state.main
        var i = line.start
        let end = line.end
        if st.mode == Mode.multilineBasic || st.mode == Mode.multilineLiteral {
            guard let after = scanMultiline(line, from: i, tokenStart: i, literal: st.mode == Mode.multilineLiteral, tokens: &tokens) else {
                return
            }
            i = after
            st.mode = Mode.normal
        }
        var atLineStart = i == line.start
        var expectKey = st.depth == 0 || topIsTable(st)
        while i < end {
            let c = line[i]
            if Ch.isSpace(c) { i += 1; continue }
            if c == Ch.hash {
                tokens.add(i, line.trimmedEnd, .comment)
                break
            }
            if atLineStart {
                atLineStart = false
                if c == Ch.lbracket, st.depth == 0 || looksLikeHeader(line, from: i) {
                    st.depth = 0
                    st.data = 0
                    i = lexHeader(line, from: i, tokens: &tokens)
                    expectKey = false
                    continue
                }
                if st.depth > 0, !topIsTable(st), keyPath(line, from: i) != nil {
                    // `key = …` inside an array that was never closed: start over.
                    st.depth = 0
                    st.data = 0
                    expectKey = true
                }
            }
            if expectKey, let eq = keyPath(line, from: i) {
                emitKeyPath(line, from: i, to: eq, tokens: &tokens)
                tokens.add(eq, eq + 1, .operator)
                i = eq + 1
                expectKey = false
                continue
            }
            expectKey = false
            switch c {
            case Ch.quote, Ch.apostrophe:
                let literal = c == Ch.apostrophe
                if line[i + 1] == c, line[i + 2] == c {
                    guard let after = scanMultiline(line, from: i + 3, tokenStart: i, literal: literal, tokens: &tokens) else {
                        st.mode = literal ? Mode.multilineLiteral : Mode.multilineBasic
                        state.main = st
                        return
                    }
                    i = after
                } else {
                    let close = ConfigLexKit.closingQuote(line, from: i, limit: end, escapes: !literal) ?? end
                    if literal {
                        tokens.add(i, close, .string)
                    } else {
                        ConfigLexKit.addEscaped(line, i, close, tokens: &tokens)
                    }
                    i = close
                }
            case Ch.lbracket, Ch.lbrace:
                tokens.add(i, i + 1, .punctuation)
                push(&st, table: c == Ch.lbrace)
                expectKey = c == Ch.lbrace
                i += 1
            case Ch.rbracket, Ch.rbrace:
                tokens.add(i, i + 1, .punctuation)
                pop(&st)
                i += 1
            case Ch.comma:
                tokens.add(i, i + 1, .punctuation)
                expectKey = topIsTable(st)
                i += 1
            case Ch.equals:
                tokens.add(i, i + 1, .operator)
                i += 1
            default:
                if let e = scanDateTime(line, at: i) {
                    tokens.add(i, e, .constant)
                    i = e
                } else if let e = scanNumber(line, at: i) {
                    tokens.add(i, e, .number)
                    i = e
                } else if isBareKeyChar(c) {
                    var e = i
                    while e < end, isBareKeyChar(line[e]) { e += 1 }
                    if ConfigLexKit.word(line, i, e, in: ["true", "false"]) {
                        tokens.add(i, e, .constant)
                    }
                    i = e
                } else {
                    i += 1
                }
            }
        }
        state.main = st
    }

    // MARK: Nesting

    private func topIsTable(_ st: LexState) -> Bool {
        let level = Int(st.depth) - 1
        guard level >= 0, level < 31 else { return false }
        return (UInt32(bitPattern: st.data) >> UInt32(level)) & 1 == 1
    }

    private func push(_ st: inout LexState, table: Bool) {
        let level = Int(st.depth)
        if level < 31 {
            var bits = UInt32(bitPattern: st.data)
            if table { bits |= 1 << UInt32(level) } else { bits &= ~(1 << UInt32(level)) }
            st.data = Int32(bitPattern: bits)
        }
        if st.depth < UInt16.max { st.depth += 1 }
    }

    private func pop(_ st: inout LexState) {
        guard st.depth > 0 else { return }
        st.depth -= 1
        let level = Int(st.depth)
        if level < 31 {
            st.data = Int32(bitPattern: UInt32(bitPattern: st.data) & ~(1 << UInt32(level)))
        }
    }

    // MARK: Keys and headers

    private func isBareKeyChar(_ c: UInt16) -> Bool {
        Ch.isAlnum(c) || c == Ch.underscore || c == Ch.minus || (c >= 0x80 && !Ch.isSpace(c))
    }

    /// If a (dotted) key followed by `=` starts at `i`, returns the index of the `=`.
    private func keyPath(_ line: LineBuffer, from i: Int) -> Int? {
        var j = i
        while true {
            let c = line[j]
            if c == Ch.quote || c == Ch.apostrophe {
                guard let close = ConfigLexKit.closingQuote(line, from: j, limit: line.end, escapes: c == Ch.quote) else { return nil }
                j = close
            } else if isBareKeyChar(c) {
                while j < line.end, isBareKeyChar(line[j]) { j += 1 }
            } else {
                return nil
            }
            let k = line.skipSpaces(j)
            if line[k] == Ch.dot {
                j = line.skipSpaces(k + 1)
                continue
            }
            if line[k] == Ch.equals, line[k + 1] != Ch.equals { return k }
            return nil
        }
    }

    private func emitKeyPath(_ line: LineBuffer, from i: Int, to eq: Int, tokens: inout TokenBuffer) {
        var j = i
        while j < eq {
            let c = line[j]
            if Ch.isSpace(c) { j += 1; continue }
            if c == Ch.dot {
                tokens.add(j, j + 1, .punctuation)
                j += 1
                continue
            }
            if c == Ch.quote || c == Ch.apostrophe {
                let close = ConfigLexKit.closingQuote(line, from: j, limit: eq, escapes: c == Ch.quote) ?? eq
                tokens.add(j, close, .property)
                j = close
                continue
            }
            var e = j
            while e < eq, isBareKeyChar(line[e]) { e += 1 }
            if e == j { e = j + 1 }
            tokens.add(j, e, .property)
            j = e
        }
    }

    /// `[table]`, `[[array.of.tables]]`, `[dog."tater.man"]`.
    private func lexHeader(_ line: LineBuffer, from i: Int, tokens: inout TokenBuffer) -> Int {
        let end = line.end
        let double = line[i + 1] == Ch.lbracket
        let openEnd = i + (double ? 2 : 1)
        tokens.add(i, openEnd, .punctuation)
        let nameStart = line.skipSpaces(openEnd)
        var k = nameStart
        var nameEnd = nameStart
        while k < end {
            let c = line[k]
            if c == Ch.quote || c == Ch.apostrophe {
                k = ConfigLexKit.closingQuote(line, from: k, limit: end, escapes: c == Ch.quote) ?? end
                nameEnd = k
                continue
            }
            if c == Ch.rbracket || c == Ch.hash { break }
            if !Ch.isSpace(c) { nameEnd = k + 1 }
            k += 1
        }
        tokens.add(nameStart, nameEnd, .section)
        if k < end, line[k] == Ch.rbracket {
            let closeEnd = k + ((double && line[k + 1] == Ch.rbracket) ? 2 : 1)
            tokens.add(k, closeEnd, .punctuation)
            k = closeEnd
        }
        return k
    }

    /// Whether a line inside an open array looks like a table header (used to recover from an
    /// unterminated array). Arrays such as `[1, 2]` or `["a"]` do not qualify.
    private func looksLikeHeader(_ line: LineBuffer, from i: Int) -> Bool {
        var j = i + 1
        if line[j] == Ch.lbracket { j += 1 }
        j = line.skipSpaces(j)
        guard Ch.isAlpha(line[j]) || line[j] == Ch.underscore else { return false }
        let s = j
        while j < line.end, Ch.isAlnum(line[j]) || line[j] == Ch.underscore || line[j] == Ch.minus || line[j] == Ch.dot { j += 1 }
        if ConfigLexKit.word(line, s, j, in: Self.notHeaderNames) { return false }
        j = line.skipSpaces(j)
        guard line[j] == Ch.rbracket else { return false }
        j += 1
        if line[j] == Ch.rbracket { j += 1 }
        j = line.skipSpaces(j)
        return j >= line.end || line[j] == Ch.hash
    }

    // MARK: Values

    /// Scans a multi-line string body from `from`; tokens start at `tokenStart` (the opening quotes,
    /// or the line start when continuing). Returns the index after the closing quotes, or nil.
    private func scanMultiline(_ line: LineBuffer, from start: Int, tokenStart: Int, literal: Bool, tokens: inout TokenBuffer) -> Int? {
        let q = literal ? Ch.apostrophe : Ch.quote
        let end = line.end
        var seg = tokenStart
        var j = start
        while j < end {
            let c = line[j]
            if !literal, c == Ch.backslash {
                tokens.add(seg, j, .string)
                let k = j + 1 >= end ? end : ConfigLexKit.escapeEnd(line, j, limit: end)
                tokens.add(j, k, .escape)
                j = k
                seg = k
                continue
            }
            if c == q, line[j + 1] == q, line[j + 2] == q {
                // Up to two extra quotes belong to the content: `""""` ends with a quote character.
                var close = j + 3
                if line[close] == q {
                    close += 1
                    if line[close] == q { close += 1 }
                }
                tokens.add(seg, close, .string)
                return close
            }
            j += 1
        }
        tokens.add(seg, end, .string)
        return nil
    }

    private func digits(_ line: LineBuffer, _ k: Int, _ n: Int) -> Bool {
        for m in 0..<n where !Ch.isDigit(line[k + m]) { return false }
        return true
    }

    /// `HH:MM[:SS[.frac]]`
    private func scanTime(_ line: LineBuffer, at k: Int) -> Int? {
        guard digits(line, k, 2), line[k + 2] == Ch.colon, digits(line, k + 3, 2) else { return nil }
        var e = k + 5
        if line[e] == Ch.colon, digits(line, e + 1, 2) {
            e += 3
            if line[e] == Ch.dot, Ch.isDigit(line[e + 1]) {
                e += 1
                while e < line.end, Ch.isDigit(line[e]) { e += 1 }
            }
        }
        return e
    }

    /// Offset date-times, local date-times, local dates and local times.
    private func scanDateTime(_ line: LineBuffer, at i: Int) -> Int? {
        if digits(line, i, 4), line[i + 4] == Ch.minus, digits(line, i + 5, 2), line[i + 7] == Ch.minus, digits(line, i + 8, 2) {
            var k = i + 10
            let sep = line[k]
            if sep == 0x54 || sep == 0x74 || sep == Ch.space, let t = scanTime(line, at: k + 1) {
                k = t
                let z = line[k]
                if z == 0x5A || z == 0x7A {
                    k += 1
                } else if z == Ch.plus || z == Ch.minus, digits(line, k + 1, 2), line[k + 3] == Ch.colon, digits(line, k + 4, 2) {
                    k += 6
                }
            }
            return k
        }
        return scanTime(line, at: i)
    }

    /// Integers (with `_`, hex/octal/binary prefixes), floats and `inf`/`nan` with optional sign.
    private func scanNumber(_ line: LineBuffer, at i: Int) -> Int? {
        var k = i
        if line[k] == Ch.plus || line[k] == Ch.minus { k += 1 }
        if line.matches(Self.inf, at: k) || line.matches(Self.nan, at: k), !Ch.isIdentChar(line[k + 3]) {
            return k + 3
        }
        guard Ch.isDigit(line[k]) else { return nil }
        if line[k] == Ch.zero, line[k + 1] == Ch.x || line[k + 1] == Ch.o || line[k + 1] == Ch.b {
            k += 2
            while k < line.end, Ch.isHexDigit(line[k]) || line[k] == Ch.underscore { k += 1 }
            return k
        }
        while k < line.end, Ch.isDigit(line[k]) || line[k] == Ch.underscore { k += 1 }
        if line[k] == Ch.dot, Ch.isDigit(line[k + 1]) {
            k += 1
            while k < line.end, Ch.isDigit(line[k]) || line[k] == Ch.underscore { k += 1 }
        }
        if line[k] == Ch.e || line[k] == 0x45 {
            var m = k + 1
            if line[m] == Ch.plus || line[m] == Ch.minus { m += 1 }
            if Ch.isDigit(line[m]) {
                k = m
                while k < line.end, Ch.isDigit(line[k]) || line[k] == Ch.underscore { k += 1 }
            }
        }
        return k
    }
}
