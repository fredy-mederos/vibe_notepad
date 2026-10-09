import Foundation

/// Bash, zsh and POSIX shell scripts.
///
/// State:
/// - `mode`: 0 normal, 1 inside `'…'`, 2 inside `"…"`, 3 inside `$'…'`, 4 heredoc body with
///   expansions, 5 heredoc body without expansions (quoted delimiter).
/// - `sub` flags: 1 = the previous line ended with a `\` continuation in the middle of a command (so
///   this line does not start in command position), 2 = `<<-` heredoc (tab-indented terminator), 4 = a `case` pattern is
///   expected, 8 = inside a multi-line array assignment `a=( … )`.
/// - `depth`: nesting of `case … esac`.
/// - `data`: FNV-1a hash of the heredoc delimiter.
public struct ShellLexer: SyntaxLexer {
    public init() {}

    enum Mode {
        static let normal: UInt8 = 0
        static let singleQuoted: UInt8 = 1
        static let doubleQuoted: UInt8 = 2
        static let ansiQuoted: UInt8 = 3
        static let heredoc: UInt8 = 4
        static let heredocLiteral: UInt8 = 5
    }

    enum Flag {
        static let continuation: UInt8 = 1
        static let stripTabs: UInt8 = 2
        static let casePattern: UInt8 = 4
        static let array: UInt8 = 8
    }

    /// Whether a shell lexer state is inside a heredoc body (used by the Dockerfile lexer).
    static func isInHeredoc(_ state: LexState) -> Bool {
        state.mode == Mode.heredoc || state.mode == Mode.heredocLiteral
    }

    /// Deepest nesting of `$( … )`, backticks and quotes that is lexed recursively.
    private static let maxNesting = 12
    /// Longest span searched for the parenthesis closing a `$(`.
    private static let parenWindow = 4096

    private static let keywords = ConfigLexKit.words("""
    if then else elif fi case esac for select while until do done in function time coproc [[ ]]
    """)
    /// Commands whose first non-option argument is itself a command.
    private static let prefixCommands = ConfigLexKit.words("sudo doas exec time xargs env nohup nice command builtin")
    /// Builtins whose `NAME=value` / `NAME` arguments declare variables.
    private static let declarationCommands = ConfigLexKit.words("export local declare readonly typeset unset alias")
    private static let testOperators: Set<String> = ["=", "==", "!=", "=~", "<", ">"]

    struct Context {
        var cmdPos = true
        var expectIn = false
        var expectName = false
        var expectFunctionName = false
        var caseHeader = false
        var declaration = false
        var redirectTarget = false
        var casePattern = false
        var caseDepth = 0
        var testDepth = 0
        var arrayDepth = 0
        /// End of the assignment value being lexed: parts glued to it belong to the value.
        var assignmentEnd = -1
        // Results carried to the next line (top level only).
        var heredoc: (hash: Int32, quoted: Bool, strip: Bool)?
        var openString: UInt8 = 0
        var continuation = false

        mutating func startCommand() {
            cmdPos = true
            expectIn = false
            expectName = false
            expectFunctionName = false
            caseHeader = false
            declaration = false
            redirectTarget = false
            assignmentEnd = -1
        }

        /// A string or expansion was lexed at `end`.
        mutating func value(glued: Bool, end: Int) {
            if glued {
                assignmentEnd = end
            } else {
                cmdPos = false
                redirectTarget = false
                assignmentEnd = -1
            }
        }
    }

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        let st = state.main
        let end = line.end
        var i = line.start
        var ctx = Context()
        // Bounds the lookahead scans for `$(`/`((` closers so that long lines stay linear.
        var budget = 32 * line.length + 4096
        ctx.caseDepth = Int(st.depth)
        ctx.casePattern = st.sub & Flag.casePattern != 0
        ctx.cmdPos = st.sub & (Flag.continuation | Flag.array) == 0
        if st.sub & Flag.array != 0 { ctx.arrayDepth = 1 }

        switch st.mode {
        case Mode.heredoc, Mode.heredocLiteral:
            lexHeredocLine(line, state: &state.main, tokens: &tokens)
            return
        case Mode.singleQuoted, Mode.ansiQuoted:
            let ansi = st.mode == Mode.ansiQuoted
            guard let close = scanSingleQuoted(line, from: i, tokenStart: i, ansi: ansi, limit: end, tokens: &tokens) else {
                return
            }
            i = close
            ctx.cmdPos = false
        case Mode.doubleQuoted:
            guard let close = scanDoubleQuoted(line, from: i, tokenStart: i, limit: end, level: 0,
                                               budget: &budget, tokens: &tokens) else {
                return
            }
            i = close
            ctx.cmdPos = false
        default:
            if line[i] == Ch.hash, line[i + 1] == Ch.bang {
                tokens.add(i, line.trimmedEnd, .meta)
                state.main = LexState(depth: st.depth)
                return
            }
        }

        lexCommands(line, from: i, to: end, ctx: &ctx, level: 0, budget: &budget, tokens: &tokens)

        var next = LexState()
        next.depth = UInt16(clamping: max(0, ctx.caseDepth))
        if ctx.openString != 0 {
            next.mode = ctx.openString
        } else if let heredoc = ctx.heredoc {
            next.mode = heredoc.quoted ? Mode.heredocLiteral : Mode.heredoc
            next.data = heredoc.hash
            if heredoc.strip { next.sub |= Flag.stripTabs }
        }
        if ctx.continuation { next.sub |= Flag.continuation }
        if ctx.casePattern { next.sub |= Flag.casePattern }
        if ctx.arrayDepth > 0 { next.sub |= Flag.array }
        state.main = next
    }

    // MARK: Heredocs

    private func lexHeredocLine(_ line: LineBuffer, state st: inout LexState, tokens: inout TokenBuffer) {
        var s = line.start
        if st.sub & Flag.stripTabs != 0 {
            while s < line.end, line[s] == Ch.tab { s += 1 }
        }
        let e = ConfigLexKit.contentEnd(line)
        var quoting = false
        var k = s
        while k < e {
            let c = line[k]
            if c == Ch.quote || c == Ch.apostrophe || c == Ch.backslash {
                quoting = true
                break
            }
            k += 1
        }
        if !quoting, ConfigLexKit.delimiterHash(line, s, e) == st.data {
            tokens.add(s, e, .meta)
            st = LexState(depth: st.depth)
            return
        }
        if st.mode == Mode.heredocLiteral {
            tokens.add(line.start, line.end, .string)
        } else {
            var budget = 32 * line.length + 4096
            _ = scanDoubleQuoted(line, from: line.start, tokenStart: line.start, limit: line.end, closes: false, level: 0,
                                 budget: &budget, tokens: &tokens)
        }
    }

    // MARK: Commands

    private func lexCommands(_ line: LineBuffer, from start: Int, to end: Int, ctx: inout Context, level: Int,
                             budget: inout Int, tokens: inout TokenBuffer) {
        var i = start
        while i < end {
            let c = line[i]
            if Ch.isSpace(c) {
                i += 1
                continue
            }
            let glued = i == ctx.assignmentEnd
            if c == Ch.hash, i == start || isCommentBoundary(line[i - 1]) {
                tokens.add(i, end, .comment)
                return
            }
            switch c {
            case Ch.backslash:
                if i + 1 >= end || (line[i + 1] == Ch.cr && i + 2 >= end) {
                    // A continuation after `&&`, `|`… still expects a command on the next line.
                    tokens.add(i, i + 1, .escape)
                    if level == 0 { ctx.continuation = !ctx.cmdPos }
                    return
                }
                tokens.add(i, i + 2, .escape)
                i += 2
                if glued { ctx.assignmentEnd = i } else { ctx.cmdPos = false }
                continue
            case Ch.apostrophe:
                guard let close = scanSingleQuoted(line, from: i + 1, tokenStart: i, ansi: false, limit: end, tokens: &tokens) else {
                    if level == 0 { ctx.openString = Mode.singleQuoted }
                    return
                }
                i = close
                ctx.value(glued: glued, end: i)
                continue
            case Ch.quote:
                guard let close = scanDoubleQuoted(line, from: i + 1, tokenStart: i, limit: end, level: level,
                                                   budget: &budget, tokens: &tokens) else {
                    if level == 0 { ctx.openString = Mode.doubleQuoted }
                    return
                }
                i = close
                ctx.value(glued: glued, end: i)
                continue
            case Ch.dollar:
                let n = i + 1 < end ? line[i + 1] : 0
                if n == Ch.apostrophe {
                    guard let close = scanSingleQuoted(line, from: i + 2, tokenStart: i, ansi: true, limit: end, tokens: &tokens) else {
                        if level == 0 { ctx.openString = Mode.ansiQuoted }
                        return
                    }
                    i = close
                    ctx.value(glued: glued, end: i)
                    continue
                }
                if n == Ch.quote {
                    guard let close = scanDoubleQuoted(line, from: i + 2, tokenStart: i, limit: end, level: level,
                                                       budget: &budget, tokens: &tokens) else {
                        if level == 0 { ctx.openString = Mode.doubleQuoted }
                        return
                    }
                    i = close
                    ctx.value(glued: glued, end: i)
                    continue
                }
                if isExpansionStart(line, i, limit: end) {
                    let r = lexDollar(line, at: i, limit: end, level: level, budget: &budget, tokens: &tokens)
                    i = r.end
                    if r.openCommand {
                        ctx.startCommand()
                    } else {
                        ctx.value(glued: glued, end: i)
                    }
                    continue
                }
            case Ch.backtick:
                if let close = backtickEnd(line, from: i, limit: end) {
                    lexBackticks(line, i, close, level: level, budget: &budget, tokens: &tokens)
                    i = close + 1
                    ctx.value(glued: glued, end: i)
                } else {
                    tokens.add(i, i + 1, .variable)
                    i += 1
                    ctx.startCommand()
                }
                continue
            case Ch.semicolon:
                var e = i + 1
                if e < end, line[e] == Ch.semicolon {
                    e += 1
                    if e < end, line[e] == Ch.amp { e += 1 }
                } else if e < end, line[e] == Ch.amp {
                    e += 1
                }
                tokens.add(i, e, .operator)
                ctx.startCommand()
                if e - i >= 2, ctx.caseDepth > 0 { ctx.casePattern = true }
                i = e
                continue
            case Ch.pipe:
                var e = i + 1
                if e < end, line[e] == Ch.pipe || line[e] == Ch.amp { e += 1 }
                tokens.add(i, e, .operator)
                if !ctx.casePattern, ctx.testDepth == 0 { ctx.startCommand() }
                i = e
                continue
            case Ch.amp:
                if i + 1 < end, line[i + 1] == Ch.gt {
                    var e = i + 2
                    if e < end, line[e] == Ch.gt { e += 1 }
                    tokens.add(i, e, .operator)
                    ctx.redirectTarget = true
                    i = e
                    continue
                }
                var e = i + 1
                if e < end, line[e] == Ch.amp { e += 1 }
                tokens.add(i, e, .operator)
                if ctx.testDepth == 0 { ctx.startCommand() }
                i = e
                continue
            case Ch.lt, Ch.gt:
                i = lexRedirection(line, at: i, limit: end, ctx: &ctx, tokens: &tokens)
                continue
            case Ch.lparen:
                if i + 1 < end, line[i + 1] == Ch.lparen, ctx.cmdPos || ctx.expectName,
                   let close = arithmeticEnd(line, from: i, limit: end, budget: &budget) {
                    tokens.add(i, i + 2, .operator)
                    lexArithmetic(line, from: i + 2, to: close - 1, level: level, budget: &budget, tokens: &tokens)
                    tokens.add(close - 1, close + 1, .operator)
                    ctx.cmdPos = false
                    ctx.expectName = false
                    i = close + 1
                    continue
                }
                if ctx.casePattern {
                    tokens.add(i, i + 1, .operator)
                } else if glued {
                    tokens.add(i, i + 1, .punctuation)
                    ctx.arrayDepth += 1
                    ctx.cmdPos = false
                    ctx.assignmentEnd = -1
                } else {
                    tokens.add(i, i + 1, .punctuation)
                    ctx.startCommand()
                }
                i += 1
                continue
            case Ch.rparen:
                if ctx.casePattern {
                    tokens.add(i, i + 1, .operator)
                    ctx.casePattern = false
                    ctx.startCommand()
                } else {
                    tokens.add(i, i + 1, .punctuation)
                    if ctx.arrayDepth > 0 { ctx.arrayDepth -= 1 }
                    ctx.cmdPos = false
                }
                i += 1
                continue
            case Ch.lbrace:
                if ctx.cmdPos, !ctx.casePattern, i + 1 >= end || Ch.isSpace(line[i + 1]) {
                    tokens.add(i, i + 1, .punctuation)
                    i += 1
                    continue
                }
            case Ch.rbrace:
                if i == start || Ch.isSpace(line[i - 1]) || line[i - 1] == Ch.semicolon,
                   i + 1 >= end || isWordEnd(line[i + 1]) {
                    tokens.add(i, i + 1, .punctuation)
                    ctx.cmdPos = false
                    i += 1
                    continue
                }
            case Ch.bang:
                if ctx.cmdPos, i + 1 >= end || Ch.isSpace(line[i + 1]) {
                    tokens.add(i, i + 1, .operator)
                    i += 1
                    continue
                }
            default:
                break
            }
            i = lexWord(line, from: i, to: end, ctx: &ctx, tokens: &tokens)
        }
    }

    @inline(__always)
    private func isCommentBoundary(_ c: UInt16) -> Bool {
        Ch.isSpace(c) || c == Ch.semicolon || c == Ch.pipe || c == Ch.amp || c == Ch.lparen || c == Ch.rparen
            || c == Ch.lt || c == Ch.gt || c == Ch.lbrace || c == Ch.rbrace
    }

    @inline(__always)
    private func isWordEnd(_ c: UInt16) -> Bool {
        Ch.isSpace(c) || c == Ch.semicolon || c == Ch.pipe || c == Ch.amp || c == Ch.lparen || c == Ch.rparen
            || c == Ch.lt || c == Ch.gt
    }

    /// `<`, `>`, `>>`, `>&2`, `2>&1` (digits are handled by `lexWord`), `&>`, `<<<`, `<(`, heredocs.
    private func lexRedirection(_ line: LineBuffer, at i: Int, limit end: Int, ctx: inout Context, tokens: inout TokenBuffer) -> Int {
        let c = line[i]
        var e = i + 1
        let n = e < end ? line[e] : 0
        if c == Ch.lt, n == Ch.lt {
            if e + 1 < end, line[e + 1] == Ch.lt {
                tokens.add(i, e + 2, .operator)
                return e + 2
            }
            var opEnd = e + 1
            var strip = false
            if opEnd < end, line[opEnd] == Ch.minus {
                strip = true
                opEnd += 1
            }
            tokens.add(i, opEnd, .operator)
            var ds = opEnd
            while ds < end, Ch.isSpace(line[ds]) { ds += 1 }
            if ds < end, let d = ConfigLexKit.scanHeredocDelimiter(line, from: ds, limit: end) {
                tokens.add(ds, d.end, .meta)
                if ctx.heredoc == nil {
                    ctx.heredoc = (ConfigLexKit.delimiterHash(line, ds, d.end), d.quoted, strip)
                }
                return d.end
            }
            return opEnd
        }
        if n == Ch.lparen {
            tokens.add(i, e + 1, .operator)
            ctx.startCommand()
            return e + 1
        }
        if c == Ch.lt, n == Ch.amp || n == Ch.gt {
            e += 1
        } else if c == Ch.gt, n == Ch.gt || n == Ch.amp || n == Ch.pipe {
            e += 1
        }
        var fd = false
        if line[e - 1] == Ch.amp {
            while e < end, Ch.isDigit(line[e]) || line[e] == Ch.minus {
                e += 1
                fd = true
            }
        }
        tokens.add(i, e, .operator)
        ctx.redirectTarget = !fd
        return e
    }

    // MARK: Words

    private func lexWord(_ line: LineBuffer, from i: Int, to end: Int, ctx: inout Context, tokens: inout TokenBuffer) -> Int {
        var we = i
        while we < end {
            let c = line[we]
            if Ch.isSpace(c) { break }
            switch c {
            case Ch.semicolon, Ch.pipe, Ch.amp, Ch.lparen, Ch.rparen, Ch.lt, Ch.gt, Ch.quote, Ch.apostrophe, Ch.backtick, Ch.backslash:
                break
            case Ch.dollar where isExpansionStart(line, we, limit: end) || line[we + 1] == Ch.quote || line[we + 1] == Ch.apostrophe:
                break
            default:
                we += 1
                continue
            }
            break
        }
        if we == i { return i + 1 }
        let glued = i == ctx.assignmentEnd
        let whole = we >= end || isWordEnd(line[we])
        let first = line[i]

        if glued {
            ctx.assignmentEnd = we
            return we
        }
        if ctx.redirectTarget {
            ctx.redirectTarget = false
            return we
        }
        if isDigits(line, i, we), we < end, line[we] == Ch.gt || line[we] == Ch.lt {
            tokens.add(i, we, .operator)
            return we
        }
        if ctx.casePattern {
            if whole, line.string(i, we) == "esac" {
                tokens.add(i, we, .keyword)
                ctx.caseDepth = max(0, ctx.caseDepth - 1)
                ctx.casePattern = false
                ctx.cmdPos = false
                return we
            }
            for k in i..<we where line[k] == Ch.star || line[k] == Ch.question {
                tokens.add(k, k + 1, .operator)
            }
            return we
        }
        if first == Ch.minus, we - i >= 2, Ch.isAlpha(line[i + 1]) || line[i + 1] == Ch.minus {
            if let eq = ConfigLexKit.find(line, Ch.equals, from: i + 1, limit: we) {
                tokens.add(i, eq, .attribute)
                tokens.add(eq, eq + 1, .operator)
                if isNumber(line, eq + 1, we) { tokens.add(eq + 1, we, .number) }
            } else {
                tokens.add(i, we, .attribute)
            }
            return we
        }
        if ctx.expectName {
            tokens.add(i, we, .variable)
            ctx.expectName = false
            ctx.expectIn = true
            return we
        }
        let short = we - i <= 12
        if whole, short {
            let word = line.string(i, we)
            if ctx.expectIn, word == "in" {
                tokens.add(i, we, .keyword)
                if ctx.caseHeader { ctx.casePattern = true }
                ctx.expectIn = false
                ctx.caseHeader = false
                ctx.cmdPos = false
                return we
            }
            if ctx.cmdPos, Self.keywords.contains(word) {
                tokens.add(i, we, .keyword)
                switch word {
                case "for", "select":
                    ctx.expectName = true
                    ctx.cmdPos = false
                case "case":
                    ctx.caseDepth += 1
                    ctx.expectIn = true
                    ctx.caseHeader = true
                    ctx.cmdPos = false
                case "function":
                    ctx.expectFunctionName = true
                    ctx.cmdPos = false
                case "esac":
                    ctx.caseDepth = max(0, ctx.caseDepth - 1)
                    ctx.casePattern = false
                    ctx.cmdPos = false
                case "[[":
                    ctx.testDepth += 1
                    ctx.cmdPos = false
                case "]]":
                    ctx.testDepth = max(0, ctx.testDepth - 1)
                    ctx.cmdPos = false
                case "fi", "done", "in":
                    ctx.cmdPos = false
                default:
                    ctx.cmdPos = true
                }
                return we
            }
            if word == "]]", ctx.testDepth > 0 {
                tokens.add(i, we, .keyword)
                ctx.testDepth -= 1
                ctx.cmdPos = false
                return we
            }
            if word == "]" || (word == "[" && ctx.cmdPos) {
                tokens.add(i, we, .keyword)
                ctx.cmdPos = false
                return we
            }
            if Self.testOperators.contains(word) {
                tokens.add(i, we, .operator)
                return we
            }
        }
        if ctx.expectFunctionName {
            tokens.add(i, we, .function)
            ctx.expectFunctionName = false
            ctx.cmdPos = true
            return skipEmptyParens(line, from: we, limit: end, tokens: &tokens) ?? we
        }
        // Assignments: NAME=value, NAME+=value, NAME[i]=value
        if ctx.cmdPos || ctx.declaration, Ch.isAlpha(first) || first == Ch.underscore {
            var ne = i + 1
            while ne < we, Ch.isAlnum(line[ne]) || line[ne] == Ch.underscore { ne += 1 }
            if ne < we, line[ne] == Ch.lbracket, let close = ConfigLexKit.find(line, Ch.rbracket, from: ne + 1, limit: we) {
                ne = close + 1
            }
            var opEnd = -1
            if ne < we, line[ne] == Ch.equals {
                opEnd = ne + 1
            } else if ne + 1 < we, line[ne] == Ch.plus, line[ne + 1] == Ch.equals {
                opEnd = ne + 2
            }
            if opEnd > 0 {
                tokens.add(i, ne, .property)
                tokens.add(ne, opEnd, .operator)
                if isNumber(line, opEnd, we) { tokens.add(opEnd, we, .number) }
                ctx.assignmentEnd = we
                return we
            }
            if ctx.declaration, !ctx.cmdPos, whole, ne == we {
                tokens.add(i, we, .property)
                return we
            }
        }
        if ctx.cmdPos {
            if isNumber(line, i, we) {
                tokens.add(i, we, .number)
                return we
            }
            if whole, let after = skipEmptyParens(line, from: we, limit: end, tokens: &tokens, nameStart: i) {
                // `name() { … }`
                ctx.cmdPos = true
                return after
            }
            tokens.add(i, we, .function)
            let word = short ? line.string(i, we) : ""
            ctx.cmdPos = Self.prefixCommands.contains(word)
            ctx.declaration = Self.declarationCommands.contains(word)
            ctx.assignmentEnd = -1
            return we
        }
        if isNumber(line, i, we) { tokens.add(i, we, .number) }
        return we
    }

    /// Recognizes `()` after a function name. When `nameStart` is given the name is emitted as a
    /// function only if the parentheses are there. Returns the index after `)`.
    private func skipEmptyParens(_ line: LineBuffer, from s: Int, limit end: Int, tokens: inout TokenBuffer, nameStart: Int? = nil) -> Int? {
        var k = s
        while k < end, Ch.isSpace(line[k]) { k += 1 }
        guard k < end, line[k] == Ch.lparen else { return nil }
        var k2 = k + 1
        while k2 < end, Ch.isSpace(line[k2]) { k2 += 1 }
        guard k2 < end, line[k2] == Ch.rparen else { return nil }
        if let nameStart { tokens.add(nameStart, s, .function) }
        tokens.add(k, k + 1, .punctuation)
        tokens.add(k2, k2 + 1, .punctuation)
        return k2 + 1
    }

    private func isDigits(_ line: LineBuffer, _ s: Int, _ e: Int) -> Bool {
        guard e > s else { return false }
        for k in s..<e where !Ch.isDigit(line[k]) { return false }
        return true
    }

    /// `42`, `-7`, `3.14`.
    private func isNumber(_ line: LineBuffer, _ s: Int, _ e: Int) -> Bool {
        var k = s
        if k < e, line[k] == Ch.minus || line[k] == Ch.plus { k += 1 }
        guard k < e, Ch.isDigit(line[k]) else { return false }
        while k < e, Ch.isDigit(line[k]) { k += 1 }
        if k < e, line[k] == Ch.dot {
            k += 1
            guard k < e else { return false }
            while k < e, Ch.isDigit(line[k]) { k += 1 }
        }
        return k == e
    }

    // MARK: Strings

    /// Scans a single-quoted (or, with `ansi`, a `$'…'`) string body from `start`; tokens begin at
    /// `tokenStart`. Returns the index after the closing quote, or nil when `limit` comes first.
    private func scanSingleQuoted(_ line: LineBuffer, from start: Int, tokenStart: Int, ansi: Bool, limit end: Int,
                                  tokens: inout TokenBuffer) -> Int? {
        var seg = tokenStart
        var k = start
        while k < end {
            let c = line[k]
            if ansi, c == Ch.backslash {
                if k + 1 < end {
                    tokens.add(seg, k, .string)
                    let e = ConfigLexKit.escapeEnd(line, k, limit: end)
                    tokens.add(k, e, .escape)
                    k = e
                    seg = k
                } else {
                    k += 1
                }
                continue
            }
            if c == Ch.apostrophe {
                tokens.add(seg, k + 1, .string)
                return k + 1
            }
            k += 1
        }
        tokens.add(seg, end, .string)
        return nil
    }

    /// Scans the body of a double-quoted string (or, when `closes` is false, a heredoc line),
    /// emitting string segments, escapes and expansions. Returns the index after the closing quote,
    /// or nil when `limit` comes first.
    private func scanDoubleQuoted(_ line: LineBuffer, from start: Int, tokenStart: Int, limit end: Int,
                                  closes: Bool = true, level: Int, budget: inout Int, tokens: inout TokenBuffer) -> Int? {
        var seg = tokenStart
        var j = start
        while j < end {
            let c = line[j]
            if c == Ch.backslash {
                if j + 1 < end {
                    let n = line[j + 1]
                    if n == Ch.dollar || n == Ch.backtick || n == Ch.backslash || (closes && n == Ch.quote) {
                        tokens.add(seg, j, .string)
                        tokens.add(j, j + 2, .escape)
                        seg = j + 2
                    }
                }
                j += 2
                continue
            }
            if closes, c == Ch.quote {
                tokens.add(seg, j + 1, .string)
                return j + 1
            }
            if c == Ch.dollar, isExpansionStart(line, j, limit: end) {
                tokens.add(seg, j, .string)
                j = lexDollar(line, at: j, limit: end, level: level, budget: &budget, tokens: &tokens).end
                seg = j
                continue
            }
            if c == Ch.backtick, let close = backtickEnd(line, from: j, limit: end) {
                tokens.add(seg, j, .string)
                lexBackticks(line, j, close, level: level, budget: &budget, tokens: &tokens)
                j = close + 1
                seg = j
                continue
            }
            j += 1
        }
        tokens.add(seg, end, .string)
        return nil
    }

    // MARK: Expansions

    @inline(__always)
    private func isExpansionStart(_ line: LineBuffer, _ j: Int, limit: Int) -> Bool {
        guard j + 1 < limit else { return false }
        let n = line[j + 1]
        switch n {
        case Ch.lbrace, Ch.lparen, Ch.underscore, Ch.at, Ch.hash, Ch.question, Ch.dollar, Ch.bang, Ch.star, Ch.minus:
            return true
        default:
            return Ch.isAlpha(n) || Ch.isDigit(n)
        }
    }

    /// Lexes `$NAME`, `$1`, `$@`, `${…}`, `$(…)` or `$((…))` at `i`. Returns the end and whether it
    /// was a `$(` without its `)` on this line (the rest of the line is then a command).
    private func lexDollar(_ line: LineBuffer, at i: Int, limit end: Int, level: Int,
                           budget: inout Int, tokens: inout TokenBuffer) -> (end: Int, openCommand: Bool) {
        let n = line[i + 1]
        if n == Ch.lparen {
            if i + 2 < end, line[i + 2] == Ch.lparen, let close = arithmeticEnd(line, from: i + 1, limit: end, budget: &budget) {
                tokens.add(i, i + 3, .variable)
                lexArithmetic(line, from: i + 3, to: close - 1, level: level, budget: &budget, tokens: &tokens)
                tokens.add(close - 1, close + 1, .variable)
                return (close + 1, false)
            }
            if level < Self.maxNesting, let close = matchingParen(line, from: i + 1, limit: end, level: level, budget: &budget) {
                tokens.add(i, i + 2, .variable)
                var sub = Context()
                lexCommands(line, from: i + 2, to: close, ctx: &sub, level: level + 1, budget: &budget, tokens: &tokens)
                tokens.add(close, close + 1, .variable)
                return (close + 1, false)
            }
            tokens.add(i, i + 2, .variable)
            return (i + 2, true)
        }
        if n == Ch.lbrace {
            let stop = min(end, i + ConfigLexKit.referenceWindow)
            var depth = 0
            var j = i + 1
            while j < stop {
                let c = line[j]
                if c == Ch.lbrace {
                    depth += 1
                } else if c == Ch.rbrace {
                    depth -= 1
                    if depth == 0 {
                        tokens.add(i, j + 1, .variable)
                        return (j + 1, false)
                    }
                }
                j += 1
            }
            var e = i + 2
            while e < end, Ch.isAlnum(line[e]) || line[e] == Ch.underscore { e += 1 }
            tokens.add(i, e, .variable)
            return (e, false)
        }
        if Ch.isAlpha(n) || n == Ch.underscore {
            var e = i + 2
            while e < end, Ch.isAlnum(line[e]) || line[e] == Ch.underscore { e += 1 }
            tokens.add(i, e, .variable)
            return (e, false)
        }
        tokens.add(i, i + 2, .variable)
        return (i + 2, false)
    }

    /// Index of the `)` matching the `(` at `open`, honoring quotes, escapes and nested `$( )`.
    private func matchingParen(_ line: LineBuffer, from open: Int, limit: Int, level: Int, budget: inout Int) -> Int? {
        let end = min(limit, open + Self.parenWindow)
        var depth = 0
        var j = open
        while j < end {
            budget -= 1
            if budget < 0 { return nil }
            let c = line[j]
            switch c {
            case Ch.backslash:
                j += 2
                continue
            case Ch.apostrophe:
                guard let q = ConfigLexKit.find(line, Ch.apostrophe, from: j + 1, limit: end) else { return nil }
                j = q + 1
                continue
            case Ch.quote:
                guard let q = skipDoubleQuoted(line, from: j, limit: end, level: level + 1, budget: &budget) else { return nil }
                j = q
                continue
            case Ch.backtick:
                guard let q = backtickEnd(line, from: j, limit: end) else { return nil }
                j = q + 1
                continue
            case Ch.lparen:
                depth += 1
            case Ch.rparen:
                depth -= 1
                if depth == 0 { return j }
            default:
                break
            }
            j += 1
        }
        return nil
    }

    /// Index after the `"` closing the string that opens at `j`.
    private func skipDoubleQuoted(_ line: LineBuffer, from j: Int, limit end: Int, level: Int, budget: inout Int) -> Int? {
        guard level < Self.maxNesting else { return nil }
        var k = j + 1
        while k < end {
            budget -= 1
            if budget < 0 { return nil }
            let c = line[k]
            if c == Ch.backslash {
                k += 2
                continue
            }
            if c == Ch.quote { return k + 1 }
            if c == Ch.dollar, line[k + 1] == Ch.lparen {
                guard let close = matchingParen(line, from: k + 1, limit: end, level: level + 1, budget: &budget) else { return nil }
                k = close + 1
                continue
            }
            if c == Ch.backtick {
                guard let q = backtickEnd(line, from: k, limit: end) else { return nil }
                k = q + 1
                continue
            }
            k += 1
        }
        return nil
    }

    /// For `$((` / `((` starting at `open` (the first `(`): the index of the final `)` of `))`.
    private func arithmeticEnd(_ line: LineBuffer, from open: Int, limit: Int, budget: inout Int) -> Int? {
        let end = min(limit, open + Self.parenWindow)
        var depth = 0
        var j = open
        while j < end {
            budget -= 1
            if budget < 0 { return nil }
            let c = line[j]
            if c == Ch.lparen {
                depth += 1
            } else if c == Ch.rparen {
                depth -= 1
                if depth == 0 { return line[j - 1] == Ch.rparen && j - 1 > open + 1 ? j : nil }
            }
            j += 1
        }
        return nil
    }

    private func lexArithmetic(_ line: LineBuffer, from s: Int, to e: Int, level: Int, budget: inout Int, tokens: inout TokenBuffer) {
        var i = s
        while i < e {
            let c = line[i]
            if Ch.isSpace(c) {
                i += 1
            } else if Ch.isDigit(c) {
                let n = min(line.scanNumber(i), e)
                tokens.add(i, n, .number)
                i = max(n, i + 1)
            } else if c == Ch.dollar, isExpansionStart(line, i, limit: e) {
                i = lexDollar(line, at: i, limit: e, level: level, budget: &budget, tokens: &tokens).end
            } else if Ch.isAlpha(c) || c == Ch.underscore {
                var n = i + 1
                while n < e, Ch.isAlnum(line[n]) || line[n] == Ch.underscore { n += 1 }
                tokens.add(i, n, .variable)
                i = n
            } else if c == Ch.lparen || c == Ch.rparen || c == Ch.lbracket || c == Ch.rbracket || c == Ch.comma {
                tokens.add(i, i + 1, .punctuation)
                i += 1
            } else if Ch.isOperator(c) || c == Ch.colon {
                var n = i + 1
                while n < e, Ch.isOperator(line[n]) { n += 1 }
                tokens.add(i, n, .operator)
                i = n
            } else {
                i += 1
            }
        }
    }

    /// Index of the backtick closing the one at `j`.
    private func backtickEnd(_ line: LineBuffer, from j: Int, limit: Int) -> Int? {
        var k = j + 1
        while k < limit {
            let c = line[k]
            if c == Ch.backslash {
                k += 2
                continue
            }
            if c == Ch.backtick { return k }
            k += 1
        }
        return nil
    }

    private func lexBackticks(_ line: LineBuffer, _ open: Int, _ close: Int, level: Int, budget: inout Int, tokens: inout TokenBuffer) {
        tokens.add(open, open + 1, .variable)
        if level < Self.maxNesting {
            var sub = Context()
            lexCommands(line, from: open + 1, to: close, ctx: &sub, level: level + 1, budget: &budget, tokens: &tokens)
        } else {
            tokens.add(open + 1, close, .variable)
        }
        tokens.add(close, close + 1, .variable)
    }
}
