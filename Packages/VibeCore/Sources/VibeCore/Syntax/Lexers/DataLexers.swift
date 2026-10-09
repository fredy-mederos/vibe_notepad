import Foundation

// MARK: - Diff

/// Unified and context diffs, patches and `git log -p` output.
///
/// State: `mode == 1` inside a unified hunk, with the number of old/new lines still expected in
/// `depth`/`data` (so a `--- x` line inside a hunk is a deleted line, not a file header);
/// `mode == 2` inside a hunk whose header could not be parsed (combined diffs).
public struct DiffLexer: SyntaxLexer {
    public init() {}

    enum Mode {
        static let normal: UInt8 = 0
        static let hunk: UInt8 = 1
        static let looseHunk: UInt8 = 2
    }

    private static let metaPrefixes: [[UInt16]] = [
        "diff ", "index ", "new file mode", "deleted file mode", "old mode", "new mode", "similarity index",
        "dissimilarity index", "rename from", "rename to", "copy from", "copy to", "Index: ", "Binary files ",
        "Only in ", "Files ", "RCS file:", "retrieving revision", "GIT binary patch",
    ].map(u16)
    private static let oldHeader = u16("--- ")
    private static let newHeader = u16("+++ ")
    private static let contextHeader = u16("*** ")
    private static let contextSeparator = u16("***************")
    private static let commit = u16("commit ")

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        var st = state.main
        let s = line.start
        let e = ConfigLexKit.contentEnd(line)
        let c = s < e ? line[s] : 0
        if st.mode == Mode.hunk {
            var old = Int(st.depth)
            var new = Int(st.data)
            var handled = true
            switch c {
            case 0, Ch.space:
                old -= 1
                new -= 1
            case Ch.minus:
                tokens.add(s, e, .deleted)
                old -= 1
            case Ch.plus:
                tokens.add(s, e, .inserted)
                new -= 1
            case Ch.backslash:
                tokens.add(s, e, .comment)
            default:
                handled = false
            }
            if handled {
                if old <= 0, new <= 0 {
                    state.main = .initial
                } else {
                    state.main = LexState(mode: Mode.hunk, depth: UInt16(clamping: max(0, old)), data: Int32(clamping: max(0, new)))
                }
                return
            }
            st = .initial
        }
        guard s < e else {
            state.main = st
            return
        }
        if c == Ch.at, line[s + 1] == Ch.at {
            state.main = lexHunkHeader(line, s, e, tokens: &tokens)
            return
        }
        if c == Ch.backslash {
            tokens.add(s, e, .comment)
        } else if line.matches(Self.oldHeader, at: s) || line.matches(Self.contextHeader, at: s) {
            // `--- 1,5 ----` / `*** 1,5 ****` are context-diff ranges; otherwise file headers.
            tokens.add(s, e, Ch.isDigit(line[s + 4]) ? .changed : .meta)
        } else if line.matches(Self.newHeader, at: s) || line.matches(Self.contextSeparator, at: s) || isMeta(line, s, e) {
            tokens.add(s, e, .meta)
        } else if c == Ch.plus {
            tokens.add(s, e, .inserted)
        } else if c == Ch.minus {
            tokens.add(s, e, .deleted)
        } else if c == Ch.bang, line[s + 1] == Ch.space {
            tokens.add(s, e, .changed)
        }
        state.main = st
    }

    private func isMeta(_ line: LineBuffer, _ s: Int, _ e: Int) -> Bool {
        for prefix in Self.metaPrefixes where line.matches(prefix, at: s) { return true }
        if line.matches(Self.commit, at: s), Ch.isHexDigit(line[s + 7]) { return true }
        // `====…` separators (svn, cvs)
        if e - s >= 3 {
            var k = s
            while k < e, line[k] == Ch.equals { k += 1 }
            if k == e { return true }
        }
        return false
    }

    /// `@@ -1,5 +1,6 @@ section`. Returns the state for the following lines.
    private func lexHunkHeader(_ line: LineBuffer, _ s: Int, _ e: Int, tokens: inout TokenBuffer) -> LexState {
        if let header = parseHunk(line, s, e) {
            tokens.add(s, header.end, .changed)
            tokens.add(line.skipSpaces(header.end), e, .function)
            if header.old <= 0, header.new <= 0 { return .initial }
            return LexState(mode: Mode.hunk, depth: UInt16(clamping: header.old), data: Int32(clamping: header.new))
        }
        // Combined diffs (`@@@ -a,b -c,d +e,f @@@`) and malformed headers.
        var marker = s
        while marker < e, line[marker] == Ch.at { marker += 1 }
        let width = marker - s
        var k = marker
        var close = e
        while k < e {
            if line[k] == Ch.at {
                var run = k
                while run < e, line[run] == Ch.at { run += 1 }
                if run - k >= width {
                    close = run
                    break
                }
                k = run
                continue
            }
            k += 1
        }
        tokens.add(s, close, .changed)
        tokens.add(line.skipSpaces(close), e, .function)
        return LexState(mode: Mode.looseHunk)
    }

    private func parseHunk(_ line: LineBuffer, _ s: Int, _ e: Int) -> (old: Int, new: Int, end: Int)? {
        var k = s + 2
        guard line[k] == Ch.space else { return nil }
        k = line.skipSpaces(k)
        guard line[k] == Ch.minus, let (_, a) = number(line, k + 1, e) else { return nil }
        k = a
        var old = 1
        if line[k] == Ch.comma {
            guard let (count, b) = number(line, k + 1, e) else { return nil }
            old = count
            k = b
        }
        k = line.skipSpaces(k)
        guard line[k] == Ch.plus, let (_, c) = number(line, k + 1, e) else { return nil }
        k = c
        var new = 1
        if line[k] == Ch.comma {
            guard let (count, d) = number(line, k + 1, e) else { return nil }
            new = count
            k = d
        }
        k = line.skipSpaces(k)
        guard line[k] == Ch.at, line[k + 1] == Ch.at, line[k + 2] != Ch.at else { return nil }
        return (old, new, k + 2)
    }

    private func number(_ line: LineBuffer, _ s: Int, _ e: Int) -> (Int, Int)? {
        var k = s
        var value = 0
        while k < e, Ch.isDigit(line[k]) {
            if value < 1_000_000_000 { value = value * 10 + Int(line[k] - Ch.zero) }
            k += 1
        }
        return k > s ? (value, k) : nil
    }
}

// MARK: - CSV / TSV

/// Delimiter-separated values: every field gets a rainbow color by column index.
///
/// State: `mode == 1` inside a quoted field that continues on the next line; `data` is its column.
public struct CSVLexer: SyntaxLexer {
    public let delimiter: UInt16

    public init(delimiter: UInt16 = Ch.comma) {
        self.delimiter = delimiter
    }

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        let end = ConfigLexKit.contentEnd(line)
        var column = 0
        var i = line.start
        var fieldStart = i
        var quoted = false
        if state.main.mode == 1 {
            column = Int(state.main.data)
            quoted = true
            i = line.start - 1
        }
        state.main = .initial
        while true {
            let kind = TokenKind.rainbow[column % TokenKind.rainbow.count]
            if quoted || (i < end && line[i] == Ch.quote) {
                // `i` is the opening quote (or one before the line start when continuing).
                guard let after = closingQuote(line, from: i + 1, end: end) else {
                    tokens.add(fieldStart, end, kind)
                    state.main = LexState(mode: 1, data: Int32(clamping: column))
                    return
                }
                i = after
                quoted = false
            }
            while i < end, line[i] != delimiter { i += 1 }
            tokens.add(fieldStart, i, kind)
            guard i < end else { return }
            tokens.add(i, i + 1, .punctuation)
            column += 1
            i += 1
            fieldStart = i
        }
    }

    /// Index after the quote closing a field (`""` is an escaped quote), or nil.
    private func closingQuote(_ line: LineBuffer, from j: Int, end: Int) -> Int? {
        var k = max(j, line.start)
        while k < end {
            if line[k] == Ch.quote {
                if k + 1 < end, line[k + 1] == Ch.quote {
                    k += 2
                    continue
                }
                return k + 1
            }
            k += 1
        }
        return nil
    }
}
