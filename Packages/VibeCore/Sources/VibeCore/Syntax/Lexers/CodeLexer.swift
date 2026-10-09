import Foundation

// MARK: - Specification

/// How a string literal handles embedded expressions.
public enum StringInterpolation: Sendable {
    case none
    /// `\( … )` (Swift)
    case backslashParen
    /// `${ … }` (JavaScript templates, HCL)
    case dollarBrace
    /// `$name` and `${ … }` (Kotlin, Dart, Groovy, Scala, PHP, Perl, PowerShell)
    case dollarNameAndBrace
    /// `#{ … }` (Ruby, Elixir)
    case hashBrace
    /// `{ … }` with `{{` escapes (Python f-strings, C# `$"…"`)
    case braces
}

public struct StringSpec: Sendable {
    public var open: [UInt16]
    public var close: [UInt16]
    /// Optional case-insensitive prefixes that must directly precede `open` (e.g. `f`, `r`, `@`).
    public var prefixes: [[UInt16]]
    public var escape: UInt16
    public var multiline: Bool
    public var interpolation: StringInterpolation
    /// `''` inside `'…'` is an escaped quote (SQL, C# verbatim strings).
    public var doubledCloseEscapes: Bool
    public var kind: TokenKind

    public init(_ open: String, _ close: String? = nil, prefixes: [String] = [], escape: Bool = true,
                multiline: Bool = false, interpolation: StringInterpolation = .none,
                doubledCloseEscapes: Bool = false, kind: TokenKind = .string) {
        self.open = u16(open)
        self.close = u16(close ?? open)
        self.prefixes = prefixes.map { u16($0.lowercased()) }
        self.escape = escape ? Ch.backslash : 0
        self.multiline = multiline
        self.interpolation = interpolation
        self.doubledCloseEscapes = doubledCloseEscapes
        self.kind = kind
    }
}

/// Declarative description of a C-like or scripting language for `CodeLexer`.
public struct CodeSpec: Sendable {
    public var lineComments: [[UInt16]] = []
    public var blockComments: [(open: [UInt16], close: [UInt16])] = []
    public var nestedComments = false
    public var strings: [StringSpec] = []

    public var keywords: Set<String> = []
    public var types: Set<String> = []
    public var constants: Set<String> = []
    public var builtins: Set<String> = []
    public var variables: Set<String> = []
    /// Keywords after which the next identifier is a function name (`func`, `def`, `fn`).
    public var functionDeclarations: Set<String> = []
    /// Keywords after which the next identifier is a type name (`class`, `struct`).
    public var typeDeclarations: Set<String> = []
    public var caseInsensitive = false

    public var identExtra: UInt16 = 0
    public var identExtra2: UInt16 = 0
    public var capitalizedTypes = false
    public var allCapsConstants = true
    /// C-style `size_t`, `uint8_t`.
    public var typeSuffixT = false
    public var callsAreFunctions = true
    /// `name {` is a call with a trailing lambda (Kotlin, Groovy/Gradle DSLs).
    public var blockCallsAreFunctions = false
    public var propertyAfterDot = true

    /// `@Something` annotations/attributes/decorators.
    public var annotationPrefix: UInt16 = 0
    public var annotationKind: TokenKind = .meta
    /// `#if`, `#available` (Swift) — `#` followed by an identifier anywhere.
    public var hashDirectives = false
    /// C preprocessor: a `#` directive at the start of a line.
    public var preprocessor = false
    /// Sigils that introduce variables (`$` PHP/Perl/PowerShell, `@` Ruby ivars).
    public var variablePrefixes: [UInt16] = []
    /// `:symbol` (Ruby, Elixir).
    public var symbolPrefix: UInt16 = 0
    public var regexLiterals = false
    /// Strings directly followed by one of these characters are keys (`"key" = …`).
    public var keyStringsBefore: [UInt16] = []
    public var identBeforeEqualsIsProperty = false
    public var identBeforeColonIsProperty = false
    /// Rust: lifetimes, `macro!` calls and `#[attributes]`.
    public var rust = false
    /// JavaScript/TypeScript JSX tags (heuristic).
    public var jsx = false
    /// PowerShell `-eq`, `-match` operators.
    public var dashOperators = false

    public init() {}
}

// MARK: - Lexer

/// A configurable lexer for most programming languages.
public struct CodeLexer: SyntaxLexer {
    public let spec: CodeSpec
    private let stringStart: [Bool]
    private let lineCommentStart: [Bool]

    enum Mode {
        static let normal: UInt8 = 0
        static let blockComment: UInt8 = 1
        static let string: UInt8 = 2
    }

    public init(_ spec: CodeSpec) {
        var spec = spec
        if spec.caseInsensitive {
            spec.keywords = Set(spec.keywords.map { $0.lowercased() })
            spec.types = Set(spec.types.map { $0.lowercased() })
            spec.constants = Set(spec.constants.map { $0.lowercased() })
            spec.builtins = Set(spec.builtins.map { $0.lowercased() })
        }
        self.spec = spec
        var starts = [Bool](repeating: false, count: 128)
        for s in spec.strings {
            if s.prefixes.isEmpty {
                if let c = s.open.first, c < 128 { starts[Int(c)] = true }
            } else {
                for p in s.prefixes {
                    if let c = (p.first ?? s.open.first), c < 128 {
                        starts[Int(c)] = true
                        starts[Int(Ch.isLower(c) ? c - 32 : c)] = true
                    }
                }
            }
        }
        stringStart = starts
        var commentStarts = [Bool](repeating: false, count: 128)
        for c in spec.lineComments { if let f = c.first, f < 128 { commentStarts[Int(f)] = true } }
        for b in spec.blockComments { if let f = b.open.first, f < 128 { commentStarts[Int(f)] = true } }
        lineCommentStart = commentStarts
    }

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        var i = line.start
        var st = state.main

        if st.mode == Mode.blockComment {
            let index = Int(st.sub)
            guard index < spec.blockComments.count else { state.main = .initial; return }
            var depth = Int(st.depth)
            if let close = scanBlockComment(line, from: i, pair: spec.blockComments[index], depth: &depth) {
                tokens.add(i, close, .comment)
                i = close
                st = .initial
            } else {
                tokens.add(i, line.end, .comment)
                st.depth = UInt16(clamping: depth)
                state.main = st
                return
            }
        } else if st.mode == Mode.string {
            let index = Int(st.sub)
            guard index < spec.strings.count else { state.main = .initial; return }
            if let after = scanString(line, bodyFrom: i, tokenStart: i, spec: spec.strings[index], tokens: &tokens) {
                i = after
                st = .initial
            } else {
                state.main = st
                return
            }
        }

        var context = Context()
        if spec.preprocessor, st.mode == Mode.normal, i == line.start {
            i = lexPreprocessor(line, tokens: &tokens, context: &context)
        }
        lexCode(line, from: i, state: &st, context: &context, tokens: &tokens, nested: false)
        state.main = st
    }

    // MARK: Main loop

    struct Context {
        enum Previous { case start, value, op, keyword }
        enum Declaration { case none, function, type }
        var previous: Previous = .start
        var declaration: Declaration = .none
    }

    /// Lexes `[from, line.end)`. When not `nested`, an unterminated multi-line construct
    /// updates `state` so the next line continues it.
    private func lexCode(_ line: LineBuffer, from start: Int, state: inout LexState,
                         context: inout Context, tokens: inout TokenBuffer, nested: Bool) {
        var i = start
        let end = line.end
        while i < end {
            let c = line[i]

            if Ch.isSpace(c) { i += 1; continue }

            // Comments
            if c < 128, lineCommentStart[Int(c)] {
                if let (index, openEnd) = matchBlockComment(line, at: i) {
                    var depth = 1
                    if let close = scanBlockComment(line, from: openEnd, pair: spec.blockComments[index], depth: &depth) {
                        tokens.add(i, close, .comment)
                        i = close
                        continue
                    }
                    tokens.add(i, end, .comment)
                    if !nested {
                        state = LexState(mode: Mode.blockComment, sub: UInt8(index), depth: UInt16(clamping: depth))
                    }
                    return
                }
                if matchesLineComment(line, at: i) {
                    tokens.add(i, end, .comment)
                    return
                }
            }

            // Rust lifetimes must be recognized before char literals.
            if spec.rust, c == Ch.apostrophe, Ch.isIdentStart(line[i + 1]), line[i + 2] != Ch.apostrophe {
                // Lifetime or label: 'a, 'static
                let j = line.scanIdentifier(i + 1)
                if line[j] != Ch.apostrophe {
                    tokens.add(i, j, .type)
                    i = j
                    continue
                }
            }

            // Strings
            if c < 128, stringStart[Int(c)], let (index, bodyStart) = matchString(line, at: i) {
                let stringSpec = spec.strings[index]
                if let after = scanString(line, bodyFrom: bodyStart, tokenStart: i, spec: stringSpec, tokens: &tokens) {
                    if !spec.keyStringsBefore.isEmpty {
                        let next = line.skipSpaces(after)
                        if spec.keyStringsBefore.contains(line[next]), line[next + 1] != Ch.equals {
                            recolorLast(&tokens, from: i, to: after, as: .property)
                        }
                    }
                    i = after
                    context.previous = .value
                    continue
                }
                if stringSpec.multiline, !nested {
                    state = LexState(mode: Mode.string, sub: UInt8(index))
                }
                return
            }

            // Numbers
            if Ch.isDigit(c) || (c == Ch.dot && Ch.isDigit(line[i + 1]) && context.previous != .value) {
                let j = line.scanNumber(i)
                tokens.add(i, j, .number)
                i = j
                context.previous = .value
                continue
            }

            // Annotations, directives and sigils
            if spec.annotationPrefix != 0, c == spec.annotationPrefix, Ch.isIdentStart(line[i + 1]) {
                let j = line.scanIdentifier(i + 1, extra: Ch.dot)
                tokens.add(i, j, spec.annotationKind)
                i = j
                context.previous = .op
                continue
            }
            if spec.hashDirectives, c == Ch.hash, Ch.isIdentStart(line[i + 1]) {
                let j = line.scanIdentifier(i + 1)
                tokens.add(i, j, .meta)
                i = j
                context.previous = .keyword
                continue
            }
            if spec.rust, c == Ch.hash, line[i + 1] == Ch.lbracket || (line[i + 1] == Ch.bang && line[i + 2] == Ch.lbracket) {
                let close = matchingBracket(line, from: line.find(Ch.lbracket, from: i) ?? i, open: Ch.lbracket, close: Ch.rbracket) ?? (end - 1)
                tokens.add(i, close + 1, .meta)
                i = close + 1
                continue
            }
            if !spec.variablePrefixes.isEmpty, spec.variablePrefixes.contains(c) {
                let n = line[i + 1]
                if Ch.isIdentStart(n) || (c == Ch.at && n == Ch.at && Ch.isIdentStart(line[i + 2])) {
                    var j = i + 1
                    if line[j] == Ch.at { j += 1 }
                    j = line.scanIdentifier(j)
                    // PowerShell scopes: $env:PATH
                    if spec.dashOperators, line[j] == Ch.colon, Ch.isIdentStart(line[j + 1]) { j = line.scanIdentifier(j + 1) }
                    tokens.add(i, j, .variable)
                    i = j
                    context.previous = .value
                    continue
                }
                if c == Ch.dollar, n == Ch.lbrace, let close = matchingBracket(line, from: i + 1, open: Ch.lbrace, close: Ch.rbrace) {
                    tokens.add(i, close + 1, .variable)
                    i = close + 1
                    context.previous = .value
                    continue
                }
            }
            if spec.symbolPrefix != 0, c == spec.symbolPrefix, Ch.isIdentStart(line[i + 1]), line[i - 1] != spec.symbolPrefix, !Ch.isIdentChar(line[i - 1]) {
                let j = line.scanIdentifier(i + 1, extra: spec.identExtra, extra2: spec.identExtra2)
                tokens.add(i, j, .constant)
                i = j
                context.previous = .value
                continue
            }
            if spec.dashOperators, c == Ch.minus, Ch.isAlpha(line[i + 1]), !Ch.isIdentChar(line[i - 1]) {
                let j = line.scanIdentifier(i + 1)
                tokens.add(i, j, .keyword)
                i = j
                context.previous = .op
                continue
            }

            // Identifiers
            if Ch.isIdentStart(c) || (spec.identExtra != 0 && c == spec.identExtra && c != Ch.minus) {
                let j = line.scanIdentifier(i, extra: spec.identExtra, extra2: spec.identExtra2)
                let kind = classify(line, i, j, context: &context)
                tokens.add(i, j, kind)
                i = j
                continue
            }

            // Regex literals
            if spec.regexLiterals, c == Ch.slash, context.previous != .value, line[i + 1] != Ch.slash, line[i + 1] != Ch.star,
               let j = scanRegex(line, from: i) {
                tokens.add(i, j, .regex)
                i = j
                context.previous = .value
                continue
            }

            // JSX tags
            if spec.jsx, c == Ch.lt, context.previous != .value,
               Ch.isIdentStart(line[i + 1]) || line[i + 1] == Ch.slash || line[i + 1] == Ch.gt {
                i = lexJSXTag(line, from: i, tokens: &tokens)
                context.previous = .op
                continue
            }

            // Operators and punctuation
            if Ch.isOperator(c) {
                var j = i + 1
                while j < end, Ch.isOperator(line[j]), !(line[j] == Ch.slash && (line[j + 1] == Ch.slash || line[j + 1] == Ch.star)) { j += 1 }
                tokens.add(i, j, .operator)
                i = j
                context.previous = .op
                if context.declaration != .none { context.declaration = .none }
                continue
            }
            if Ch.isPunctuation(c) || c == Ch.colon {
                tokens.add(i, i + 1, .punctuation)
                context.previous = (c == Ch.rparen || c == Ch.rbracket || c == Ch.rbrace) ? .value : .op
                if c == Ch.lparen || c == Ch.lbrace || c == Ch.semicolon { context.declaration = .none }
                i += 1
                continue
            }
            i += 1
        }
    }

    // MARK: Identifiers

    private func classify(_ line: LineBuffer, _ s: Int, _ e: Int, context: inout Context) -> TokenKind {
        let word = spec.caseInsensitive ? line.lowercasedString(s, e) : line.string(s, e)

        if spec.keywords.contains(word) {
            if spec.functionDeclarations.contains(word) {
                context.declaration = .function
            } else if spec.typeDeclarations.contains(word) {
                context.declaration = .type
            }
            context.previous = .keyword
            return .keyword
        }
        context.previous = .value

        switch context.declaration {
        case .function:
            if line[e] == Ch.dot { return .type } // extension receiver: `fun String.trimmed()`
            context.declaration = .none
            return .function
        case .type:
            context.declaration = .none
            return .type
        case .none:
            break
        }

        if spec.constants.contains(word) { return .constant }
        if spec.variables.contains(word) { return .variable }
        if spec.types.contains(word) { return .type }

        let next = line.skipSpaces(e)
        let nextChar = line[next]

        if spec.identBeforeEqualsIsProperty, nextChar == Ch.equals, line[next + 1] != Ch.equals { return .property }
        if spec.identBeforeColonIsProperty, nextChar == Ch.colon, line[next + 1] != Ch.colon { return .property }

        if spec.rust, nextChar == Ch.bang, line[next + 1] != Ch.equals { return .function }

        let afterDot = line[s - 1] == Ch.dot && line[s - 2] != Ch.dot
        if afterDot, spec.propertyAfterDot {
            if nextChar == Ch.lparen || (spec.blockCallsAreFunctions && nextChar == Ch.lbrace) { return .function }
            return .property
        }

        let first = line[s]
        if spec.allCapsConstants, e - s > 1, Ch.isUpper(first), isAllCaps(line, s, e) { return .constant }
        if spec.capitalizedTypes, Ch.isUpper(first) { return .type }
        if spec.typeSuffixT, e - s > 2, line[e - 2] == Ch.underscore, line[e - 1] == 0x74 /* t */ { return .type }
        if spec.dashOperators, line.find(Ch.minus, from: s).map({ $0 < e }) == true { return .function }

        if spec.callsAreFunctions, nextChar == Ch.lparen { return .function }
        if spec.blockCallsAreFunctions, nextChar == Ch.lbrace { return .function }
        if spec.builtins.contains(word) { return .function }
        return .plain
    }

    private func isAllCaps(_ line: LineBuffer, _ s: Int, _ e: Int) -> Bool {
        var sawLetter = false
        for k in s..<e {
            let c = line[k]
            if Ch.isLower(c) { return false }
            if Ch.isUpper(c) { sawLetter = true }
        }
        return sawLetter
    }

    // MARK: Comments

    private func matchBlockComment(_ line: LineBuffer, at i: Int) -> (Int, Int)? {
        for (index, pair) in spec.blockComments.enumerated() where line.matches(pair.open, at: i) {
            return (index, i + pair.open.count)
        }
        return nil
    }

    private func matchesLineComment(_ line: LineBuffer, at i: Int) -> Bool {
        for marker in spec.lineComments where line.matches(marker, at: i) {
            // `#` in shells/Python only starts a comment at a word boundary; `$#` is not a comment.
            if marker.count == 1, marker[0] == Ch.hash, i > line.start, line[i - 1] == Ch.dollar { return false }
            return true
        }
        return false
    }

    /// Scans to the end of a block comment, honoring nesting. Returns the index after the close marker.
    private func scanBlockComment(_ line: LineBuffer, from start: Int, pair: (open: [UInt16], close: [UInt16]), depth: inout Int) -> Int? {
        var j = start
        while j < line.end {
            if spec.nestedComments, line.matches(pair.open, at: j) {
                depth += 1
                j += pair.open.count
                continue
            }
            if line.matches(pair.close, at: j) {
                depth -= 1
                j += pair.close.count
                if depth <= 0 { return j }
                continue
            }
            j += 1
        }
        return nil
    }

    private func lexPreprocessor(_ line: LineBuffer, tokens: inout TokenBuffer, context: inout Context) -> Int {
        let first = line.firstNonSpace
        guard line[first] == Ch.hash else { return line.start }
        let wordStart = line.skipSpaces(first + 1)
        let wordEnd = line.scanIdentifier(wordStart)
        tokens.add(first, wordEnd, .meta)
        let directive = line.string(wordStart, wordEnd)
        var i = wordEnd
        if directive == "include" || directive == "import" {
            let s = line.skipSpaces(i)
            if line[s] == Ch.lt, let close = line.find(Ch.gt, from: s + 1) {
                tokens.add(s, close + 1, .string)
                i = close + 1
            }
        } else if directive == "define" {
            let s = line.skipSpaces(i)
            let e = line.scanIdentifier(s)
            tokens.add(s, e, .constant)
            i = e
        } else if directive == "pragma" {
            // `#pragma mark - Section` reads better as a single directive.
            tokens.add(first, line.end, .meta)
            return line.end
        }
        context.previous = .op
        return i
    }

    // MARK: Strings

    private func matchString(_ line: LineBuffer, at i: Int) -> (Int, Int)? {
        for (index, s) in spec.strings.enumerated() {
            if s.prefixes.isEmpty {
                if line.matches(s.open, at: i) { return (index, i + s.open.count) }
            } else {
                for p in s.prefixes where line.matchesIgnoringCase(p, at: i) && line.matches(s.open, at: i + p.count) {
                    return (index, i + p.count + s.open.count)
                }
            }
        }
        return nil
    }

    /// Scans a string body. Emits string/escape/interpolation tokens starting at `tokenStart`.
    /// Returns the index after the closing delimiter, or nil when the line ends first.
    private func scanString(_ line: LineBuffer, bodyFrom start: Int, tokenStart: Int, spec s: StringSpec, tokens: inout TokenBuffer) -> Int? {
        var segment = tokenStart
        var j = start
        let end = line.end
        while j < end {
            let c = line[j]
            if s.escape != 0, c == s.escape {
                let escEnd = escapeEnd(line, at: j)
                tokens.add(segment, j, s.kind)
                // Swift interpolation `\( … )`
                if s.interpolation == .backslashParen, line[j + 1] == Ch.lparen,
                   let close = matchingBracket(line, from: j + 1, open: Ch.lparen, close: Ch.rparen) {
                    tokens.add(j, j + 2, .escape)
                    lexInterpolation(line, j + 2, close, tokens: &tokens)
                    tokens.add(close, close + 1, .escape)
                    j = close + 1
                    segment = j
                    continue
                }
                tokens.add(j, escEnd, .escape)
                j = escEnd
                segment = j
                continue
            }
            if line.matches(s.close, at: j) {
                if s.doubledCloseEscapes, line.matches(s.close, at: j + s.close.count) {
                    j += s.close.count * 2
                    continue
                }
                tokens.add(segment, j + s.close.count, s.kind)
                return j + s.close.count
            }
            switch s.interpolation {
            case .dollarBrace, .dollarNameAndBrace:
                if c == Ch.dollar, line[j + 1] == Ch.lbrace, let close = matchingBracket(line, from: j + 1, open: Ch.lbrace, close: Ch.rbrace) {
                    tokens.add(segment, j, s.kind)
                    tokens.add(j, j + 2, .escape)
                    lexInterpolation(line, j + 2, close, tokens: &tokens)
                    tokens.add(close, close + 1, .escape)
                    j = close + 1
                    segment = j
                    continue
                }
                if s.interpolation == .dollarNameAndBrace, c == Ch.dollar, Ch.isIdentStart(line[j + 1]) {
                    tokens.add(segment, j, s.kind)
                    let e = line.scanIdentifier(j + 1)
                    tokens.add(j, e, .variable)
                    j = e
                    segment = j
                    continue
                }
            case .hashBrace:
                if c == Ch.hash, line[j + 1] == Ch.lbrace, let close = matchingBracket(line, from: j + 1, open: Ch.lbrace, close: Ch.rbrace) {
                    tokens.add(segment, j, s.kind)
                    tokens.add(j, j + 2, .escape)
                    lexInterpolation(line, j + 2, close, tokens: &tokens)
                    tokens.add(close, close + 1, .escape)
                    j = close + 1
                    segment = j
                    continue
                }
            case .braces:
                if c == Ch.lbrace {
                    if line[j + 1] == Ch.lbrace { j += 2; continue }
                    if let close = matchingBracket(line, from: j, open: Ch.lbrace, close: Ch.rbrace) {
                        tokens.add(segment, j, s.kind)
                        tokens.add(j, j + 1, .escape)
                        lexInterpolation(line, j + 1, close, tokens: &tokens)
                        tokens.add(close, close + 1, .escape)
                        j = close + 1
                        segment = j
                        continue
                    }
                }
            case .backslashParen, .none:
                break
            }
            j += 1
        }
        // Unterminated on this line.
        tokens.add(segment, end, s.kind)
        return s.multiline ? nil : end
    }

    private func lexInterpolation(_ line: LineBuffer, _ s: Int, _ e: Int, tokens: inout TokenBuffer) {
        guard e > s else { return }
        var scratch = LexState.initial
        var context = Context()
        lexCode(line.slice(s, e), from: s, state: &scratch, context: &context, tokens: &tokens, nested: true)
    }

    private func escapeEnd(_ line: LineBuffer, at j: Int) -> Int {
        let n = line[j + 1]
        if n == 0 { return j + 1 }
        if n == 0x75 /* u */ || n == 0x55 /* U */ {
            if line[j + 2] == Ch.lbrace, let close = line.find(Ch.rbrace, from: j + 3), close - j < 14 { return close + 1 }
            var k = j + 2
            let limit = n == 0x55 ? 8 : 4
            while k < j + 2 + limit, Ch.isHexDigit(line[k]) { k += 1 }
            return k
        }
        if n == Ch.x {
            var k = j + 2
            while k < j + 4, Ch.isHexDigit(line[k]) { k += 1 }
            return k
        }
        return j + 2
    }

    // MARK: Regex & JSX

    private func scanRegex(_ line: LineBuffer, from i: Int) -> Int? {
        var j = i + 1
        var inClass = false
        while j < line.end {
            let c = line[j]
            if c == Ch.backslash { j += 2; continue }
            if c == Ch.lbracket { inClass = true } else if c == Ch.rbracket { inClass = false } else if c == Ch.slash, !inClass {
                j += 1
                while j < line.end, Ch.isAlpha(line[j]) { j += 1 }
                return j
            }
            j += 1
        }
        return nil
    }

    private func lexJSXTag(_ line: LineBuffer, from i: Int, tokens: inout TokenBuffer) -> Int {
        var k = i + 1
        if line[k] == Ch.slash { k += 1 }
        tokens.add(i, k, .punctuation)
        if Ch.isIdentStart(line[k]) {
            let nameEnd = line.scanIdentifier(k, extra: Ch.dot, extra2: Ch.minus)
            tokens.add(k, nameEnd, Ch.isUpper(line[k]) ? .type : .tag)
            k = nameEnd
        }
        while k < line.end {
            k = line.skipSpaces(k)
            let c = line[k]
            if c == Ch.gt {
                tokens.add(k, k + 1, .punctuation)
                return k + 1
            }
            if c == Ch.slash, line[k + 1] == Ch.gt {
                tokens.add(k, k + 2, .punctuation)
                return k + 2
            }
            if Ch.isIdentStart(c) {
                let e = line.scanIdentifier(k, extra: Ch.minus, extra2: Ch.colon)
                tokens.add(k, e, .attribute)
                k = e
                continue
            }
            if c == Ch.equals {
                tokens.add(k, k + 1, .operator)
                k += 1
                continue
            }
            if c == Ch.quote || c == Ch.apostrophe {
                let close = line.find(c, from: k + 1) ?? (line.end - 1)
                tokens.add(k, close + 1, .string)
                k = close + 1
                continue
            }
            if c == Ch.lbrace, let close = matchingBracket(line, from: k, open: Ch.lbrace, close: Ch.rbrace) {
                tokens.add(k, k + 1, .punctuation)
                lexInterpolation(line, k + 1, close, tokens: &tokens)
                tokens.add(close, close + 1, .punctuation)
                k = close + 1
                continue
            }
            break
        }
        return k
    }

    // MARK: Helpers

    /// Index of the bracket closing the one at `from`, on the same line.
    private func matchingBracket(_ line: LineBuffer, from: Int, open: UInt16, close: UInt16) -> Int? {
        var depth = 0
        var j = from
        while j < line.end {
            let c = line[j]
            if c == open { depth += 1 } else if c == close {
                depth -= 1
                if depth == 0 { return j }
            } else if c == Ch.quote || c == Ch.apostrophe, j > from {
                // Skip nested string literals so `${ "}" }` works.
                if let q = line.find(c, from: j + 1) { j = q }
            }
            j += 1
        }
        return nil
    }

    private func recolorLast(_ tokens: inout TokenBuffer, from s: Int, to e: Int, as kind: TokenKind) {
        // Replace the string tokens just emitted for [s, e) with a single key token.
        tokens.removeTokens(from: s)
        tokens.add(s, e, kind)
    }
}
