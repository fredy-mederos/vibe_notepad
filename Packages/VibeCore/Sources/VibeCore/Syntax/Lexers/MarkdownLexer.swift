import Foundation

/// Markdown source highlighting: headings, emphasis, code spans, links, lists and task
/// boxes, block quotes and alerts, tables, HTML, YAML front matter, and fenced code blocks
/// highlighted with the fence's language.
public struct MarkdownLexer: SyntaxLexer {
    public init() {}

    enum Mode {
        static let normal: UInt8 = 0
        static let documentStart: UInt8 = 1
        static let frontMatter: UInt8 = 2
        static let fence: UInt8 = 3
        static let htmlComment: UInt8 = 4
    }

    public var initialState: LineState {
        LineState(main: LexState(mode: Mode.documentStart))
    }

    private static let commentOpen = u16("<!--")
    private static let commentClose = u16("-->")
    private static let frontMatterFence = u16("---")
    private static let frontMatterEnd = u16("...")
    private static let https = u16("https://")
    private static let http = u16("http://")
    private static let www = u16("www.")

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        switch state.main.mode {
        case Mode.documentStart:
            state.main = .initial
            if isOnly(line, Self.frontMatterFence) {
                tokens.add(line.start, line.trimmedEnd, .markup)
                state = LineState(main: LexState(mode: Mode.frontMatter), embedded: .yaml, inner: .initial)
                return
            }
        case Mode.frontMatter:
            if isOnly(line, Self.frontMatterFence) || isOnly(line, Self.frontMatterEnd) {
                tokens.add(line.start, line.trimmedEnd, .markup)
                state = LineState()
                return
            }
            lexEmbedded(.yaml, line, inner: &state.inner, tokens: &tokens)
            return
        case Mode.fence:
            let fenceChar = state.main.sub == 0 ? Ch.backtick : Ch.tilde
            if isClosingFence(line, char: fenceChar, length: Int(state.main.data)) {
                tokens.add(line.firstNonSpace, line.trimmedEnd, .markup)
                state = LineState()
                return
            }
            if let language = state.embedded {
                lexEmbedded(language, line, inner: &state.inner, tokens: &tokens)
            } else {
                tokens.add(line.start, line.end, .code)
            }
            return
        case Mode.htmlComment:
            if let close = line.find(Self.commentClose, from: line.start) {
                tokens.add(line.start, close + 3, .comment)
                state.main = .initial
                lexInline(line, close + 3, line.end, base: .plain, tablePipes: false, tokens: &tokens)
            } else {
                tokens.add(line.start, line.end, .comment)
            }
            return
        default:
            break
        }
        lexBlockLine(line, state: &state, tokens: &tokens)
    }

    // MARK: Block structure

    private func lexBlockLine(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        let first = line.firstNonSpace
        guard first < line.end else { return }
        let indent = first - line.start
        let c = line[first]

        // Fenced code block opener.
        if c == Ch.backtick || c == Ch.tilde {
            var j = first
            while line[j] == c { j += 1 }
            let count = j - first
            if count >= 3, c == Ch.tilde || (line.find(Ch.backtick, from: j) == nil) {
                let infoStart = line.skipSpaces(j)
                let infoEnd = line.trimmedEnd
                tokens.add(first, j, .markup)
                tokens.add(infoStart, infoEnd, .meta)
                var language = LanguageRegistry.language(forFenceInfo: line.string(infoStart, infoEnd))
                if language == .plainText { language = nil }
                state = LineState(
                    main: LexState(mode: Mode.fence, sub: c == Ch.backtick ? 0 : 1, data: Int32(count)),
                    embedded: language,
                    inner: language?.lexer.initialState.main ?? .initial
                )
                return
            }
        }

        // ATX heading.
        if c == Ch.hash, indent <= 3 {
            var j = first
            while line[j] == Ch.hash { j += 1 }
            if j - first <= 6, j >= line.end || Ch.isSpace(line[j]) {
                tokens.add(first, j, .markup)
                var textEnd = line.trimmedEnd
                var closing = textEnd
                while closing > j, line[closing - 1] == Ch.hash { closing -= 1 }
                var closingRange: Range<Int>?
                if closing < textEnd, closing > j, Ch.isSpace(line[closing - 1]) {
                    closingRange = closing..<textEnd
                    textEnd = closing
                }
                lexInline(line, line.skipSpaces(j), textEnd, base: .heading, tablePipes: false, tokens: &tokens)
                if let closingRange { tokens.add(closingRange.lowerBound, closingRange.upperBound, .markup) }
                return
            }
        }

        // Thematic breaks and setext underlines.
        if indent <= 3, c == Ch.minus || c == Ch.star || c == Ch.underscore || c == Ch.equals, isRule(line, from: first, char: c) {
            tokens.add(first, line.trimmedEnd, .markup)
            return
        }

        // HTML comments and HTML block lines.
        if line.matches(Self.commentOpen, at: first) {
            if let close = line.find(Self.commentClose, from: first + 4) {
                tokens.add(first, close + 3, .comment)
                lexInline(line, close + 3, line.end, base: .plain, tablePipes: false, tokens: &tokens)
            } else {
                tokens.add(first, line.end, .comment)
                state.main = LexState(mode: Mode.htmlComment)
            }
            return
        }
        if c == Ch.lt, Ch.isAlpha(line[first + 1]) || (line[first + 1] == Ch.slash && Ch.isAlpha(line[first + 2])), line.find(Ch.gt, from: first) != nil {
            var inner = LexState.initial
            lexEmbedded(.html, line.slice(first, line.end), inner: &inner, tokens: &tokens)
            return
        }

        // Link reference definitions and footnote definitions: `[label]: url "title"`.
        if c == Ch.lbracket, indent <= 3, let close = line.find(Ch.rbracket, from: first + 1), line[close + 1] == Ch.colon {
            tokens.add(first, close + 1, .link)
            tokens.add(close + 1, close + 2, .markup)
            if line[first + 1] == Ch.caret {
                lexInline(line, close + 2, line.end, base: .plain, tablePipes: false, tokens: &tokens)
                return
            }
            let urlStart = line.skipSpaces(close + 2)
            var urlEnd = urlStart
            while urlEnd < line.end, !Ch.isSpace(line[urlEnd]) { urlEnd += 1 }
            tokens.add(urlStart, urlEnd, .url)
            let titleStart = line.skipSpaces(urlEnd)
            if titleStart < line.end { tokens.add(titleStart, line.trimmedEnd, .string) }
            return
        }

        var i = first
        var base = TokenKind.plain

        // Block quotes, possibly nested, with GitHub alert markers.
        if c == Ch.gt {
            while line[i] == Ch.gt {
                tokens.add(i, i + 1, .markup)
                i = line.skipSpaces(i + 1)
            }
            base = .quote
            if line[i] == Ch.lbracket, line[i + 1] == Ch.bang, let close = line.find(Ch.rbracket, from: i), close < line.end {
                tokens.add(i, close + 1, .keyword)
                i = line.skipSpaces(close + 1)
            }
            if i >= line.end { return }
            if line[i] == Ch.hash {
                var j = i
                while line[j] == Ch.hash { j += 1 }
                if j - i <= 6, Ch.isSpace(line[j]) || j >= line.end {
                    tokens.add(i, j, .markup)
                    lexInline(line, line.skipSpaces(j), line.end, base: .heading, tablePipes: false, tokens: &tokens)
                    return
                }
            }
        }

        // List items and task boxes.
        if let markerEnd = listMarkerEnd(line, at: i) {
            tokens.add(i, markerEnd, .listMarker)
            var j = line.skipSpaces(markerEnd)
            if line[j] == Ch.lbracket, line[j + 2] == Ch.rbracket, j + 3 >= line.end || Ch.isSpace(line[j + 3]) {
                let mark = line[j + 1]
                if mark == Ch.space || mark == Ch.x || mark == 0x58 /* X */ {
                    let checked = mark != Ch.space
                    tokens.add(j, j + 3, checked ? .inserted : .listMarker)
                    j = line.skipSpaces(j + 3)
                    if checked { base = .comment }
                }
            }
            i = j
        }

        // Table delimiter rows (`| --- | :---: |`).
        if isTableDelimiterRow(line, from: i) {
            tokens.add(i, line.trimmedEnd, .markup)
            return
        }

        let tablePipes = line[i] == Ch.pipe || line.find(u16(" | "), from: i) != nil
        lexInline(line, i, line.end, base: base, tablePipes: tablePipes, tokens: &tokens)
    }

    // MARK: Inline

    /// Per-character classification so overlapping constructs resolve by precedence:
    /// code spans > escapes/autolinks/HTML > links > emphasis.
    private struct InlineMap {
        let start: Int
        var kinds: [TokenKind]
        var locked: [Bool]

        init(start: Int, count: Int, base: TokenKind) {
            self.start = start
            kinds = Array(repeating: base, count: count)
            locked = Array(repeating: false, count: count)
        }

        func isLocked(_ i: Int) -> Bool {
            let k = i - start
            return k >= 0 && k < locked.count ? locked[k] : true
        }

        mutating func set(_ s: Int, _ e: Int, _ kind: TokenKind, lock: Bool) {
            let lo = max(s - start, 0), hi = min(e - start, kinds.count)
            guard lo < hi else { return }
            for k in lo..<hi where !locked[k] {
                kinds[k] = kind
                if lock { locked[k] = true }
            }
        }
    }

    private func lexInline(_ line: LineBuffer, _ start: Int, _ end: Int, base: TokenKind, tablePipes: Bool, tokens: inout TokenBuffer) {
        let count = end - start
        guard count > 0 else { return }
        var map = InlineMap(start: start, count: count, base: base)

        markCodeSpans(line, start, end, &map)
        markAtoms(line, start, end, &map)
        markLinks(line, start, end, &map)
        markEmphasis(line, start, end, &map, depth: 0)
        if tablePipes {
            for i in start..<end where line[i] == Ch.pipe && line[i - 1] != Ch.backslash && !map.isLocked(i) {
                map.set(i, i + 1, .markup, lock: true)
            }
        }

        var runStart = 0
        while runStart < count {
            let kind = map.kinds[runStart]
            var runEnd = runStart + 1
            while runEnd < count, map.kinds[runEnd] == kind { runEnd += 1 }
            tokens.add(start + runStart, start + runEnd, kind)
            runStart = runEnd
        }
    }

    private func markCodeSpans(_ line: LineBuffer, _ start: Int, _ end: Int, _ map: inout InlineMap) {
        var i = start
        while i < end {
            let c = line[i]
            if c == Ch.backslash { i += 2; continue }
            guard c == Ch.backtick else { i += 1; continue }
            var j = i
            while j < end, line[j] == Ch.backtick { j += 1 }
            let run = j - i
            var k = j
            var closer: Int?
            while k < end {
                if line[k] == Ch.backtick {
                    var m = k
                    while m < end, line[m] == Ch.backtick { m += 1 }
                    if m - k == run { closer = k; break }
                    k = m
                } else {
                    k += 1
                }
            }
            if let closer {
                map.set(i, j, .markup, lock: true)
                map.set(j, closer, .code, lock: true)
                map.set(closer, closer + run, .markup, lock: true)
                i = closer + run
            } else {
                i = j
            }
        }
    }

    /// Escapes, autolinks, inline HTML/comments and bare URLs.
    private func markAtoms(_ line: LineBuffer, _ start: Int, _ end: Int, _ map: inout InlineMap) {
        var i = start
        while i < end {
            if map.isLocked(i) { i += 1; continue }
            let c = line[i]
            if c == Ch.backslash, i + 1 < end, isASCIIPunctuation(line[i + 1]) {
                map.set(i, i + 2, .escape, lock: true)
                i += 2
                continue
            }
            if c == Ch.lt {
                if line.matches(Self.commentOpen, at: i), let close = line.find(Self.commentClose, from: i + 4), close + 3 <= end {
                    map.set(i, close + 3, .comment, lock: true)
                    i = close + 3
                    continue
                }
                if let close = line.find(Ch.gt, from: i + 1), close < end {
                    if isAutolink(line, i + 1, close) {
                        map.set(i, i + 1, .markup, lock: true)
                        map.set(i + 1, close, .url, lock: true)
                        map.set(close, close + 1, .markup, lock: true)
                        i = close + 1
                        continue
                    }
                    if Ch.isAlpha(line[i + 1]) || (line[i + 1] == Ch.slash && Ch.isAlpha(line[i + 2])) {
                        map.set(i, close + 1, .tag, lock: true)
                        i = close + 1
                        continue
                    }
                }
            }
            if c == 0x68 /* h */ || c == 0x77 /* w */, i == start || !Ch.isAlnum(line[i - 1]), let urlEnd = bareURLEnd(line, i, end) {
                map.set(i, urlEnd, .url, lock: true)
                i = urlEnd
                continue
            }
            i += 1
        }
    }

    private func markLinks(_ line: LineBuffer, _ start: Int, _ end: Int, _ map: inout InlineMap) {
        var i = start
        while i < end {
            if map.isLocked(i) { i += 1; continue }
            let isImage = line[i] == Ch.bang && line[i + 1] == Ch.lbracket
            guard line[i] == Ch.lbracket || isImage else { i += 1; continue }
            let open = isImage ? i + 1 : i
            guard let close = matching(line, from: open, end: end, open: Ch.lbracket, close: Ch.rbracket, map: map) else {
                i += 1
                continue
            }
            let after = close + 1
            if line[after] == Ch.lparen, after < end,
               let parenClose = matching(line, from: after, end: end, open: Ch.lparen, close: Ch.rparen, map: map) {
                map.set(i, open + 1, .markup, lock: true)
                map.set(open + 1, close, .link, lock: true)
                map.set(close, after + 1, .markup, lock: true)
                let urlStart = line.skipSpaces(after + 1)
                var urlEnd = urlStart
                while urlEnd < parenClose, !Ch.isSpace(line[urlEnd]) { urlEnd += 1 }
                map.set(urlStart, urlEnd, .url, lock: true)
                if urlEnd < parenClose { map.set(line.skipSpaces(urlEnd), parenClose, .string, lock: true) }
                map.set(parenClose, parenClose + 1, .markup, lock: true)
                i = parenClose + 1
                continue
            }
            if line[after] == Ch.lbracket, let refClose = line.find(Ch.rbracket, from: after + 1), refClose < end {
                map.set(i, open + 1, .markup, lock: true)
                map.set(open + 1, close, .link, lock: true)
                map.set(close, after + 1, .markup, lock: true)
                map.set(after + 1, refClose, .url, lock: true)
                map.set(refClose, refClose + 1, .markup, lock: true)
                i = refClose + 1
                continue
            }
            if line[open + 1] == Ch.caret {
                map.set(i, close + 1, .link, lock: true)
                i = close + 1
                continue
            }
            i = open + 1
        }
    }

    private func markEmphasis(_ line: LineBuffer, _ start: Int, _ end: Int, _ map: inout InlineMap, depth: Int) {
        var i = start
        while i < end {
            let c = line[i]
            guard c == Ch.star || c == Ch.underscore || c == Ch.tilde, !map.isLocked(i) else { i += 1; continue }
            var j = i
            while j < end, line[j] == c, !map.isLocked(j) { j += 1 }
            let run = j - i
            let previous = i > line.start ? line[i - 1] : Ch.space
            let next = j < end ? line[j] : 0
            let canOpen = next != 0 && !Ch.isSpace(next) && (c != Ch.underscore || !Ch.isAlnum(previous)) && (c != Ch.tilde || run <= 2)
            guard canOpen else { i = j; continue }

            var k = j
            var closer: Int?
            while k < end {
                if map.isLocked(k) || line[k] != c { k += 1; continue }
                var m = k
                while m < end, line[m] == c, !map.isLocked(m) { m += 1 }
                let length = m - k
                let before = line[k - 1]
                let after = m < end ? line[m] : Ch.space
                let canClose = !Ch.isSpace(before) && (c != Ch.underscore || !Ch.isAlnum(after))
                if canClose, length == run || (run >= 3 && length >= 3) {
                    closer = k
                    break
                }
                k = m
            }
            guard let closer else { i = j; continue }
            let kind: TokenKind = c == Ch.tilde ? .strikethrough : (run == 1 ? .emphasis : .strong)
            map.set(closer, closer + run, .markup, lock: true)
            map.set(j, closer, kind, lock: false)
            map.set(i, j, .markup, lock: true)
            if depth < 3 { markEmphasis(line, j, closer, &map, depth: depth + 1) }
            i = closer + run
        }
    }

    // MARK: Helpers

    private func isOnly(_ line: LineBuffer, _ literal: [UInt16]) -> Bool {
        line.matches(literal, at: line.start) && line.trimmedEnd == line.start + literal.count
    }

    private func isClosingFence(_ line: LineBuffer, char: UInt16, length: Int) -> Bool {
        let first = line.firstNonSpace
        var j = first
        while line[j] == char { j += 1 }
        return j - first >= length && line.skipSpaces(j) >= line.end
    }

    private func isRule(_ line: LineBuffer, from first: Int, char: UInt16) -> Bool {
        var count = 0
        var j = first
        while j < line.end {
            let d = line[j]
            if d == char { count += 1 } else if !Ch.isSpace(d) { return false }
            j += 1
        }
        if char == Ch.equals { return count >= 2 && line.find(Ch.space, from: first).map({ $0 >= line.trimmedEnd }) ?? true }
        return count >= 3
    }

    private func listMarkerEnd(_ line: LineBuffer, at i: Int) -> Int? {
        let c = line[i]
        if c == Ch.minus || c == Ch.star || c == Ch.plus {
            return i + 1 >= line.end || Ch.isSpace(line[i + 1]) ? i + 1 : nil
        }
        guard Ch.isDigit(c) else { return nil }
        var j = i
        while Ch.isDigit(line[j]), j - i < 9 { j += 1 }
        if line[j] == Ch.dot || line[j] == Ch.rparen, j + 1 >= line.end || Ch.isSpace(line[j + 1]) {
            return j + 1
        }
        return nil
    }

    private func isTableDelimiterRow(_ line: LineBuffer, from i: Int) -> Bool {
        var dashes = 0, pipes = 0
        var j = i
        while j < line.end {
            let c = line[j]
            switch c {
            case Ch.minus: dashes += 1
            case Ch.pipe: pipes += 1
            case Ch.colon, Ch.space, Ch.tab, Ch.cr: break
            default: return false
            }
            j += 1
        }
        return dashes >= 3 && pipes >= 1
    }

    private func isAutolink(_ line: LineBuffer, _ s: Int, _ e: Int) -> Bool {
        guard e - s >= 3 else { return false }
        var sawColon = false, sawAt = false
        for k in s..<e {
            let c = line[k]
            if Ch.isSpace(c) || c == Ch.lt { return false }
            if c == Ch.colon { sawColon = true }
            if c == Ch.at { sawAt = true }
        }
        return (sawColon && Ch.isAlpha(line[s])) || sawAt
    }

    private func bareURLEnd(_ line: LineBuffer, _ i: Int, _ end: Int) -> Int? {
        let prefix: Int
        if line.matches(Self.https, at: i) { prefix = 8 } else if line.matches(Self.http, at: i) { prefix = 7 } else if line.matches(Self.www, at: i) { prefix = 4 } else { return nil }
        var j = i + prefix
        while j < end, !Ch.isSpace(line[j]), line[j] != Ch.lt { j += 1 }
        // Trim trailing punctuation and unbalanced closing parentheses.
        while j > i + prefix {
            let c = line[j - 1]
            if c == Ch.dot || c == Ch.comma || c == Ch.colon || c == Ch.semicolon || c == Ch.bang || c == Ch.question
                || c == Ch.star || c == Ch.underscore || c == Ch.tilde || c == Ch.quote || c == Ch.apostrophe {
                j -= 1
                continue
            }
            if c == Ch.rparen {
                var balance = 0
                for k in i..<j { if line[k] == Ch.lparen { balance += 1 } else if line[k] == Ch.rparen { balance -= 1 } }
                if balance < 0 { j -= 1; continue }
            }
            break
        }
        return j > i + prefix ? j : nil
    }

    private func matching(_ line: LineBuffer, from: Int, end: Int, open: UInt16, close: UInt16, map: InlineMap) -> Int? {
        var depth = 0
        var j = from
        while j < end {
            if line[j] == Ch.backslash { j += 2; continue }
            if !map.isLocked(j) || j == from {
                if line[j] == open { depth += 1 } else if line[j] == close {
                    depth -= 1
                    if depth == 0 { return j }
                }
            }
            j += 1
        }
        return nil
    }

    private func isASCIIPunctuation(_ c: UInt16) -> Bool {
        (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
    }
}
