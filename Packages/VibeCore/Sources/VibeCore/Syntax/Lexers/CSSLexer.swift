import Foundation

/// CSS, SCSS and Less.
///
/// State:
/// - `mode`: 0 normal, 1 inside a `/* … */` comment, 2 inside a string continued with a trailing `\`.
/// - `sub`: the syntactic context to resume with (0 statement start, 1 declaration value,
///   2 selector, 3 at-rule prelude, 4 property name).
/// - `depth`: `{ }` nesting.
/// - `data`: in mode 2 the quote (1 = `"`, 2 = `'`).
///
/// Inside blocks, a statement is a nested rule when a `{` comes before any `;` or `}` on the line,
/// and a declaration otherwise; lines that end before deciding use `name: value` vs `a:hover`.
public struct CSSLexer: SyntaxLexer {
    public enum Dialect: Sendable {
        case css, scss, less
    }

    public let dialect: Dialect

    public init(dialect: Dialect = .css) {
        self.dialect = dialect
    }

    enum Mode {
        static let normal: UInt8 = 0
        static let comment: UInt8 = 1
        static let string: UInt8 = 2
    }

    enum Context: UInt8 {
        case statement = 0, value, selector, prelude, property
    }

    struct Scan {
        var ctx: Context
        var depth: Int
        /// The next identifier names a mixin/function/animation (`@mixin name`, `@keyframes spin`).
        var functionNext = false
        /// The at-rule prelude contains selectors (`@extend .a`, `@page :first`, `@at-root .b`).
        var preludeSelectors = false
        /// Open parentheses in a selector (`:nth-child(`, `:not(`, Less guards): names inside are values.
        var pseudoParens = 0
    }

    private static let commentOpen = u16("/*")
    private static let commentClose = u16("*/")
    private static let url = u16("url")
    private static let urlOpen = u16("url(")
    private static let functionAtRules = ConfigLexKit.words("mixin include function keyframes -webkit-keyframes -moz-keyframes -o-keyframes")
    private static let selectorAtRules = ConfigLexKit.words("extend page at-root")
    private static let keyframeSelectors: Set<String> = ["from", "to"]
    private static let lessGuardWords: Set<String> = ["when", "and", "not"]
    private static let preludeKeywords = ConfigLexKit.words("and or not only from through to in as with show hide of using if else when")
    private static let pseudoClasses = ConfigLexKit.words("""
    hover active focus focus-within focus-visible visited link any-link target root empty checked disabled enabled
    required optional valid invalid in-range out-of-range read-only read-write placeholder-shown indeterminate
    first-child last-child only-child first-of-type last-of-type only-of-type nth-child nth-last-child nth-of-type
    nth-last-of-type not is where has lang dir host host-context before after first-line first-letter selection
    placeholder marker backdrop part slotted fullscreen modal autofill
    """)

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        let st = state.main
        let end = line.end
        var i = line.start
        var scan = Scan(ctx: Context(rawValue: st.sub) ?? .statement, depth: Int(st.depth))

        if st.mode == Mode.comment {
            guard let close = line.find(Self.commentClose, from: i) else {
                tokens.add(i, end, .comment)
                return
            }
            tokens.add(i, close + 2, .comment)
            i = close + 2
        } else if st.mode == Mode.string {
            let quote = st.data == 2 ? Ch.apostrophe : Ch.quote
            guard let after = scanString(line, from: i, tokenStart: i, quote: quote, tokens: &tokens) else {
                if !continuesString(line) { state.main = LexState(sub: scan.ctx.rawValue, depth: st.depth) }
                return
            }
            i = after
        }

        while i < end {
            let c = line[i]
            if Ch.isSpace(c) {
                i += 1
                continue
            }
            if c == Ch.slash, line[i + 1] == Ch.star {
                guard let close = line.find(Self.commentClose, from: i + 2) else {
                    tokens.add(i, end, .comment)
                    state.main = LexState(mode: Mode.comment, sub: scan.ctx.rawValue, depth: UInt16(clamping: scan.depth))
                    return
                }
                tokens.add(i, close + 2, .comment)
                i = close + 2
                continue
            }
            if c == Ch.slash, line[i + 1] == Ch.slash, dialect != .css {
                tokens.add(i, end, .comment)
                break
            }
            if scan.ctx == .statement {
                switch c {
                case Ch.rbrace:
                    tokens.add(i, i + 1, .punctuation)
                    scan.depth = max(0, scan.depth - 1)
                    i += 1
                case Ch.lbrace:
                    tokens.add(i, i + 1, .punctuation)
                    scan.depth += 1
                    i += 1
                case Ch.semicolon:
                    tokens.add(i, i + 1, .punctuation)
                    i += 1
                default:
                    scan.ctx = classify(line, at: i, end: end)
                    scan.pseudoParens = 0
                    if scan.ctx == .prelude {
                        var ne = i + 1
                        while ne < end, isNameChar(line[ne]) { ne += 1 }
                        tokens.add(i, ne, .keyword)
                        let name = ne - i <= 20 ? line.lowercasedString(i + 1, ne) : ""
                        scan.functionNext = Self.functionAtRules.contains(name)
                        scan.preludeSelectors = Self.selectorAtRules.contains(name)
                        i = ne
                    }
                }
                continue
            }
            if c == Ch.quote || c == Ch.apostrophe {
                guard let after = scanString(line, from: i + 1, tokenStart: i, quote: c, tokens: &tokens) else {
                    if continuesString(line) {
                        state.main = LexState(mode: Mode.string, sub: scan.ctx.rawValue, depth: UInt16(clamping: scan.depth),
                                              data: c == Ch.apostrophe ? 2 : 1)
                        return
                    }
                    i = end
                    continue
                }
                i = after
                continue
            }
            switch c {
            case Ch.lbrace:
                tokens.add(i, i + 1, .punctuation)
                scan.depth += 1
                scan.ctx = .statement
                i += 1
                continue
            case Ch.rbrace:
                tokens.add(i, i + 1, .punctuation)
                scan.depth = max(0, scan.depth - 1)
                scan.ctx = .statement
                i += 1
                continue
            case Ch.semicolon:
                tokens.add(i, i + 1, .punctuation)
                scan.ctx = .statement
                i += 1
                continue
            default:
                break
            }
            switch scan.ctx {
            case .selector:
                i = lexSelector(line, at: i, end: end, scan: &scan, tokens: &tokens)
            case .property:
                if c == Ch.colon {
                    tokens.add(i, i + 1, .punctuation)
                    scan.ctx = .value
                    i += 1
                } else {
                    i = lexPropertyName(line, at: i, end: end, scan: &scan, tokens: &tokens)
                }
            case .value, .prelude, .statement:
                i = lexValue(line, at: i, end: end, scan: &scan, tokens: &tokens)
            }
        }
        state.main = LexState(sub: scan.ctx.rawValue, depth: UInt16(clamping: scan.depth))
    }

    // MARK: Statements

    /// Decides what the statement starting at `i` is.
    private func classify(_ line: LineBuffer, at i: Int, end: Int) -> Context {
        let c = line[i]
        if c == Ch.at {
            if line[i + 1] == Ch.lbrace { return .selector }
            if dialect == .less {
                var ne = i + 1
                while ne < end, isNameChar(line[ne]) { ne += 1 }
                if ne > i + 1, line[line.skipSpaces(ne)] == Ch.colon { return .property }
            }
            return .prelude
        }
        if dialect == .scss, c == Ch.dollar { return .property }
        if c == Ch.minus, line[i + 1] == Ch.minus { return .property }
        let selectorStart = c == Ch.dot || (c == Ch.hash && line[i + 1] != Ch.lbrace) || c == Ch.amp || c == Ch.colon
            || c == Ch.lbracket || c == Ch.gt || c == Ch.plus || c == Ch.tilde || c == Ch.percent
        // Same units as the lexer: strings, comments, interpolations and unquoted `url(…)` are skipped
        // whole, so each statement start is classified by scanning only up to its own end.
        var j = i
        scanning: while j < end {
            let d = line[j]
            switch d {
            case Ch.quote, Ch.apostrophe:
                j = ConfigLexKit.closingQuote(line, from: j, limit: end) ?? end
                continue
            case Ch.slash:
                if line[j + 1] == Ch.star {
                    j = (ConfigLexKit.find(line, Self.commentClose, from: j + 2, limit: end) ?? end) + 2
                    continue
                }
                if line[j + 1] == Ch.slash, dialect != .css { break scanning }
            case Ch.hash, Ch.at:
                if line[j + 1] == Ch.lbrace, let close = interpolationEnd(line, from: j, end: end) {
                    j = close + 1
                    continue
                }
            case 0x75, 0x55:
                let arg = line.skipSpaces(j + 4)
                if line.matchesIgnoringCase(Self.urlOpen, at: j), j == i || !isNameChar(line[j - 1]),
                   line[arg] != Ch.quote, line[arg] != Ch.apostrophe {
                    guard let close = ConfigLexKit.find(line, Ch.rparen, from: j + 4, limit: end) else { break scanning }
                    j = close + 1
                    continue
                }
            case Ch.lbrace:
                return .selector
            case Ch.semicolon, Ch.rbrace:
                return selectorStart ? .selector : .property
            default:
                break
            }
            j += 1
        }
        return selectorStart ? .selector : ambiguous(line, from: i, end: min(j, end))
    }

    /// For a statement that does not end on this line: `name: value` is a declaration, `a:hover` a selector.
    private func ambiguous(_ line: LineBuffer, from i: Int, end: Int) -> Context {
        var j = i
        var parens = 0
        while j < end {
            let d = line[j]
            if d == Ch.quote || d == Ch.apostrophe {
                j = ConfigLexKit.closingQuote(line, from: j, limit: end) ?? end
                continue
            }
            if d == Ch.lparen || d == Ch.lbracket { parens += 1 }
            if d == Ch.rparen || d == Ch.rbracket { parens = max(0, parens - 1) }
            if d == Ch.colon, parens == 0 {
                let n = line[j + 1]
                if n == Ch.colon { return .selector }
                if j + 1 >= end || Ch.isSpace(n) { return .property }
                var we = j + 1
                while we < end, isNameChar(line[we]) { we += 1 }
                return ConfigLexKit.lowercasedWord(line, j + 1, we, in: Self.pseudoClasses) ? .selector : .property
            }
            j += 1
        }
        return .selector
    }

    // MARK: Names

    @inline(__always)
    private func isNameStart(_ c: UInt16) -> Bool {
        Ch.isAlpha(c) || c == Ch.underscore || (c >= 0x80 && !Ch.isSpace(c))
    }

    @inline(__always)
    private func isNameChar(_ c: UInt16) -> Bool {
        isNameStart(c) || Ch.isDigit(c) || c == Ch.minus
    }

    /// A name (after an optional `.`, `#`, `%`, `$`, `@` or `--` prefix) that may contain `#{…}`
    /// (SCSS) or `@{…}` (Less) interpolations and `\` escapes.
    private func lexName(_ line: LineBuffer, from s: Int, prefix: Int, end: Int, kind: TokenKind, tokens: inout TokenBuffer) -> Int {
        var k = s + prefix
        var seg = s
        while k < end {
            let c = line[k]
            if c == Ch.hash, dialect == .scss, line[k + 1] == Ch.lbrace, let close = interpolationEnd(line, from: k, end: end) {
                tokens.add(seg, k, kind)
                emitInterpolation(line, k, close, tokens: &tokens)
                k = close + 1
                seg = k
                continue
            }
            if c == Ch.at, dialect == .less, line[k + 1] == Ch.lbrace, let close = interpolationEnd(line, from: k, end: end) {
                tokens.add(seg, k, kind)
                tokens.add(k, close + 1, .variable)
                k = close + 1
                seg = k
                continue
            }
            if c == Ch.backslash, k + 1 < end {
                k += 2
                continue
            }
            if isNameChar(c) {
                k += 1
                continue
            }
            break
        }
        tokens.add(seg, k, kind)
        return max(k, s + 1)
    }

    /// Index of the `}` closing the `#{` / `@{` at `k`.
    private func interpolationEnd(_ line: LineBuffer, from k: Int, end: Int) -> Int? {
        ConfigLexKit.find(line, Ch.rbrace, from: k + 2, limit: min(end, k + ConfigLexKit.referenceWindow))
    }

    private func emitInterpolation(_ line: LineBuffer, _ open: Int, _ close: Int, tokens: inout TokenBuffer) {
        tokens.add(open, open + 2, .escape)
        tokens.add(open + 2, close, .variable)
        tokens.add(close, close + 1, .escape)
    }

    // MARK: Selectors

    private func lexSelector(_ line: LineBuffer, at i: Int, end: Int, scan: inout Scan, tokens: inout TokenBuffer) -> Int {
        let c = line[i]
        let n = line[i + 1]
        switch c {
        case Ch.dot:
            let interpolation = (n == Ch.hash || n == Ch.at) && line[i + 2] == Ch.lbrace
            if isNameStart(n) || n == Ch.minus || n == Ch.backslash || interpolation {
                return lexName(line, from: i, prefix: 1, end: end, kind: .attribute, tokens: &tokens)
            }
            if Ch.isDigit(n) {
                let e = scanNumber(line, at: i, end: end)
                tokens.add(i, e, .number)
                return e
            }
            return i + 1
        case Ch.hash:
            if dialect == .scss, n == Ch.lbrace, let close = interpolationEnd(line, from: i, end: end) {
                emitInterpolation(line, i, close, tokens: &tokens)
                return close + 1
            }
            if isNameChar(n) || n == Ch.backslash {
                return lexName(line, from: i, prefix: 1, end: end, kind: .attribute, tokens: &tokens)
            }
            return i + 1
        case Ch.percent:
            if dialect == .scss, isNameStart(n) {
                return lexName(line, from: i, prefix: 1, end: end, kind: .attribute, tokens: &tokens)
            }
            tokens.add(i, i + 1, .operator)
            return i + 1
        case Ch.colon:
            var k = i + 1
            if line[k] == Ch.colon { k += 1 }
            var ne = k
            while ne < end, isNameChar(line[ne]) { ne += 1 }
            guard ne > k else {
                tokens.add(i, k, .punctuation)
                return k
            }
            tokens.add(i, ne, .keyword)
            if line[ne] == Ch.lparen {
                tokens.add(ne, ne + 1, .punctuation)
                scan.pseudoParens += 1
                return ne + 1
            }
            return ne
        case Ch.lbracket:
            return lexAttributeSelector(line, at: i, end: end, tokens: &tokens)
        case Ch.amp:
            tokens.add(i, i + 1, .keyword)
            var ne = i + 1
            while ne < end, isNameChar(line[ne]) { ne += 1 }
            tokens.add(i + 1, ne, .attribute)
            return ne
        case Ch.star, Ch.gt, Ch.plus, Ch.tilde, Ch.pipe:
            tokens.add(i, i + 1, .operator)
            return i + 1
        case Ch.comma:
            tokens.add(i, i + 1, .punctuation)
            return i + 1
        case Ch.lparen:
            tokens.add(i, i + 1, .punctuation)
            scan.pseudoParens += 1
            return i + 1
        case Ch.equals, Ch.lt:
            tokens.add(i, i + 1, .operator)
            return i + 1
        case Ch.rparen:
            tokens.add(i, i + 1, .punctuation)
            scan.pseudoParens = max(0, scan.pseudoParens - 1)
            return i + 1
        case Ch.at:
            if n == Ch.lbrace, let close = interpolationEnd(line, from: i, end: end) {
                tokens.add(i, close + 1, .variable)
                return close + 1
            }
            if isNameStart(n) {
                return lexName(line, from: i, prefix: 1, end: end, kind: .variable, tokens: &tokens)
            }
            return i + 1
        case Ch.dollar:
            if isNameStart(n) {
                return lexName(line, from: i, prefix: 1, end: end, kind: .variable, tokens: &tokens)
            }
            return i + 1
        case Ch.backslash:
            let e = min(i + 2, end)
            tokens.add(i, e, .escape)
            return e
        default:
            break
        }
        if Ch.isDigit(c) {
            let e = scanNumber(line, at: i, end: end)
            tokens.add(i, e, .number)
            return e
        }
        if isNameStart(c) || c == Ch.minus {
            var ne = i + 1
            while ne < end, isNameChar(line[ne]) { ne += 1 }
            let kind: TokenKind
            if scan.pseudoParens > 0 {
                kind = .constant
            } else if ConfigLexKit.word(line, i, ne, in: Self.keyframeSelectors)
                        || (dialect == .less && ConfigLexKit.word(line, i, ne, in: Self.lessGuardWords)) {
                kind = .keyword
            } else {
                kind = .tag
            }
            if line[ne] == Ch.hash, dialect == .scss, line[ne + 1] == Ch.lbrace {
                return lexName(line, from: i, prefix: 0, end: end, kind: kind, tokens: &tokens)
            }
            tokens.add(i, ne, kind)
            return ne
        }
        return i + 1
    }

    /// `[type="text" i]`
    private func lexAttributeSelector(_ line: LineBuffer, at i: Int, end: Int, tokens: inout TokenBuffer) -> Int {
        tokens.add(i, i + 1, .punctuation)
        var k = line.skipSpaces(i + 1)
        var ne = k
        while ne < end, isNameChar(line[ne]) || line[ne] == Ch.pipe { ne += 1 }
        tokens.add(k, ne, .attribute)
        k = line.skipSpaces(ne)
        var oe = k
        while oe < end, line[oe] == Ch.tilde || line[oe] == Ch.pipe || line[oe] == Ch.caret || line[oe] == Ch.dollar
                || line[oe] == Ch.star || line[oe] == Ch.equals { oe += 1 }
        if oe > k {
            tokens.add(k, oe, .operator)
            k = line.skipSpaces(oe)
            if k < end, line[k] == Ch.quote || line[k] == Ch.apostrophe {
                let close = ConfigLexKit.closingQuote(line, from: k, limit: end) ?? end
                ConfigLexKit.addEscaped(line, k, close, tokens: &tokens)
                k = close
            } else {
                var ve = k
                while ve < end, line[ve] != Ch.rbracket, !Ch.isSpace(line[ve]) { ve += 1 }
                tokens.add(k, ve, .string)
                k = ve
            }
            k = line.skipSpaces(k)
            if k < end, Ch.isAlpha(line[k]), line[k + 1] == Ch.rbracket || Ch.isSpace(line[k + 1]) {
                tokens.add(k, k + 1, .keyword)
                k = line.skipSpaces(k + 1)
            }
        }
        if k < end, line[k] == Ch.rbracket {
            tokens.add(k, k + 1, .punctuation)
            return k + 1
        }
        return max(k, i + 1)
    }

    // MARK: Declarations

    private func lexPropertyName(_ line: LineBuffer, at i: Int, end: Int, scan: inout Scan, tokens: inout TokenBuffer) -> Int {
        let c = line[i]
        let n = line[i + 1]
        if c == Ch.minus, n == Ch.minus {
            return lexName(line, from: i, prefix: 2, end: end, kind: .variable, tokens: &tokens)
        }
        if (c == Ch.dollar && dialect == .scss) || (c == Ch.at && dialect == .less) {
            return lexName(line, from: i, prefix: 1, end: end, kind: .variable, tokens: &tokens)
        }
        if c == Ch.star || c == Ch.underscore {
            // IE hacks: *zoom, _height
            return lexName(line, from: i, prefix: 1, end: end, kind: .property, tokens: &tokens)
        }
        if isNameStart(c) || c == Ch.minus || (c == Ch.hash && n == Ch.lbrace) || (c == Ch.at && n == Ch.lbrace) {
            return lexName(line, from: i, prefix: 0, end: end, kind: .property, tokens: &tokens)
        }
        return lexValue(line, at: i, end: end, scan: &scan, tokens: &tokens)
    }

    /// Declaration values and at-rule preludes.
    private func lexValue(_ line: LineBuffer, at i: Int, end: Int, scan: inout Scan, tokens: inout TokenBuffer) -> Int {
        let prelude = scan.ctx == .prelude
        let c = line[i]
        let n = line[i + 1]
        switch c {
        case Ch.hash:
            if dialect == .scss, n == Ch.lbrace, let close = interpolationEnd(line, from: i, end: end) {
                emitInterpolation(line, i, close, tokens: &tokens)
                return close + 1
            }
            var k = i + 1
            while k < end, Ch.isHexDigit(line[k]) { k += 1 }
            let count = k - i - 1
            if count == 3 || count == 4 || count == 6 || count == 8, !isNameChar(line[k]) {
                tokens.add(i, k, .constant)
                return k
            }
            if prelude, isNameChar(n) {
                return lexName(line, from: i, prefix: 1, end: end, kind: .attribute, tokens: &tokens)
            }
            return i + 1
        case Ch.dollar:
            if isNameStart(n) || n == Ch.minus {
                return lexName(line, from: i, prefix: 1, end: end, kind: .variable, tokens: &tokens)
            }
            return i + 1
        case Ch.at:
            if n == Ch.lbrace, let close = interpolationEnd(line, from: i, end: end) {
                tokens.add(i, close + 1, .variable)
                return close + 1
            }
            if isNameStart(n) || n == Ch.at {
                let start = n == Ch.at ? i + 1 : i
                if start > i { tokens.add(i, start, .variable) }
                return lexName(line, from: start, prefix: 1, end: end, kind: .variable, tokens: &tokens)
            }
            return i + 1
        case Ch.bang:
            let k = line.skipSpaces(i + 1)
            if k < end, Ch.isAlpha(line[k]) {
                var ne = k
                while ne < end, Ch.isAlpha(line[ne]) { ne += 1 }
                tokens.add(i, ne, .keyword)
                return ne
            }
            var e = i + 1
            if line[e] == Ch.equals { e += 1 }
            tokens.add(i, e, .operator)
            return e
        case Ch.comma, Ch.lparen, Ch.rparen, Ch.lbracket, Ch.rbracket:
            tokens.add(i, i + 1, .punctuation)
            return i + 1
        case Ch.colon:
            if prelude, scan.preludeSelectors, isNameStart(n) {
                var ne = i + 1
                while ne < end, isNameChar(line[ne]) { ne += 1 }
                tokens.add(i, ne, .keyword)
                return ne
            }
            tokens.add(i, i + 1, .punctuation)
            return i + 1
        case Ch.amp:
            tokens.add(i, i + 1, .keyword)
            return i + 1
        case Ch.backslash:
            let e = min(i + 2, end)
            tokens.add(i, e, .escape)
            return e
        case Ch.dot:
            if Ch.isDigit(n) {
                let e = scanNumber(line, at: i, end: end)
                tokens.add(i, e, .number)
                return e
            }
            if prelude, isNameStart(n) || n == Ch.minus {
                return lexName(line, from: i, prefix: 1, end: end, kind: .attribute, tokens: &tokens)
            }
            return i + 1
        case Ch.percent:
            if prelude, dialect == .scss, isNameStart(n) {
                return lexName(line, from: i, prefix: 1, end: end, kind: .attribute, tokens: &tokens)
            }
            tokens.add(i, i + 1, .operator)
            return i + 1
        case Ch.plus, Ch.minus:
            let signedNumber = Ch.isDigit(n) || (n == Ch.dot && Ch.isDigit(line[i + 2]))
            if signedNumber, i == line.start || !isNameChar(line[i - 1]) {
                let e = scanNumber(line, at: i, end: end)
                tokens.add(i, e, .number)
                return e
            }
            if c == Ch.minus, n == Ch.minus, isNameStart(line[i + 2]) || line[i + 2] == Ch.minus {
                return lexName(line, from: i, prefix: 2, end: end, kind: .variable, tokens: &tokens)
            }
            if c == Ch.minus, isNameStart(n) {
                return lexIdentifier(line, at: i, end: end, scan: &scan, tokens: &tokens)
            }
            tokens.add(i, i + 1, .operator)
            return i + 1
        default:
            break
        }
        if Ch.isDigit(c) {
            let e = scanNumber(line, at: i, end: end)
            tokens.add(i, e, .number)
            return e
        }
        if isNameStart(c) {
            return lexIdentifier(line, at: i, end: end, scan: &scan, tokens: &tokens)
        }
        if Ch.isOperator(c) || c == Ch.equals {
            var e = i + 1
            while e < end, line[e] == Ch.equals { e += 1 }
            tokens.add(i, e, .operator)
            return e
        }
        return i + 1
    }

    /// Keywords, functions (`rgb(`, `var(`, `url(…)`), media features and other value identifiers.
    private func lexIdentifier(_ line: LineBuffer, at i: Int, end: Int, scan: inout Scan, tokens: inout TokenBuffer) -> Int {
        var ne = i + 1
        while ne < end, isNameChar(line[ne]) { ne += 1 }
        // SCSS module functions: math.div(…)
        if line[ne] == Ch.dot, isNameStart(line[ne + 1]) {
            var me = ne + 1
            while me < end, isNameChar(line[me]) { me += 1 }
            if line[me] == Ch.lparen { ne = me }
        }
        if line[ne] == Ch.hash, dialect == .scss, line[ne + 1] == Ch.lbrace {
            return lexName(line, from: i, prefix: 0, end: end, kind: .constant, tokens: &tokens)
        }
        if line[ne] == Ch.lparen {
            tokens.add(i, ne, .function)
            scan.functionNext = false
            if ne - i == 3, line.matchesIgnoringCase(Self.url, at: i) {
                let s = line.skipSpaces(ne + 1)
                if line[s] != Ch.quote, line[s] != Ch.apostrophe {
                    tokens.add(ne, ne + 1, .punctuation)
                    guard let close = ConfigLexKit.find(line, Ch.rparen, from: s, limit: end) else {
                        tokens.add(s, end, .string)
                        return end
                    }
                    var te = close
                    while te > s, Ch.isSpace(line[te - 1]) { te -= 1 }
                    tokens.add(s, te, .string)
                    tokens.add(close, close + 1, .punctuation)
                    return close + 1
                }
            }
            return ne
        }
        guard scan.ctx == .prelude else {
            tokens.add(i, ne, .constant)
            return ne
        }
        let next = line.skipSpaces(ne)
        if line[next] == Ch.colon, line[next + 1] != Ch.colon {
            tokens.add(i, ne, .property)
        } else if scan.functionNext {
            tokens.add(i, ne, .function)
            scan.functionNext = false
        } else if ConfigLexKit.lowercasedWord(line, i, ne, in: Self.preludeKeywords) {
            tokens.add(i, ne, .keyword)
        } else {
            tokens.add(i, ne, .constant)
        }
        return ne
    }

    /// `10px`, `1.5em`, `-2px`, `.5s`, `50%`, `1e3`.
    private func scanNumber(_ line: LineBuffer, at i: Int, end: Int) -> Int {
        var k = i
        if line[k] == Ch.plus || line[k] == Ch.minus { k += 1 }
        while k < end, Ch.isDigit(line[k]) { k += 1 }
        if line[k] == Ch.dot, Ch.isDigit(line[k + 1]) {
            k += 1
            while k < end, Ch.isDigit(line[k]) { k += 1 }
        }
        if line[k] == Ch.e || line[k] == 0x45 {
            let m = line[k + 1] == Ch.plus || line[k + 1] == Ch.minus ? k + 2 : k + 1
            if Ch.isDigit(line[m]) {
                k = m
                while k < end, Ch.isDigit(line[k]) { k += 1 }
            }
        }
        if line[k] == Ch.percent {
            k += 1
        } else {
            while k < end, Ch.isAlpha(line[k]) { k += 1 }
        }
        return min(max(k, i + 1), end)
    }

    // MARK: Strings

    private func continuesString(_ line: LineBuffer) -> Bool {
        line.end > line.start && line[line.end - 1] == Ch.backslash
    }

    /// Scans a string body from `start` (tokens start at `tokenStart`). Returns the index after the
    /// closing quote, or nil when the line ends first.
    private func scanString(_ line: LineBuffer, from start: Int, tokenStart: Int, quote: UInt16, tokens: inout TokenBuffer) -> Int? {
        let end = line.end
        var seg = tokenStart
        var j = start
        while j < end {
            let c = line[j]
            if c == Ch.backslash {
                guard j + 1 < end else { break }
                tokens.add(seg, j, .string)
                var e = j + 1
                if Ch.isHexDigit(line[e]) {
                    while e < end, e < j + 7, Ch.isHexDigit(line[e]) { e += 1 }
                } else {
                    e += 1
                }
                tokens.add(j, e, .escape)
                j = e
                seg = e
                continue
            }
            if c == quote {
                tokens.add(seg, j + 1, .string)
                return j + 1
            }
            if c == Ch.hash, dialect == .scss, line[j + 1] == Ch.lbrace, let close = interpolationEnd(line, from: j, end: end) {
                tokens.add(seg, j, .string)
                emitInterpolation(line, j, close, tokens: &tokens)
                j = close + 1
                seg = j
                continue
            }
            if c == Ch.at, dialect == .less, line[j + 1] == Ch.lbrace, let close = interpolationEnd(line, from: j, end: end) {
                tokens.add(seg, j, .string)
                tokens.add(j, close + 1, .variable)
                j = close + 1
                seg = j
                continue
            }
            j += 1
        }
        tokens.add(seg, end, .string)
        return nil
    }
}
