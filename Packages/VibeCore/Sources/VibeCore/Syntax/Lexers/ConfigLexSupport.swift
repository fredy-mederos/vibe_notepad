import Foundation

/// Scanning helpers shared by the configuration, markup, shell and build-file lexers.
enum ConfigLexKit {
    static let letterV: UInt16 = 0x76
    static let letterUpperV: UInt16 = 0x56

    static func words(_ s: String) -> Set<String> {
        Set(s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }

    /// Boolean-like words colored as constants in configuration values (compared lowercased).
    static let booleans: Set<String> = ["true", "false", "yes", "no", "on", "off"]

    /// Longest span searched for the closing bracket of a variable reference, so that unterminated
    /// references cannot make a line quadratic to lex.
    static let referenceWindow = 512

    /// First index of `lit` in `[from, limit)` (the whole literal must fit before `limit`), or nil.
    static func find(_ line: LineBuffer, _ lit: [UInt16], from: Int, limit: Int) -> Int? {
        guard let first = lit.first else { return nil }
        var j = max(from, line.start)
        let end = min(limit, line.end)
        while j + lit.count <= end {
            if line[j] == first, line.matches(lit, at: j) { return j }
            j += 1
        }
        return nil
    }

    // MARK: Lines

    /// First index of `c` in `[from, limit)`, or nil.
    static func find(_ line: LineBuffer, _ c: UInt16, from: Int, limit: Int) -> Int? {
        var j = max(from, line.start)
        let end = min(limit, line.end)
        while j < end {
            if line[j] == c { return j }
            j += 1
        }
        return nil
    }

    /// End of the line's content without a trailing "\r".
    @inline(__always)
    static func contentEnd(_ line: LineBuffer) -> Int {
        let e = line.end
        return (e > line.start && line[e - 1] == Ch.cr) ? e - 1 : e
    }

    /// Whether the lowercased text of `[s, e)` is in `set`. Long words are rejected without allocating.
    static func lowercasedWord(_ line: LineBuffer, _ s: Int, _ e: Int, in set: Set<String>, maxLength: Int = 24) -> Bool {
        guard e > s, e - s <= maxLength else { return false }
        return set.contains(line.lowercasedString(s, e))
    }

    /// Whether the exact text of `[s, e)` is in `set`.
    static func word(_ line: LineBuffer, _ s: Int, _ e: Int, in set: Set<String>, maxLength: Int = 24) -> Bool {
        guard e > s, e - s <= maxLength else { return false }
        return set.contains(line.string(s, e))
    }

    // MARK: Heredoc delimiters

    /// FNV-1a hash of `[s, e)` ignoring quotes and backslashes, so `'EOF'`, `"EOF"`, `\EOF` and `EOF` hash alike.
    static func delimiterHash(_ line: LineBuffer, _ s: Int, _ e: Int) -> Int32 {
        var h: UInt32 = 2_166_136_261
        var k = max(s, line.start)
        let end = min(e, line.end)
        while k < end {
            let c = line[k]
            if c != Ch.quote, c != Ch.apostrophe, c != Ch.backslash {
                h = (h ^ UInt32(c)) &* 16_777_619
            }
            k += 1
        }
        return Int32(bitPattern: h)
    }

    /// Scans a heredoc delimiter word at `i` (`EOF`, `'EOF'`, `"EOF"`, `\EOF`).
    /// Returns its end and whether it is quoted (quoting disables expansions in the body).
    static func scanHeredocDelimiter(_ line: LineBuffer, from i: Int, limit: Int) -> (end: Int, quoted: Bool)? {
        var j = i
        var quoted = false
        scan: while j < limit {
            let c = line[j]
            if Ch.isSpace(c) { break }
            switch c {
            case Ch.semicolon, Ch.pipe, Ch.amp, Ch.lt, Ch.gt, Ch.lparen, Ch.rparen:
                break scan
            case Ch.quote, Ch.apostrophe:
                quoted = true
                if let close = line.find(c, from: j + 1), close < limit { j = close + 1 } else { j = limit }
            case Ch.backslash:
                quoted = true
                j += 2
            default:
                j += 1
            }
        }
        j = min(j, limit)
        return j > i ? (j, quoted) : nil
    }

    // MARK: Strings

    /// Index after the closing quote of the string opening at `i`, or nil when `limit` comes first.
    static func closingQuote(_ line: LineBuffer, from i: Int, limit: Int, escapes: Bool = true) -> Int? {
        let q = line[i]
        let end = min(limit, line.end)
        var j = i + 1
        while j < end {
            let c = line[j]
            if escapes, c == Ch.backslash { j += 2; continue }
            if c == q { return j + 1 }
            j += 1
        }
        return nil
    }

    /// End of the backslash escape at `j` (`\n`, `\uXXXX`, `\u{…}`, `\UXXXXXXXX`, `\xHH`), clamped to `limit`.
    static func escapeEnd(_ line: LineBuffer, _ j: Int, limit: Int) -> Int {
        let n = line[j + 1]
        var k = j + 2
        var maxHex = 0
        if n == 0x75 { maxHex = 4 } else if n == 0x55 { maxHex = 8 } else if n == Ch.x { maxHex = 2 }
        if maxHex > 0 {
            if n == 0x75, line[k] == Ch.lbrace, let close = find(line, Ch.rbrace, from: k + 1, limit: min(limit, k + 10)) {
                return close + 1
            }
            let stop = k + maxHex
            while k < stop, k < limit, Ch.isHexDigit(line[k]) { k += 1 }
        }
        return min(k, limit)
    }

    /// Emits `[s, e)` as `kind`, splitting backslash escapes out as `.escape`.
    static func addEscaped(_ line: LineBuffer, _ s: Int, _ e: Int, _ kind: TokenKind = .string, tokens: inout TokenBuffer) {
        var seg = s
        var j = s
        while j < e {
            if line[j] == Ch.backslash, j + 1 < e {
                tokens.add(seg, j, kind)
                let k = escapeEnd(line, j, limit: e)
                tokens.add(j, k, .escape)
                j = k
                seg = k
                continue
            }
            j += 1
        }
        tokens.add(seg, e, kind)
    }

    /// Emits the string `[s, e)` with backslash escapes as `.escape` and `$NAME`/`${…}` references as `.variable`.
    static func addInterpolated(_ line: LineBuffer, _ s: Int, _ e: Int, escapes: Bool = true, tokens: inout TokenBuffer) {
        var seg = s
        var j = s
        while j < e {
            let c = line[j]
            if escapes, c == Ch.backslash, j + 1 < e {
                tokens.add(seg, j, .string)
                let k = escapeEnd(line, j, limit: e)
                tokens.add(j, k, .escape)
                j = k
                seg = k
                continue
            }
            if c == Ch.dollar, let r = dollarReferenceEnd(line, at: j, limit: e, parens: false) {
                tokens.add(seg, j, .string)
                tokens.add(j, r, .variable)
                j = r
                seg = r
                continue
            }
            j += 1
        }
        tokens.add(seg, e, .string)
    }

    // MARK: Variables

    /// End of a `$NAME`, `${…}` (nested braces) or — when `parens` — `$(…)` reference at `i`, or nil.
    static func dollarReferenceEnd(_ line: LineBuffer, at i: Int, limit: Int, parens: Bool) -> Int? {
        guard line[i] == Ch.dollar, i + 1 < limit else { return nil }
        let n = line[i + 1]
        if n == Ch.lbrace || (parens && n == Ch.lparen) {
            let close = n == Ch.lbrace ? Ch.rbrace : Ch.rparen
            let stop = min(limit, i + referenceWindow)
            var depth = 0
            var j = i + 1
            while j < stop {
                let c = line[j]
                if c == n {
                    depth += 1
                } else if c == close {
                    depth -= 1
                    if depth == 0 { return j + 1 }
                }
                j += 1
            }
            return nil
        }
        if Ch.isAlpha(n) || n == Ch.underscore {
            var j = i + 2
            while j < limit, Ch.isAlnum(line[j]) || line[j] == Ch.underscore { j += 1 }
            return j
        }
        return nil
    }

    // MARK: Numbers

    /// Whether `[s, e)` is a number as written in configuration files: integers and decimals with an
    /// optional sign, hex (`0x1F`), versions (`1.2.3`, `v1.2.3-beta.1`), IPv4 addresses with optional
    /// `/cidr` and `:port`, and sizes/durations/percentages (`64k`, `10m`, `1.5GB`, `500ms`, `1h30m`, `50%`).
    static func isNumberWord(_ line: LineBuffer, _ s: Int, _ e: Int) -> Bool {
        guard e > s else { return false }
        var k = s
        if line[k] == Ch.plus || line[k] == Ch.minus { k += 1 }
        var versionPrefix = false
        if line[k] == letterV || line[k] == letterUpperV, Ch.isDigit(line[k + 1]) {
            versionPrefix = true
            k += 1
        }
        guard k < e, Ch.isDigit(line[k]) else { return false }
        if line[k] == Ch.zero, Ch.lower(line[k + 1]) == Ch.x, Ch.isHexDigit(line[k + 2]) {
            k += 2
            while k < e, Ch.isHexDigit(line[k]) || line[k] == Ch.underscore { k += 1 }
            return k == e
        }
        var groups = 1
        while k < e, Ch.isDigit(line[k]) || line[k] == Ch.underscore { k += 1 }
        while k < e, line[k] == Ch.dot, Ch.isDigit(line[k + 1]) {
            k += 1
            groups += 1
            while k < e, Ch.isDigit(line[k]) { k += 1 }
        }
        if groups == 4 {
            if line[k] == Ch.slash, Ch.isDigit(line[k + 1]) {
                k += 1
                while k < e, Ch.isDigit(line[k]) { k += 1 }
            }
            if line[k] == Ch.colon, Ch.isDigit(line[k + 1]) {
                k += 1
                while k < e, Ch.isDigit(line[k]) { k += 1 }
            }
            return k == e
        }
        // Units and compound durations: 64k, 10m, 1.5GB, 500ms, 1h30m.
        while k < e {
            var letters = 0
            while k < e, letters < 5, Ch.isAlpha(line[k]) {
                k += 1
                letters += 1
            }
            if letters == 0 || k >= e || !Ch.isDigit(line[k]) { break }
            while k < e, Ch.isDigit(line[k]) { k += 1 }
        }
        if k < e, line[k] == Ch.percent { k += 1 }
        // Pre-release and build suffixes: 1.2.3-beta.1, v0.0.0-20210101-abcdef, 2.0.0+incompatible.
        if groups >= 3 || versionPrefix {
            while k < e, line[k] == Ch.minus || line[k] == Ch.plus || line[k] == Ch.dot, Ch.isAlnum(line[k + 1]) {
                k += 1
                while k < e, Ch.isAlnum(line[k]) { k += 1 }
            }
        }
        return k == e
    }

    // MARK: Merging

    /// Appends `base` to `tokens`, clipped so that `overlay` tokens replace them where they overlap.
    /// Both arrays must be sorted and non-overlapping; the result is too.
    static func appendMerged(_ base: [Token], overlay: [Token], into tokens: inout TokenBuffer) {
        var bi = 0
        var cursor = Int.min
        for o in overlay {
            while bi < base.count, base[bi].start < o.start {
                let b = base[bi]
                let s = max(b.start, cursor), e = min(b.end, o.start)
                if e > s { tokens.add(s, e, b.kind) }
                if b.end <= o.start { bi += 1 } else { break }
            }
            tokens.add(o.start, o.end, o.kind)
            cursor = max(cursor, o.end)
            while bi < base.count, base[bi].end <= cursor { bi += 1 }
        }
        while bi < base.count {
            let b = base[bi]
            let s = max(b.start, cursor)
            if b.end > s { tokens.add(s, b.end, b.kind) }
            bi += 1
        }
    }
}
