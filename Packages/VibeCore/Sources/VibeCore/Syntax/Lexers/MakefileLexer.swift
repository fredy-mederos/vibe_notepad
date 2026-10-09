import Foundation

/// Makefiles (GNU make flavored).
///
/// State:
/// - `mode`: 0 normal; 1 recipe line continued with `\` (the shell state lives in `LineState.inner`
///   with `embedded == .shell`); 2 inside `define … endef` (`depth` = nesting); 3 continued variable
///   value; 4 continued prerequisites or directive arguments.
public struct MakefileLexer: SyntaxLexer {
    public init() {}

    enum Mode {
        static let normal: UInt8 = 0
        static let recipe: UInt8 = 1
        static let define: UInt8 = 2
        static let value: UInt8 = 3
        static let prerequisites: UInt8 = 4
    }

    private static let directives = ConfigLexKit.words("""
    include -include sinclude ifeq ifneq ifdef ifndef else endif define endef export unexport override private vpath undefine
    """)
    private static let functions = ConfigLexKit.words("""
    subst patsubst strip findstring filter filter-out sort word wordlist words firstword lastword dir notdir suffix
    basename addsuffix addprefix join wildcard realpath abspath error warning info shell origin flavor foreach if or
    and call eval file value let intcmp guile
    """)
    private static let maxNesting = 16

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        switch state.main.mode {
        case Mode.recipe:
            lexRecipe(line, from: line.start, continuing: true, state: &state, tokens: &tokens)
            return
        case Mode.define:
            lexDefineLine(line, state: &state.main, tokens: &tokens)
            return
        case Mode.value, Mode.prerequisites:
            let rule = state.main.mode == Mode.prerequisites
            if !lexText(line, from: line.start, to: line.end, kind: .plain, operators: rule, tokens: &tokens) {
                state.main = .initial
            }
            return
        default:
            break
        }
        if line[line.start] == Ch.tab {
            lexRecipe(line, from: line.start + 1, continuing: false, state: &state, tokens: &tokens)
            return
        }
        state.main = .initial
        state.embedded = nil
        state.inner = .initial
        lexStatement(line, from: line.firstNonSpace, nested: false, state: &state.main, tokens: &tokens)
    }

    // MARK: Statements

    private func lexStatement(_ line: LineBuffer, from first: Int, nested: Bool, state: inout LexState, tokens: inout TokenBuffer) {
        let te = line.trimmedEnd
        guard first < te else { return }
        if line[first] == Ch.hash {
            tokens.add(first, te, .comment)
            return
        }
        var we = first
        if line[we] == Ch.minus { we += 1 }
        while we < te, Ch.isAlpha(line[we]) { we += 1 }
        let isDirective = we > first && (we >= te || Ch.isSpace(line[we]) || line[we] == Ch.lparen)
            && ConfigLexKit.word(line, first, we, in: Self.directives)
        guard isDirective else {
            lexAssignmentOrRule(line, from: first, bareNames: false, state: &state, tokens: &tokens)
            return
        }
        tokens.add(first, we, .keyword)
        let j = line.skipSpaces(we)
        switch line.string(first, we) {
        case "define":
            var ne = j
            while ne < te, !Ch.isSpace(line[ne]), !isAssignmentChar(line[ne]) { ne += 1 }
            tokens.add(j, ne, .property)
            let op = line.skipSpaces(ne)
            var opEnd = op
            while opEnd < te, isAssignmentChar(line[opEnd]) { opEnd += 1 }
            tokens.add(op, opEnd, .operator)
            _ = lexText(line, from: opEnd, to: line.end, kind: .plain, operators: false, tokens: &tokens)
            state = LexState(mode: Mode.define, depth: 1)
        case "endef", "endif":
            _ = lexText(line, from: j, to: line.end, kind: .plain, operators: false, tokens: &tokens)
        case "export", "unexport", "override", "private":
            if j < te {
                if nested {
                    lexAssignmentOrRule(line, from: j, bareNames: true, state: &state, tokens: &tokens)
                } else {
                    lexStatementAfterModifier(line, from: j, state: &state, tokens: &tokens)
                }
            }
        case "ifdef", "ifndef", "undefine":
            _ = lexText(line, from: j, to: line.end, kind: .variable, operators: false, tokens: &tokens)
        case "ifeq", "ifneq":
            lexConditionArguments(line, from: j, to: te, tokens: &tokens)
        case "else":
            if j < te, !nested { lexStatement(line, from: j, nested: true, state: &state, tokens: &tokens) }
        default:
            // include, -include, sinclude, vpath
            if lexText(line, from: j, to: line.end, kind: .plain, operators: true, tokens: &tokens) {
                state = LexState(mode: Mode.prerequisites)
            }
        }
    }

    /// `export`/`override` can be followed by another modifier, an assignment or bare names.
    private func lexStatementAfterModifier(_ line: LineBuffer, from j: Int, state: inout LexState, tokens: inout TokenBuffer) {
        var we = j
        while we < line.end, Ch.isAlpha(line[we]) { we += 1 }
        let next = we - j <= 9 ? line.string(j, we) : ""
        if next == "export" || next == "override" || next == "private" || next == "unexport" {
            tokens.add(j, we, .keyword)
            lexAssignmentOrRule(line, from: line.skipSpaces(we), bareNames: true, state: &state, tokens: &tokens)
        } else {
            lexAssignmentOrRule(line, from: j, bareNames: true, state: &state, tokens: &tokens)
        }
    }

    @inline(__always)
    private func isAssignmentChar(_ c: UInt16) -> Bool {
        c == Ch.equals || c == Ch.colon || c == Ch.question || c == Ch.plus || c == Ch.bang
    }

    private enum Split {
        case assignment(opStart: Int, opEnd: Int)
        case rule(colon: Int, colonEnd: Int)
        case none
    }

    /// Finds the first top-level assignment operator or rule colon in `[s, te)`.
    private func split(_ line: LineBuffer, from s: Int, to te: Int) -> Split {
        var k = s
        while k < te {
            let c = line[k]
            switch c {
            case Ch.dollar:
                if line[k + 1] == Ch.lparen || line[k + 1] == Ch.lbrace {
                    k = referenceEnd(line, at: k, limit: te) ?? te
                } else {
                    k += 2
                }
                continue
            case Ch.backslash:
                k += 2
                continue
            case Ch.hash, Ch.semicolon:
                return .none
            case Ch.equals:
                var opStart = k
                if k > s, line[k - 1] == Ch.question || line[k - 1] == Ch.plus || line[k - 1] == Ch.bang { opStart = k - 1 }
                return .assignment(opStart: opStart, opEnd: k + 1)
            case Ch.colon:
                if line[k + 1] == Ch.equals { return .assignment(opStart: k, opEnd: k + 2) }
                if line[k + 1] == Ch.colon {
                    if line[k + 2] == Ch.equals { return .assignment(opStart: k, opEnd: k + 3) }
                    if line[k + 2] == Ch.colon, line[k + 3] == Ch.equals { return .assignment(opStart: k, opEnd: k + 4) }
                    return .rule(colon: k, colonEnd: k + 2)
                }
                return .rule(colon: k, colonEnd: k + 1)
            default:
                k += 1
            }
        }
        return .none
    }

    private func lexAssignmentOrRule(_ line: LineBuffer, from s: Int, bareNames: Bool, state: inout LexState, tokens: inout TokenBuffer) {
        let te = line.trimmedEnd
        switch split(line, from: s, to: te) {
        case let .assignment(opStart, opEnd):
            var nameEnd = opStart
            while nameEnd > s, Ch.isSpace(line[nameEnd - 1]) { nameEnd -= 1 }
            _ = lexText(line, from: s, to: nameEnd, kind: .property, operators: false, tokens: &tokens)
            tokens.add(opStart, opEnd, .operator)
            if lexText(line, from: opEnd, to: line.end, kind: .plain, operators: false, tokens: &tokens) {
                state = LexState(mode: Mode.value)
            }
        case let .rule(colon, colonEnd):
            _ = lexText(line, from: s, to: colon, kind: .function, operators: true, tokens: &tokens)
            tokens.add(colon, colonEnd, .operator)
            lexRuleRest(line, from: colonEnd, staticPattern: true, state: &state, tokens: &tokens)
        case .none:
            if lexText(line, from: s, to: line.end, kind: bareNames ? .property : .plain, operators: false, tokens: &tokens) {
                state = LexState(mode: Mode.value)
            }
        }
    }

    /// Prerequisites, a static pattern (`%.o: %.c`), a target-specific variable or an inline recipe.
    private func lexRuleRest(_ line: LineBuffer, from s: Int, staticPattern: Bool, state: inout LexState, tokens: inout TokenBuffer) {
        let te = line.trimmedEnd
        switch split(line, from: s, to: te) {
        case .assignment:
            lexAssignmentOrRule(line, from: line.skipSpaces(s), bareNames: false, state: &state, tokens: &tokens)
            return
        case let .rule(colon, colonEnd) where staticPattern:
            _ = lexText(line, from: s, to: colon, kind: .plain, operators: true, tokens: &tokens)
            tokens.add(colon, colonEnd, .operator)
            lexRuleRest(line, from: colonEnd, staticPattern: false, state: &state, tokens: &tokens)
            return
        default:
            break
        }
        if let semi = topLevelSemicolon(line, from: s, to: te) {
            _ = lexText(line, from: s, to: semi, kind: .plain, operators: true, tokens: &tokens)
            tokens.add(semi, semi + 1, .operator)
            var inner = LexState.initial
            lexShellWithReferences(line, from: recipePrefixes(line, from: semi + 1, tokens: &tokens), inner: &inner, tokens: &tokens)
            return
        }
        if lexText(line, from: s, to: line.end, kind: .plain, operators: true, tokens: &tokens) {
            state = LexState(mode: Mode.prerequisites)
        }
    }

    private func topLevelSemicolon(_ line: LineBuffer, from s: Int, to te: Int) -> Int? {
        var k = s
        while k < te {
            let c = line[k]
            if c == Ch.hash { return nil }
            if c == Ch.semicolon { return k }
            if c == Ch.dollar, line[k + 1] == Ch.lparen || line[k + 1] == Ch.lbrace {
                k = referenceEnd(line, at: k, limit: te) ?? te
                continue
            }
            k += c == Ch.backslash ? 2 : 1
        }
        return nil
    }

    /// `ifeq (a,b)`, `ifneq "a" "b"`.
    private func lexConditionArguments(_ line: LineBuffer, from s: Int, to te: Int, tokens: inout TokenBuffer) {
        var k = s
        while k < te {
            let c = line[k]
            switch c {
            case Ch.lparen, Ch.rparen, Ch.comma:
                tokens.add(k, k + 1, .punctuation)
                k += 1
            case Ch.quote, Ch.apostrophe:
                let close = ConfigLexKit.closingQuote(line, from: k, limit: te, escapes: false) ?? te
                var seg = k
                var q = k + 1
                while q < close {
                    if line[q] == Ch.dollar {
                        tokens.add(seg, q, .string)
                        q = lexReference(line, at: q, limit: close, level: 0, tokens: &tokens)
                        seg = q
                    } else {
                        q += 1
                    }
                }
                tokens.add(seg, close, .string)
                k = close
            case Ch.dollar:
                k = lexReference(line, at: k, limit: te, level: 0, tokens: &tokens)
            case Ch.hash:
                tokens.add(k, te, .comment)
                return
            default:
                k += 1
            }
        }
    }

    // MARK: Text

    /// Lexes text with Make references, comments and `\#` escapes; other non-blank runs get `kind`.
    /// With `operators`, `|` and `%` are operators (rule lines). Returns whether a trailing `\`
    /// continues the line.
    private func lexText(_ line: LineBuffer, from s: Int, to e: Int, kind: TokenKind, operators: Bool, tokens: inout TokenBuffer) -> Bool {
        var te = e
        while te > s, Ch.isSpace(line[te - 1]) { te -= 1 }
        let continues = te > s && line[te - 1] == Ch.backslash && !(te - 2 >= s && line[te - 2] == Ch.backslash)
        let limit = continues ? te - 1 : te
        var i = s
        var run = -1
        while i < limit {
            let c = line[i]
            if Ch.isSpace(c) || c == Ch.hash || c == Ch.dollar || (c == Ch.backslash && line[i + 1] == Ch.hash)
                || (operators && (c == Ch.pipe || c == Ch.percent)) {
                if run >= 0 { tokens.add(run, i, kind) }
                run = -1
            }
            if Ch.isSpace(c) {
                i += 1
            } else if c == Ch.hash {
                tokens.add(i, te, .comment)
                return false
            } else if c == Ch.dollar {
                i = lexReference(line, at: i, limit: limit, level: 0, tokens: &tokens)
            } else if c == Ch.backslash, line[i + 1] == Ch.hash, i + 1 < limit {
                tokens.add(i, i + 2, .escape)
                i += 2
            } else if operators, c == Ch.pipe || c == Ch.percent {
                tokens.add(i, i + 1, .operator)
                i += 1
            } else {
                if run < 0 { run = i }
                i += 1
            }
        }
        if run >= 0 { tokens.add(run, limit, kind) }
        if continues { tokens.add(te - 1, te, .escape) }
        return continues
    }

    // MARK: References

    /// Index after the `)`/`}` closing the reference at `i` (`$(` or `${`), or nil.
    private func referenceEnd(_ line: LineBuffer, at i: Int, limit: Int) -> Int? {
        let open = line[i + 1]
        let close = open == Ch.lparen ? Ch.rparen : Ch.rbrace
        let stop = min(limit, i + 2 * ConfigLexKit.referenceWindow)
        var depth = 0
        var j = i + 1
        while j < stop {
            let c = line[j]
            if c == open {
                depth += 1
            } else if c == close {
                depth -= 1
                if depth == 0 { return j + 1 }
            }
            j += 1
        }
        return nil
    }

    /// `$(VAR)`, `${VAR}`, `$@ $< $^ $*`, `$(shell …)` function calls and `$$` escapes.
    private func lexReference(_ line: LineBuffer, at i: Int, limit: Int, level: Int, tokens: inout TokenBuffer) -> Int {
        guard i + 1 < limit else { return i + 1 }
        let n = line[i + 1]
        if n == Ch.dollar {
            // `$$` is a literal dollar for the shell: `$$HOME`, `$${HOME}`.
            var e = i + 2
            if e < limit, Ch.isAlpha(line[e]) || line[e] == Ch.underscore {
                while e < limit, Ch.isAlnum(line[e]) || line[e] == Ch.underscore { e += 1 }
                tokens.add(i, e, .variable)
                return e
            }
            if e < limit, line[e] == Ch.lbrace,
               let close = ConfigLexKit.find(line, Ch.rbrace, from: e + 1, limit: min(limit, e + ConfigLexKit.referenceWindow)) {
                tokens.add(i, close + 1, .variable)
                return close + 1
            }
            tokens.add(i, i + 2, .escape)
            return i + 2
        }
        if n == Ch.lparen || n == Ch.lbrace {
            guard let after = referenceEnd(line, at: i, limit: limit) else {
                var e = i + 2
                while e < limit, Ch.isAlnum(line[e]) || line[e] == Ch.underscore { e += 1 }
                tokens.add(i, e, .variable)
                return e
            }
            let close = after - 1
            var ne = i + 2
            while ne < close, Ch.isAlpha(line[ne]) || line[ne] == Ch.minus { ne += 1 }
            if level < Self.maxNesting, ne > i + 2, ne < close, Ch.isSpace(line[ne]),
               ConfigLexKit.word(line, i + 2, ne, in: Self.functions) {
                tokens.add(i, i + 2, .variable)
                tokens.add(i + 2, ne, .function)
                lexArguments(line, from: ne, to: close, level: level + 1, tokens: &tokens)
                tokens.add(close, after, .variable)
            } else {
                tokens.add(i, after, .variable)
            }
            return after
        }
        if Ch.isSpace(n) { return i + 1 }
        tokens.add(i, i + 2, .variable)
        return i + 2
    }

    private func lexArguments(_ line: LineBuffer, from s: Int, to e: Int, level: Int, tokens: inout TokenBuffer) {
        var k = s
        while k < e {
            let c = line[k]
            if c == Ch.dollar {
                k = lexReference(line, at: k, limit: e, level: level, tokens: &tokens)
            } else if c == Ch.comma {
                tokens.add(k, k + 1, .punctuation)
                k += 1
            } else {
                k += 1
            }
        }
    }

    // MARK: Recipes

    private func lexRecipe(_ line: LineBuffer, from s: Int, continuing: Bool, state: inout LineState, tokens: inout TokenBuffer) {
        var i = s
        if !continuing {
            state.inner = .initial
            i = recipePrefixes(line, from: s, tokens: &tokens)
        }
        lexShellWithReferences(line, from: i, inner: &state.inner, tokens: &tokens)
        let te = line.trimmedEnd
        if te > s, line[te - 1] == Ch.backslash {
            state.main = LexState(mode: Mode.recipe)
            state.embedded = .shell
        } else {
            state.main = .initial
            state.embedded = nil
            state.inner = .initial
        }
    }

    /// Recipe prefixes `@` (silent), `-` (ignore errors) and `+` (always run).
    private func recipePrefixes(_ line: LineBuffer, from s: Int, tokens: inout TokenBuffer) -> Int {
        var i = s
        while i < line.end {
            let c = line[i]
            if c == Ch.at || c == Ch.minus || c == Ch.plus {
                tokens.add(i, i + 1, .operator)
            } else if !Ch.isSpace(c) {
                break
            }
            i += 1
        }
        return i
    }

    /// Lexes `[s, end)` as shell, with Make references taking precedence over the shell tokens.
    private func lexShellWithReferences(_ line: LineBuffer, from s: Int, inner: inout LexState, tokens: inout TokenBuffer) {
        guard s < line.end else { return }
        var shell = TokenBuffer()
        lexEmbedded(.shell, line.slice(s, line.end), inner: &inner, tokens: &shell)
        var references = TokenBuffer()
        var k = s
        while k < line.end {
            if line[k] == Ch.dollar {
                k = lexReference(line, at: k, limit: line.end, level: 0, tokens: &references)
            } else {
                k += 1
            }
        }
        if references.isEmpty {
            for t in shell.tokens { tokens.add(t.start, t.end, t.kind) }
        } else {
            ConfigLexKit.appendMerged(shell.tokens, overlay: references.tokens, into: &tokens)
        }
    }

    // MARK: define … endef

    private func lexDefineLine(_ line: LineBuffer, state: inout LexState, tokens: inout TokenBuffer) {
        let first = line.firstNonSpace
        let te = line.trimmedEnd
        var we = first
        while we < te, Ch.isAlpha(line[we]) { we += 1 }
        let bare = we >= te || Ch.isSpace(line[we]) || line[we] == Ch.hash
        let word = bare && we - first <= 6 ? line.string(first, we) : ""
        if word == "endef" {
            tokens.add(first, we, .keyword)
            _ = lexText(line, from: we, to: line.end, kind: .plain, operators: false, tokens: &tokens)
            if state.depth <= 1 {
                state = .initial
            } else {
                state.depth -= 1
            }
            return
        }
        if word == "define" {
            tokens.add(first, we, .keyword)
            var ne = line.skipSpaces(we)
            let ns = ne
            while ne < te, !Ch.isSpace(line[ne]), !isAssignmentChar(line[ne]) { ne += 1 }
            tokens.add(ns, ne, .property)
            if state.depth < UInt16.max { state.depth += 1 }
            return
        }
        if line[line.start] == Ch.tab {
            var scratch = LexState.initial
            lexShellWithReferences(line, from: recipePrefixes(line, from: line.start + 1, tokens: &tokens), inner: &scratch, tokens: &tokens)
            return
        }
        var k = line.start
        while k < line.end {
            if line[k] == Ch.dollar {
                k = lexReference(line, at: k, limit: line.end, level: 0, tokens: &tokens)
            } else {
                k += 1
            }
        }
    }
}
