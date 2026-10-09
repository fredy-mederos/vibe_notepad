import Foundation

/// Generic "directive argument…" configuration files: nginx, Apache/.htaccess, hosts, ssh config,
/// requirements.txt, go.mod, crontab, tmux.conf, vimrc, CMakeLists…
///
/// The first word of a statement (line start, or after `{`, `}` or `;`) is a directive. With
/// `sshConfig`, `Host`/`Match` lines open blocks and their patterns are colored as sections.
///
/// State: `mode == 1` when the previous line ended with a `\` continuation; `depth` counts open
/// parentheses (multi-line CMake calls), so a continued line does not start with a directive.
public struct ConfLexer: SyntaxLexer {
    public let sshConfig: Bool

    public init(sshConfig: Bool = false) {
        self.sshConfig = sshConfig
    }

    private static let sshBlockKeywords: Set<String> = ["host", "match"]

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        let continued = state.main.mode == 1
        var depth = Int(state.main.depth)
        state.main = .initial
        let end = line.trimmedEnd
        let first = line.firstNonSpace
        guard first < end else { return }
        let c = line[first]
        if c == Ch.hash {
            tokens.add(first, end, .comment)
            state.main.depth = UInt16(depth)
            return
        }
        if c == Ch.quote, ConfigLexKit.find(line, Ch.quote, from: first + 1, limit: end) == nil {
            // vimrc comment line: `" text`
            tokens.add(first, end, .comment)
            state.main.depth = UInt16(depth)
            return
        }
        if !continued, depth == 0, isTagStart(line, first) {
            lexTag(line, from: first, to: end, tokens: &tokens)
            return
        }
        if sshConfig, !continued, lexSSHBlock(line, from: first, to: end, tokens: &tokens) {
            return
        }
        lexStatements(line, from: first, to: end, statementStart: !continued && depth == 0, depth: &depth, tokens: &tokens)
        state.main.depth = UInt16(clamping: depth)
        if line[end - 1] == Ch.backslash { state.main.mode = 1 }
    }

    // MARK: Statements

    private func lexStatements(_ line: LineBuffer, from start: Int, to end: Int, statementStart: Bool,
                               depth: inout Int, tokens: inout TokenBuffer) {
        var i = start
        var statement = statementStart
        while i < end {
            let c = line[i]
            if Ch.isSpace(c) { i += 1; continue }
            let atBoundary = i == line.start || isBoundary(line[i - 1])
            if atBoundary, c == Ch.hash || (c == Ch.slash && line[i + 1] == Ch.slash) {
                tokens.add(i, end, .comment)
                return
            }
            switch c {
            case Ch.quote, Ch.apostrophe, Ch.backtick:
                let close = ConfigLexKit.closingQuote(line, from: i, limit: end) ?? end
                if c == Ch.quote {
                    ConfigLexKit.addInterpolated(line, i, close, tokens: &tokens)
                } else {
                    ConfigLexKit.addEscaped(line, i, close, tokens: &tokens)
                }
                i = close
                statement = false
            case Ch.lbrace, Ch.rbrace, Ch.semicolon:
                tokens.add(i, i + 1, .punctuation)
                statement = true
                i += 1
            case Ch.lparen:
                tokens.add(i, i + 1, .punctuation)
                depth += 1
                statement = false
                i += 1
            case Ch.rparen:
                tokens.add(i, i + 1, .punctuation)
                depth = max(0, depth - 1)
                i += 1
            case Ch.lbracket, Ch.rbracket, Ch.comma:
                tokens.add(i, i + 1, .punctuation)
                i += 1
            case Ch.dollar:
                if let r = ConfigLexKit.dollarReferenceEnd(line, at: i, limit: end, parens: true) {
                    tokens.add(i, r, .variable)
                    i = r
                } else if Ch.isDigit(line[i + 1]) {
                    tokens.add(i, i + 2, .variable)
                    i += 2
                } else {
                    i += 1
                }
                statement = false
            case Ch.star:
                var e = i + 1
                while e < end, line[e] == Ch.star { e += 1 }
                if line[e] == Ch.slash, Ch.isDigit(line[e + 1]) { e += 1 }
                tokens.add(i, e, .operator)
                i = e
                statement = false
            default:
                if c == Ch.percent, line[i + 1] == Ch.lbrace,
                   let close = ConfigLexKit.find(line, Ch.rbrace, from: i + 2, limit: min(end, i + ConfigLexKit.referenceWindow)) {
                    // Apache `%{HTTP_HOST}`
                    tokens.add(i, close + 1, .variable)
                    i = close + 1
                    statement = false
                    continue
                }
                if isOperator(line, i) {
                    var e = i + 1
                    while e < end, isOperator(line, e) { e += 1 }
                    tokens.add(i, e, .operator)
                    i = e
                    statement = false
                    continue
                }
                i = lexWord(line, from: i, to: end, statement: &statement, tokens: &tokens)
            }
        }
    }

    private func lexWord(_ line: LineBuffer, from i: Int, to end: Int, statement: inout Bool, tokens: inout TokenBuffer) -> Int {
        var we = i
        while we < end, isWordChar(line, we) { we += 1 }
        if we == i { return i + 1 }
        // `remote:` / `key:` — split a trailing colon off as punctuation.
        var colon = -1
        if we - i > 1, line[we - 1] == Ch.colon {
            we -= 1
            colon = we
        }
        let c = line[i]
        if c == Ch.minus, Ch.isAlpha(line[i + 1]) || (line[i + 1] == Ch.minus && Ch.isAlpha(line[i + 2])) {
            tokens.add(i, we, .attribute)
        } else if ConfigLexKit.isNumberWord(line, i, we) || isIPv6Word(line, i, we) {
            tokens.add(i, we, .number)
        } else if statement {
            tokens.add(i, we, .keyword)
        } else if ConfigLexKit.lowercasedWord(line, i, we, in: ConfigLexKit.booleans) {
            tokens.add(i, we, .constant)
        }
        statement = false
        if colon >= 0 {
            tokens.add(colon, colon + 1, .punctuation)
            return colon + 1
        }
        return we
    }

    @inline(__always)
    private func isBoundary(_ c: UInt16) -> Bool {
        Ch.isSpace(c) || c == Ch.semicolon || c == Ch.lbrace || c == Ch.rbrace
    }

    private func isWordChar(_ line: LineBuffer, _ k: Int) -> Bool {
        let c = line[k]
        if Ch.isSpace(c) { return false }
        switch c {
        case Ch.quote, Ch.apostrophe, Ch.backtick, Ch.lbrace, Ch.rbrace, Ch.lparen, Ch.rparen, Ch.semicolon,
             Ch.comma, Ch.lbracket, Ch.rbracket, Ch.equals, Ch.lt, Ch.gt, Ch.bang, Ch.pipe, Ch.amp, Ch.star:
            return false
        case Ch.dollar:
            let n = line[k + 1]
            return !(Ch.isAlpha(n) || n == Ch.underscore || n == Ch.lbrace || n == Ch.lparen || Ch.isDigit(n))
        case Ch.percent:
            return line[k + 1] != Ch.lbrace
        default:
            return true
        }
    }

    /// `= < > ! | &` always; `~` only when it is not the start of a path (`~/…`, `~user`).
    private func isOperator(_ line: LineBuffer, _ k: Int) -> Bool {
        let c = line[k]
        switch c {
        case Ch.equals, Ch.lt, Ch.gt, Ch.bang, Ch.pipe, Ch.amp:
            return true
        case Ch.tilde:
            let n = line[k + 1]
            return !(Ch.isAlnum(n) || n == Ch.slash || n == Ch.dot || n == Ch.minus || n == Ch.underscore)
        default:
            return false
        }
    }

    /// `::1`, `fe80::1%lo0`, `2001:db8:0:0:0:0:0:1`.
    private func isIPv6Word(_ line: LineBuffer, _ s: Int, _ e: Int) -> Bool {
        var colons = 0
        var doubleColon = false
        var digits = 0
        var k = s
        while k < e {
            let c = line[k]
            if c == Ch.colon {
                colons += 1
                if line[k + 1] == Ch.colon { doubleColon = true }
            } else if c == Ch.percent {
                break
            } else if Ch.isHexDigit(c) {
                digits += 1
            } else if c != Ch.dot {
                return false
            }
            k += 1
        }
        return digits > 0 && colons >= 2 && (doubleColon || colons == 7)
    }

    // MARK: Blocks

    private func isTagStart(_ line: LineBuffer, _ i: Int) -> Bool {
        line[i] == Ch.lt && (Ch.isAlpha(line[i + 1]) || (line[i + 1] == Ch.slash && Ch.isAlpha(line[i + 2])))
    }

    /// Apache-style sections: `<Directory "/var/www">`, `</IfModule>`.
    private func lexTag(_ line: LineBuffer, from i: Int, to end: Int, tokens: inout TokenBuffer) {
        let open = line[i + 1] == Ch.slash ? 2 : 1
        tokens.add(i, i + open, .punctuation)
        var j = i + open
        while j < end, Ch.isAlnum(line[j]) || line[j] == Ch.underscore || line[j] == Ch.minus || line[j] == Ch.colon || line[j] == Ch.dot {
            j += 1
        }
        tokens.add(i + open, j, .tag)
        var close = j
        while close < end, line[close] != Ch.gt {
            if line[close] == Ch.quote {
                close = ConfigLexKit.closingQuote(line, from: close, limit: end) ?? end
            } else {
                close += 1
            }
        }
        var depth = 0
        lexStatements(line, from: j, to: min(close, end), statementStart: false, depth: &depth, tokens: &tokens)
        guard close < end else { return }
        tokens.add(close, close + 1, .punctuation)
        lexStatements(line, from: close + 1, to: end, statementStart: true, depth: &depth, tokens: &tokens)
    }

    /// `Host *.example.com` / `Match user git` in ssh configs. Returns false for other lines.
    private func lexSSHBlock(_ line: LineBuffer, from i: Int, to end: Int, tokens: inout TokenBuffer) -> Bool {
        var we = i
        while we < end, Ch.isAlpha(line[we]) { we += 1 }
        guard we >= end || Ch.isSpace(line[we]) || line[we] == Ch.equals,
              ConfigLexKit.lowercasedWord(line, i, we, in: Self.sshBlockKeywords) else { return false }
        tokens.add(i, we, .keyword)
        var j = line.skipSpaces(we)
        if j < end, line[j] == Ch.equals {
            tokens.add(j, j + 1, .operator)
            j = line.skipSpaces(j + 1)
        }
        var commentStart = end
        var k = j
        while k < end {
            if line[k] == Ch.hash, k == j || Ch.isSpace(line[k - 1]) {
                commentStart = k
                break
            }
            k += 1
        }
        var patternEnd = commentStart
        while patternEnd > j, Ch.isSpace(line[patternEnd - 1]) { patternEnd -= 1 }
        tokens.add(j, patternEnd, .section)
        tokens.add(commentStart, end, .comment)
        return true
    }
}
