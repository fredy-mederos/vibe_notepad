import Foundation

/// Dockerfiles and Containerfiles.
///
/// State:
/// - `mode`: 0 an instruction is expected; 1 shell-form continuation (`RUN … \`), lexed as shell with
///   the shell state in `LineState.inner` (`embedded == .shell`); 2 continuation of another
///   instruction (`sub` = its kind); 3 `RUN <<EOF` heredoc script (lexed as shell); 4 `COPY <<EOF`
///   heredoc text.
/// - `depth` bit 0: the escape character is a backtick (`# escape=\``); bit 1: parser directives
///   are no longer recognized.
/// - `data`: FNV-1a hash of the heredoc delimiter; `sub` bit 0 in heredoc modes: `<<-`.
public struct DockerfileLexer: SyntaxLexer {
    public init() {}

    enum Mode {
        static let instruction: UInt8 = 0
        static let shell: UInt8 = 1
        static let arguments: UInt8 = 2
        static let heredocScript: UInt8 = 3
        static let heredocText: UInt8 = 4
    }

    enum Kind {
        static let other: UInt8 = 0
        static let keyValue: UInt8 = 1
        static let expose: UInt8 = 2
        static let exec: UInt8 = 3
        static let maintainer: UInt8 = 4
    }

    private static let instructions = ConfigLexKit.words("""
    from run cmd entrypoint copy add env arg expose workdir user volume label healthcheck shell stopsignal onbuild maintainer
    """)
    private static let directives: Set<String> = ["syntax", "escape", "check"]

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        var st = state.main
        let escapeChar: UInt16 = st.depth & 1 != 0 ? Ch.backtick : Ch.backslash
        let first = line.firstNonSpace
        let end = line.trimmedEnd

        switch st.mode {
        case Mode.heredocScript, Mode.heredocText:
            var s = line.start
            if st.sub & 1 != 0 {
                while s < line.end, line[s] == Ch.tab { s += 1 }
            }
            let e = ConfigLexKit.contentEnd(line)
            if isTerminator(line, s, e, hash: st.data) {
                tokens.add(s, e, .meta)
                state.main = LexState(depth: st.depth)
                state.embedded = nil
                state.inner = .initial
            } else if st.mode == Mode.heredocScript {
                lexEmbedded(.shell, line, inner: &state.inner, tokens: &tokens)
            } else {
                tokens.add(line.start, line.end, .string)
            }
            return
        case Mode.shell:
            guard first < end else { return }
            if line[first] == Ch.hash {
                tokens.add(first, end, .comment)
                return
            }
            lexEmbedded(.shell, line, inner: &state.inner, tokens: &tokens)
            if !continues(line, first, end, escapeChar), !ShellLexer.isInHeredoc(state.inner) {
                state.main = LexState(depth: st.depth)
                state.embedded = nil
                state.inner = .initial
            }
            return
        case Mode.arguments:
            guard first < end else { return }
            if line[first] == Ch.hash {
                tokens.add(first, end, .comment)
                return
            }
            if !lexArguments(line, from: first, to: end, kind: st.sub, escapeChar: escapeChar, tokens: &tokens) {
                state.main = LexState(depth: st.depth)
            }
            return
        default:
            break
        }

        guard first < end else {
            st.depth |= 2
            state.main = st
            return
        }
        if line[first] == Ch.hash {
            if st.depth & 2 == 0, let backtick = parserDirective(line, from: first, to: end) {
                tokens.add(first, end, .meta)
                if backtick { st.depth |= 1 }
            } else {
                tokens.add(first, end, .comment)
                st.depth |= 2
            }
            state.main = st
            return
        }
        st.depth |= 2
        state.main = st
        lexInstruction(line, from: first, to: end, escapeChar: escapeChar, state: &state, tokens: &tokens, nested: false)
    }

    /// `# syntax=docker/dockerfile:1`, `# escape=\``. Returns whether the escape character becomes a
    /// backtick, or nil when the comment is not a parser directive.
    private func parserDirective(_ line: LineBuffer, from i: Int, to end: Int) -> Bool? {
        let ns = line.skipSpaces(i + 1)
        var ne = ns
        while ne < end, Ch.isAlpha(line[ne]) { ne += 1 }
        let eq = line.skipSpaces(ne)
        guard eq < end, line[eq] == Ch.equals, ConfigLexKit.lowercasedWord(line, ns, ne, in: Self.directives) else { return nil }
        let value = line.skipSpaces(eq + 1)
        return line.lowercasedString(ns, ne) == "escape" && line[value] == Ch.backtick
    }

    private func continues(_ line: LineBuffer, _ first: Int, _ end: Int, _ escapeChar: UInt16) -> Bool {
        end > first && line[end - 1] == escapeChar
    }

    private func isTerminator(_ line: LineBuffer, _ s: Int, _ e: Int, hash: Int32) -> Bool {
        var k = s
        while k < e {
            let c = line[k]
            if c == Ch.quote || c == Ch.apostrophe || c == Ch.backslash { return false }
            k += 1
        }
        return ConfigLexKit.delimiterHash(line, s, e) == hash
    }

    // MARK: Instructions

    private func lexInstruction(_ line: LineBuffer, from i: Int, to end: Int, escapeChar: UInt16,
                                state: inout LineState, tokens: inout TokenBuffer, nested: Bool) {
        var we = i
        while we < end, Ch.isAlpha(line[we]) { we += 1 }
        guard we > i, we >= end || Ch.isSpace(line[we]), ConfigLexKit.lowercasedWord(line, i, we, in: Self.instructions) else {
            lexArguments(line, from: i, to: end, kind: Kind.other, escapeChar: escapeChar, state: &state, tokens: &tokens)
            return
        }
        tokens.add(i, we, .keyword)
        let name = line.lowercasedString(i, we)
        var j = line.skipSpaces(we)
        switch name {
        case "onbuild":
            if j < end, !nested {
                lexInstruction(line, from: j, to: end, escapeChar: escapeChar, state: &state, tokens: &tokens, nested: true)
            }
        case "from":
            j = lexFlags(line, from: j, to: end, tokens: &tokens)
            lexFrom(line, from: j, to: end, escapeChar: escapeChar, state: &state, tokens: &tokens)
        case "run", "cmd", "entrypoint", "shell":
            j = lexFlags(line, from: j, to: end, tokens: &tokens)
            lexCommand(line, from: j, to: end, heredocs: name == "run", escapeChar: escapeChar, state: &state, tokens: &tokens)
        case "healthcheck":
            j = lexFlags(line, from: j, to: end, tokens: &tokens)
            var ce = j
            while ce < end, Ch.isAlpha(line[ce]) { ce += 1 }
            let word = ce - j <= 4 ? line.lowercasedString(j, ce) : ""
            if word == "cmd" {
                tokens.add(j, ce, .keyword)
                let command = line.skipSpaces(ce)
                lexCommand(line, from: command, to: end, heredocs: false, escapeChar: escapeChar, state: &state, tokens: &tokens)
            } else if word == "none" {
                tokens.add(j, ce, .keyword)
            } else {
                lexArguments(line, from: j, to: end, kind: Kind.other, escapeChar: escapeChar, state: &state, tokens: &tokens)
            }
        case "env", "arg", "label":
            lexArguments(line, from: j, to: end, kind: Kind.keyValue, escapeChar: escapeChar, state: &state, tokens: &tokens)
        case "expose":
            lexArguments(line, from: j, to: end, kind: Kind.expose, escapeChar: escapeChar, state: &state, tokens: &tokens)
        case "maintainer":
            lexArguments(line, from: j, to: end, kind: Kind.maintainer, escapeChar: escapeChar, state: &state, tokens: &tokens)
        case "copy", "add":
            j = lexFlags(line, from: j, to: end, tokens: &tokens)
            if line[j] == Ch.lt, line[j + 1] == Ch.lt,
               let after = lexHeredocStart(line, at: j, to: end, script: false, state: &state, tokens: &tokens) {
                _ = lexArguments(line, from: after, to: end, kind: Kind.other, escapeChar: escapeChar, tokens: &tokens)
                return
            }
            lexArguments(line, from: j, to: end, kind: Kind.other, escapeChar: escapeChar, state: &state, tokens: &tokens)
        default:
            lexArguments(line, from: j, to: end, kind: Kind.other, escapeChar: escapeChar, state: &state, tokens: &tokens)
        }
    }

    private func setArguments(_ continues: Bool, _ kind: UInt8, _ state: inout LineState) {
        guard continues else { return }
        state.main.mode = Mode.arguments
        state.main.sub = kind
    }

    /// Lexes the arguments of an instruction and, when they end with a continuation, keeps lexing
    /// the following lines as arguments of the same kind.
    private func lexArguments(_ line: LineBuffer, from s: Int, to end: Int, kind: UInt8, escapeChar: UInt16,
                              state: inout LineState, tokens: inout TokenBuffer) {
        setArguments(lexArguments(line, from: s, to: end, kind: kind, escapeChar: escapeChar, tokens: &tokens), kind, &state)
    }

    /// `--from=builder`, `--chown=app:app`, `--mount=type=cache,target=/root/.cache`.
    private func lexFlags(_ line: LineBuffer, from j: Int, to end: Int, tokens: inout TokenBuffer) -> Int {
        var k = j
        while k + 1 < end, line[k] == Ch.minus, line[k + 1] == Ch.minus {
            var fe = k + 2
            while fe < end, Ch.isAlnum(line[fe]) || line[fe] == Ch.minus || line[fe] == Ch.underscore { fe += 1 }
            tokens.add(k, fe, .attribute)
            k = fe
            if k < end, line[k] == Ch.equals {
                tokens.add(k, k + 1, .operator)
                var ve = k + 1
                while ve < end, !Ch.isSpace(line[ve]) {
                    if line[ve] == Ch.quote || line[ve] == Ch.apostrophe {
                        ve = ConfigLexKit.closingQuote(line, from: ve, limit: end) ?? end
                    } else {
                        ve += 1
                    }
                }
                lexFlagValue(line, from: k + 1, to: ve, tokens: &tokens)
                k = ve
            }
            k = line.skipSpaces(k)
        }
        return k
    }

    /// `type=cache,target=/root/.cache` or a plain value; `$VAR` references are variables.
    private func lexFlagValue(_ line: LineBuffer, from s: Int, to e: Int, tokens: inout TokenBuffer) {
        var k = s
        while k < e {
            let c = line[k]
            if c == Ch.comma {
                tokens.add(k, k + 1, .punctuation)
                k += 1
                continue
            }
            if c == Ch.equals {
                tokens.add(k, k + 1, .operator)
                k += 1
                continue
            }
            if c == Ch.quote || c == Ch.apostrophe {
                let close = ConfigLexKit.closingQuote(line, from: k, limit: e) ?? e
                ConfigLexKit.addInterpolated(line, k, close, tokens: &tokens)
                k = close
                continue
            }
            var r = k
            while r < e, line[r] != Ch.comma, line[r] != Ch.equals, line[r] != Ch.quote, line[r] != Ch.apostrophe { r += 1 }
            if r < e, line[r] == Ch.equals {
                tokens.add(k, r, .property)
            } else {
                ConfigLexKit.addInterpolated(line, k, r, escapes: false, tokens: &tokens)
            }
            k = max(r, k + 1)
        }
    }

    /// `FROM [--platform=…] image[:tag|@digest] [AS name]`
    private func lexFrom(_ line: LineBuffer, from j: Int, to end: Int, escapeChar: UInt16, state: inout LineState, tokens: inout TokenBuffer) {
        let cont = continues(line, j, end, escapeChar)
        let argEnd = cont ? end - 1 : end
        var ie = j
        while ie < argEnd, !Ch.isSpace(line[ie]) { ie += 1 }
        ConfigLexKit.addInterpolated(line, j, ie, escapes: false, tokens: &tokens)
        var k = line.skipSpaces(ie)
        var ae = k
        while ae < argEnd, Ch.isAlpha(line[ae]) { ae += 1 }
        if ae - k == 2, line.lowercasedString(k, ae) == "as" {
            tokens.add(k, ae, .keyword)
            k = line.skipSpaces(ae)
            var ne = k
            while ne < argEnd, !Ch.isSpace(line[ne]) { ne += 1 }
            tokens.add(k, ne, .type)
        }
        if cont {
            tokens.add(end - 1, end, .escape)
            setArguments(true, Kind.other, &state)
        }
    }

    /// Shell form (embedded shell), exec form (`["a", "b"]`) or a `RUN <<EOF` heredoc script.
    private func lexCommand(_ line: LineBuffer, from j: Int, to end: Int, heredocs: Bool, escapeChar: UInt16,
                            state: inout LineState, tokens: inout TokenBuffer) {
        guard j < end else { return }
        if line[j] == Ch.lbracket {
            lexArguments(line, from: j, to: end, kind: Kind.exec, escapeChar: escapeChar, state: &state, tokens: &tokens)
            return
        }
        if heredocs, line[j] == Ch.lt, line[j + 1] == Ch.lt, line[j + 2] != Ch.lt,
           let after = lexHeredocStart(line, at: j, to: end, script: true, state: &state, tokens: &tokens) {
            // The rest of the line (`RUN <<EOF bash -ex`) is a command line of its own.
            if after < line.end {
                var scratch = LexState.initial
                lexEmbedded(.shell, line.slice(after, line.end), inner: &scratch, tokens: &tokens)
            }
            return
        }
        state.embedded = .shell
        state.inner = .initial
        if j == end - 1, line[j] == escapeChar {
            // `RUN --mount=… \`: the command itself starts on the next line.
            tokens.add(j, end, .escape)
            state.main.mode = Mode.shell
            return
        }
        lexEmbedded(.shell, line.slice(j, line.end), inner: &state.inner, tokens: &tokens)
        if continues(line, j, end, escapeChar) || ShellLexer.isInHeredoc(state.inner) {
            state.main.mode = Mode.shell
        } else {
            state.embedded = nil
            state.inner = .initial
        }
    }

    /// `<<EOF`, `<<-EOF`, `<<"EOF"`: emits the operator and delimiter and enters a heredoc mode.
    private func lexHeredocStart(_ line: LineBuffer, at j: Int, to end: Int, script: Bool,
                                 state: inout LineState, tokens: inout TokenBuffer) -> Int? {
        var opEnd = j + 2
        var strip = false
        if line[opEnd] == Ch.minus {
            strip = true
            opEnd += 1
        }
        guard opEnd < end, let d = ConfigLexKit.scanHeredocDelimiter(line, from: opEnd, limit: end) else { return nil }
        tokens.add(j, opEnd, .operator)
        tokens.add(opEnd, d.end, .meta)
        state.main.mode = script ? Mode.heredocScript : Mode.heredocText
        state.main.sub = strip ? 1 : 0
        state.main.data = ConfigLexKit.delimiterHash(line, opEnd, d.end)
        state.embedded = script ? .shell : nil
        state.inner = .initial
        return d.end
    }

    // MARK: Arguments

    /// Lexes instruction arguments; returns whether they continue on the next line.
    private func lexArguments(_ line: LineBuffer, from s: Int, to end: Int, kind: UInt8, escapeChar: UInt16,
                              tokens: inout TokenBuffer) -> Bool {
        let cont = continues(line, s, end, escapeChar)
        let e = cont ? end - 1 : end
        switch kind {
        case Kind.keyValue:
            lexKeyValues(line, from: s, to: e, tokens: &tokens)
        case Kind.exec:
            lexExecForm(line, from: s, to: e, tokens: &tokens)
        case Kind.maintainer:
            tokens.add(s, e, .string)
        default:
            lexWords(line, from: s, to: e, numbers: kind == Kind.expose, tokens: &tokens)
        }
        if cont { tokens.add(end - 1, end, .escape) }
        return cont
    }

    /// `KEY=value KEY2="v 2"` and the legacy `ENV KEY value` form.
    private func lexKeyValues(_ line: LineBuffer, from s: Int, to e: Int, tokens: inout TokenBuffer) {
        var k = s
        while k < e {
            if Ch.isSpace(line[k]) {
                k += 1
                continue
            }
            let ks = k
            if line[k] == Ch.quote || line[k] == Ch.apostrophe {
                k = ConfigLexKit.closingQuote(line, from: k, limit: e) ?? e
            } else {
                while k < e, !Ch.isSpace(line[k]), line[k] != Ch.equals { k += 1 }
            }
            guard k < e, line[k] == Ch.equals else {
                // Legacy form: everything after the key is the value.
                tokens.add(ks, k, .property)
                let vs = line.skipSpaces(k)
                if vs < e { ConfigLexKit.addInterpolated(line, vs, e, tokens: &tokens) }
                return
            }
            tokens.add(ks, k, .property)
            tokens.add(k, k + 1, .operator)
            k += 1
            if k < e, line[k] == Ch.quote || line[k] == Ch.apostrophe {
                let close = ConfigLexKit.closingQuote(line, from: k, limit: e) ?? e
                if line[k] == Ch.quote {
                    ConfigLexKit.addInterpolated(line, k, close, tokens: &tokens)
                } else {
                    tokens.add(k, close, .string)
                }
                k = close
            } else {
                var ve = k
                while ve < e, !Ch.isSpace(line[ve]) { ve += line[ve] == Ch.backslash ? 2 : 1 }
                ve = min(ve, e)
                ConfigLexKit.addInterpolated(line, k, ve, tokens: &tokens)
                k = ve
            }
        }
    }

    /// `["executable", "param"]`
    private func lexExecForm(_ line: LineBuffer, from s: Int, to e: Int, tokens: inout TokenBuffer) {
        var k = s
        while k < e {
            let c = line[k]
            switch c {
            case Ch.lbracket, Ch.rbracket, Ch.comma:
                tokens.add(k, k + 1, .punctuation)
                k += 1
            case Ch.quote:
                let close = ConfigLexKit.closingQuote(line, from: k, limit: e) ?? e
                ConfigLexKit.addEscaped(line, k, close, tokens: &tokens)
                k = close
            case Ch.dollar:
                if let r = ConfigLexKit.dollarReferenceEnd(line, at: k, limit: e, parens: false) {
                    tokens.add(k, r, .variable)
                    k = r
                } else {
                    k += 1
                }
            default:
                k += 1
            }
        }
    }

    /// Generic arguments: exec-form arrays, flags, strings, `$VAR` and (for EXPOSE) port numbers.
    private func lexWords(_ line: LineBuffer, from s: Int, to e: Int, numbers: Bool, tokens: inout TokenBuffer) {
        var k = s
        while k < e {
            let c = line[k]
            if Ch.isSpace(c) {
                k += 1
                continue
            }
            if c == Ch.lbracket, k == s {
                lexExecForm(line, from: k, to: e, tokens: &tokens)
                return
            }
            if c == Ch.minus, line[k + 1] == Ch.minus {
                k = lexFlags(line, from: k, to: e, tokens: &tokens)
                continue
            }
            if c == Ch.quote || c == Ch.apostrophe {
                let close = ConfigLexKit.closingQuote(line, from: k, limit: e) ?? e
                if c == Ch.quote {
                    ConfigLexKit.addInterpolated(line, k, close, tokens: &tokens)
                } else {
                    tokens.add(k, close, .string)
                }
                k = close
                continue
            }
            if c == Ch.dollar {
                if let r = ConfigLexKit.dollarReferenceEnd(line, at: k, limit: e, parens: false) {
                    tokens.add(k, r, .variable)
                    k = r
                } else {
                    k += 1
                }
                continue
            }
            var we = k
            while we < e, !Ch.isSpace(line[we]), line[we] != Ch.dollar, line[we] != Ch.quote, line[we] != Ch.apostrophe { we += 1 }
            if we == k { we = k + 1 }
            if numbers, Ch.isDigit(c) {
                tokens.add(k, we, .number)
            }
            k = we
        }
    }
}
