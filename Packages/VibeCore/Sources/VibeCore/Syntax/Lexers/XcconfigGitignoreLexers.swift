import Foundation

// MARK: - xcconfig

/// Xcode build configuration files. Stateless: every line stands alone.
public struct XcconfigLexer: SyntaxLexer {
    public init() {}

    private static let include = u16("#include")
    private static let constants: Set<String> = ["YES", "NO", "yes", "no", "true", "false"]

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        state.main = .initial
        let end = line.trimmedEnd
        let first = line.firstNonSpace
        guard first < end else { return }
        if line[first] == Ch.slash, line[first + 1] == Ch.slash {
            tokens.add(first, end, .comment)
            return
        }
        if line.matches(Self.include, at: first) {
            var j = first + Self.include.count
            if line[j] == Ch.question { j += 1 }
            tokens.add(first, j, .meta)
            j = line.skipSpaces(j)
            if j < end, line[j] == Ch.quote {
                let close = ConfigLexKit.closingQuote(line, from: j, limit: end, escapes: false) ?? end
                tokens.add(j, close, .string)
                j = close
            } else if j < end, line[j] == Ch.lt {
                let close = line.find(Ch.gt, from: j + 1).map { min($0 + 1, end) } ?? end
                tokens.add(j, close, .string)
                j = close
            }
            lexValue(line, from: j, to: end, tokens: &tokens)
            return
        }
        guard Ch.isIdentStart(line[first]) else {
            lexValue(line, from: first, to: end, tokens: &tokens)
            return
        }
        let keyEnd = line.scanIdentifier(first)
        tokens.add(first, keyEnd, .property)
        var j = line.skipSpaces(keyEnd)
        // Conditional settings: KEY[sdk=iphoneos*][arch=arm64]
        while j < end, line[j] == Ch.lbracket {
            let close = line.find(Ch.rbracket, from: j + 1).map { min($0 + 1, end) } ?? end
            tokens.add(j, close, .attribute)
            j = line.skipSpaces(close)
        }
        if j < end, line[j] == Ch.equals {
            tokens.add(j, j + 1, .operator)
            j += 1
        }
        lexValue(line, from: j, to: end, tokens: &tokens)
    }

    private func lexValue(_ line: LineBuffer, from s: Int, to end: Int, tokens: inout TokenBuffer) {
        var i = s
        while i < end {
            let c = line[i]
            if Ch.isSpace(c) { i += 1; continue }
            if c == Ch.slash, line[i + 1] == Ch.slash {
                tokens.add(i, end, .comment)
                return
            }
            if c == Ch.quote || c == Ch.apostrophe {
                let close = ConfigLexKit.closingQuote(line, from: i, limit: end) ?? end
                lexQuoted(line, i, close, tokens: &tokens)
                i = close
                continue
            }
            if c == Ch.dollar {
                if let r = referenceEnd(line, at: i, limit: end) {
                    tokens.add(i, r, .variable)
                    i = r
                } else {
                    i += 1
                }
                continue
            }
            var j = i
            while j < end {
                let d = line[j]
                if Ch.isSpace(d) || d == Ch.quote || d == Ch.apostrophe || d == Ch.dollar { break }
                if d == Ch.slash, line[j + 1] == Ch.slash { break }
                j += 1
            }
            if j == i { j = i + 1 }
            if c == Ch.minus, Ch.isAlpha(line[i + 1]) {
                tokens.add(i, j, .attribute)
            } else if ConfigLexKit.word(line, i, j, in: Self.constants) {
                tokens.add(i, j, .constant)
            } else if ConfigLexKit.isNumberWord(line, i, j) {
                tokens.add(i, j, .number)
            }
            i = j
        }
    }

    /// `$(VAR)`, `$(VAR:modifier)`, `${VAR}`, `$(A_$(B))` and `$VAR`.
    private func referenceEnd(_ line: LineBuffer, at i: Int, limit: Int) -> Int? {
        let n = line[i + 1]
        if n == Ch.lparen || n == Ch.lbrace {
            return ConfigLexKit.dollarReferenceEnd(line, at: i, limit: limit, parens: true) ?? limit
        }
        return ConfigLexKit.dollarReferenceEnd(line, at: i, limit: limit, parens: false)
    }

    private func lexQuoted(_ line: LineBuffer, _ s: Int, _ e: Int, tokens: inout TokenBuffer) {
        var seg = s
        var j = s + 1
        while j < e {
            if line[j] == Ch.dollar, let r = referenceEnd(line, at: j, limit: e) {
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
}

// MARK: - Ignore lists and attributes

/// `.gitignore`, `.dockerignore` & co, `.gitattributes` and `CODEOWNERS`. Stateless.
///
/// The first whitespace-separated token is the pattern; anything after it is a list of attributes
/// (`.gitattributes`) or owners (`CODEOWNERS`).
public struct GitignoreLexer: SyntaxLexer {
    public init() {}

    private static let attrMacro = u16("[attr]")

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        state.main = .initial
        let end = ConfigLexKit.contentEnd(line)
        var i = line.skipSpaces(line.start)
        guard i < end else { return }
        if line[i] == Ch.hash {
            tokens.add(i, end, .comment)
            return
        }
        if line.matches(Self.attrMacro, at: i) {
            tokens.add(i, i + Self.attrMacro.count, .keyword)
            i += Self.attrMacro.count
            var j = i
            while j < end, !Ch.isSpace(line[j]) { j += 1 }
            tokens.add(i, j, .attribute)
            lexAttributes(line, from: j, to: end, tokens: &tokens)
            return
        }
        if line[i] == Ch.bang {
            tokens.add(i, i + 1, .operator)
            i += 1
        }
        i = lexPattern(line, from: i, to: end, tokens: &tokens)
        lexAttributes(line, from: i, to: end, tokens: &tokens)
    }

    private func lexPattern(_ line: LineBuffer, from s: Int, to end: Int, tokens: inout TokenBuffer) -> Int {
        var i = s
        // Classes are not searched again before this index once a `[` had no closing `]`.
        var noClassBefore = s
        while i < end {
            let c = line[i]
            if Ch.isSpace(c) { break }
            switch c {
            case Ch.backslash:
                let e = min(i + 2, end)
                tokens.add(i, e, .escape)
                i = e
            case Ch.star, Ch.question:
                var e = i + 1
                while e < end, line[e] == Ch.star { e += 1 }
                tokens.add(i, e, .operator)
                i = e
            case Ch.lbracket:
                // `[]a]` and `[!a]` keep the first `]` inside the class.
                var k = i + 1
                if line[k] == Ch.bang || line[k] == Ch.caret { k += 1 }
                if line[k] == Ch.rbracket { k += 1 }
                var close: Int?
                if i >= noClassBefore {
                    while k < end, !Ch.isSpace(line[k]) {
                        if line[k] == Ch.rbracket {
                            close = k
                            break
                        }
                        k += 1
                    }
                    if close == nil { noClassBefore = k }
                }
                if let close {
                    tokens.add(i, close + 1, .regex)
                    i = close + 1
                } else {
                    i += 1
                }
            case Ch.slash:
                tokens.add(i, i + 1, .punctuation)
                i += 1
            default:
                i += 1
            }
        }
        return i
    }

    private func lexAttributes(_ line: LineBuffer, from s: Int, to end: Int, tokens: inout TokenBuffer) {
        var i = s
        while i < end {
            if Ch.isSpace(line[i]) { i += 1; continue }
            if line[i] == Ch.hash {
                tokens.add(i, end, .comment)
                return
            }
            var e = i
            while e < end, !Ch.isSpace(line[e]) { e += 1 }
            if ConfigLexKit.find(line, Ch.at, from: i, limit: e) != nil {
                tokens.add(i, e, .variable)
                i = e
                continue
            }
            var k = i
            if line[k] == Ch.minus || line[k] == Ch.bang {
                tokens.add(k, k + 1, .operator)
                k += 1
            }
            if let eq = ConfigLexKit.find(line, Ch.equals, from: k, limit: e) {
                tokens.add(k, eq, .attribute)
                tokens.add(eq, eq + 1, .operator)
                tokens.add(eq + 1, e, .string)
            } else {
                tokens.add(k, e, .attribute)
            }
            i = e
        }
    }
}
