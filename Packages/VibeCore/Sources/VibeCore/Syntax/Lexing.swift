import Foundation

// MARK: - State

/// Compact, comparable lexer state. Each lexer decides what the fields mean.
/// The engine stores one `LineState` per line (the state at the start of that line) and
/// stops re-lexing after an edit as soon as the state at a line start converges again.
public struct LexState: Hashable, Sendable {
    public var mode: UInt8
    public var sub: UInt8
    public var depth: UInt16
    public var data: Int32

    public init(mode: UInt8 = 0, sub: UInt8 = 0, depth: UInt16 = 0, data: Int32 = 0) {
        self.mode = mode
        self.sub = sub
        self.depth = depth
        self.data = data
    }

    public static let initial = LexState()
}

/// State at a line boundary: the main lexer's state plus (optionally) an embedded
/// language with its own state, used for Markdown code fences and HTML `<script>`/`<style>`.
public struct LineState: Hashable, Sendable {
    public var main: LexState
    public var embedded: LanguageID?
    public var inner: LexState

    public init(main: LexState = .initial, embedded: LanguageID? = nil, inner: LexState = .initial) {
        self.main = main
        self.embedded = embedded
        self.inner = inner
    }
}

// MARK: - Lexer protocol

/// A line-oriented lexer. It receives one line (without its line terminator) plus the
/// state at the start of the line, emits tokens with offsets in `line`'s coordinate space
/// and leaves `state` describing the start of the next line.
public protocol SyntaxLexer: Sendable {
    var initialState: LineState { get }
    func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer)
}

public extension SyntaxLexer {
    var initialState: LineState { LineState() }
}

/// Lexes `line` with another language's lexer, keeping that lexer's state in `inner`.
/// Only one level of embedding is supported; nested embeddings are flattened.
func lexEmbedded(_ language: LanguageID, _ line: LineBuffer, inner: inout LexState, tokens: inout TokenBuffer) {
    let lexer = language.lexer
    var nested = LineState(main: inner)
    lexer.lex(line, state: &nested, tokens: &tokens)
    inner = nested.main
}

/// A lexer that never emits anything.
public struct PlainLexer: SyntaxLexer {
    public init() {}
    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {}
}

// MARK: - Line buffer

/// A read-only window over UTF-16 code units. Indexing outside `[start, end)` returns 0,
/// which lets lexers peek ahead without bounds checks everywhere.
public struct LineBuffer {
    public let base: UnsafePointer<UInt16>
    public let start: Int
    public let end: Int

    public init(base: UnsafePointer<UInt16>, start: Int, end: Int) {
        self.base = base
        self.start = start
        self.end = max(start, end)
    }

    @inline(__always)
    public subscript(i: Int) -> UInt16 {
        (i >= start && i < end) ? base[i] : 0
    }

    public var isEmpty: Bool { start >= end }
    public var length: Int { end - start }

    /// A sub-window, clamped to this buffer.
    public func slice(_ s: Int, _ e: Int) -> LineBuffer {
        let ss = Swift.min(Swift.max(s, start), end)
        let ee = Swift.min(Swift.max(e, ss), end)
        return LineBuffer(base: base, start: ss, end: ee)
    }

    /// Whether `lit` occurs at `i`.
    @inline(__always)
    public func matches(_ lit: [UInt16], at i: Int) -> Bool {
        guard i >= start, i + lit.count <= end else { return false }
        for k in 0..<lit.count where base[i + k] != lit[k] { return false }
        return true
    }

    /// Case-insensitive (ASCII) match; `lit` must be lowercase.
    public func matchesIgnoringCase(_ lit: [UInt16], at i: Int) -> Bool {
        guard i >= start, i + lit.count <= end else { return false }
        for k in 0..<lit.count where Ch.lower(base[i + k]) != lit[k] { return false }
        return true
    }

    public func string(_ s: Int, _ e: Int) -> String {
        let ss = Swift.max(s, start), ee = Swift.min(e, end)
        guard ee > ss else { return "" }
        return String(decoding: UnsafeBufferPointer(start: base + ss, count: ee - ss), as: UTF16.self)
    }

    public func lowercasedString(_ s: Int, _ e: Int) -> String {
        let ss = Swift.max(s, start), ee = Swift.min(e, end)
        guard ee > ss else { return "" }
        var units = [UInt16]()
        units.reserveCapacity(ee - ss)
        for k in ss..<ee { units.append(Ch.lower(base[k])) }
        return String(decoding: units, as: UTF16.self)
    }

    /// First index at or after `i` that is not a space/tab.
    @inline(__always)
    public func skipSpaces(_ i: Int) -> Int {
        var j = Swift.max(i, start)
        while j < end, Ch.isSpace(base[j]) { j += 1 }
        return j
    }

    /// Index of the first non-whitespace character, or `end` for a blank line.
    public var firstNonSpace: Int { skipSpaces(start) }

    /// Index one past the last non-whitespace character (== start for blank lines).
    public var trimmedEnd: Int {
        var j = end
        while j > start, Ch.isSpace(base[j - 1]) { j -= 1 }
        return j
    }

    public func isBlank() -> Bool { firstNonSpace >= end }

    public func find(_ c: UInt16, from i: Int) -> Int? {
        var j = Swift.max(i, start)
        while j < end {
            if base[j] == c { return j }
            j += 1
        }
        return nil
    }

    public func find(_ lit: [UInt16], from i: Int) -> Int? {
        guard let first = lit.first else { return nil }
        var j = Swift.max(i, start)
        while j + lit.count <= end {
            if base[j] == first, matches(lit, at: j) { return j }
            j += 1
        }
        return nil
    }

    /// Scans an identifier `[A-Za-z_][A-Za-z0-9_]*` (plus non-ASCII letters and `extra`).
    @inline(__always)
    public func scanIdentifier(_ i: Int, extra: UInt16 = 0, extra2: UInt16 = 0) -> Int {
        var j = i
        while j < end {
            let c = base[j]
            if Ch.isIdentChar(c) || (c == extra && extra != 0) || (c == extra2 && extra2 != 0) { j += 1 } else { break }
        }
        return j
    }

    /// Scans a run of digits/letters/`_`/`.` that forms a number literal starting at `i`.
    /// Handles hex/binary/octal prefixes, exponents and alphanumeric suffixes.
    public func scanNumber(_ i: Int) -> Int {
        var j = i
        if self[j] == Ch.zero, Ch.lower(self[j + 1]) == Ch.x {
            j += 2
            while j < end, Ch.isHexDigit(base[j]) || base[j] == Ch.underscore { j += 1 }
        } else if self[j] == Ch.zero, Ch.lower(self[j + 1]) == Ch.b || Ch.lower(self[j + 1]) == Ch.o, Ch.isDigit(self[j + 2]) {
            j += 2
            while j < end, Ch.isDigit(base[j]) || base[j] == Ch.underscore { j += 1 }
        } else {
            while j < end, Ch.isDigit(base[j]) || base[j] == Ch.underscore { j += 1 }
            if self[j] == Ch.dot, Ch.isDigit(self[j + 1]) {
                j += 1
                while j < end, Ch.isDigit(base[j]) || base[j] == Ch.underscore { j += 1 }
            }
            if Ch.lower(self[j]) == Ch.e {
                var k = j + 1
                if self[k] == Ch.plus || self[k] == Ch.minus { k += 1 }
                if Ch.isDigit(self[k]) {
                    j = k
                    while j < end, Ch.isDigit(base[j]) { j += 1 }
                }
            }
        }
        // Type suffixes such as 10f, 10L, 10u, 10n, 1_000UL, 3.5px.
        while j < end, Ch.isAlpha(base[j]) { j += 1 }
        return j
    }
}

// MARK: - Character helpers

/// UTF-16 code unit constants and classification helpers.
public enum Ch {
    public static let tab: UInt16 = 0x09
    public static let newline: UInt16 = 0x0A
    public static let cr: UInt16 = 0x0D
    public static let space: UInt16 = 0x20
    public static let bang: UInt16 = 0x21          // !
    public static let quote: UInt16 = 0x22         // "
    public static let hash: UInt16 = 0x23          // #
    public static let dollar: UInt16 = 0x24        // $
    public static let percent: UInt16 = 0x25       // %
    public static let amp: UInt16 = 0x26           // &
    public static let apostrophe: UInt16 = 0x27    // '
    public static let lparen: UInt16 = 0x28        // (
    public static let rparen: UInt16 = 0x29        // )
    public static let star: UInt16 = 0x2A          // *
    public static let plus: UInt16 = 0x2B          // +
    public static let comma: UInt16 = 0x2C         // ,
    public static let minus: UInt16 = 0x2D         // -
    public static let dot: UInt16 = 0x2E           // .
    public static let slash: UInt16 = 0x2F         // /
    public static let zero: UInt16 = 0x30
    public static let nine: UInt16 = 0x39
    public static let colon: UInt16 = 0x3A         // :
    public static let semicolon: UInt16 = 0x3B     // ;
    public static let lt: UInt16 = 0x3C            // <
    public static let equals: UInt16 = 0x3D        // =
    public static let gt: UInt16 = 0x3E            // >
    public static let question: UInt16 = 0x3F      // ?
    public static let at: UInt16 = 0x40            // @
    public static let lbracket: UInt16 = 0x5B      // [
    public static let backslash: UInt16 = 0x5C     // \
    public static let rbracket: UInt16 = 0x5D      // ]
    public static let caret: UInt16 = 0x5E         // ^
    public static let underscore: UInt16 = 0x5F    // _
    public static let backtick: UInt16 = 0x60      // `
    public static let lbrace: UInt16 = 0x7B        // {
    public static let pipe: UInt16 = 0x7C          // |
    public static let rbrace: UInt16 = 0x7D        // }
    public static let tilde: UInt16 = 0x7E         // ~
    public static let b: UInt16 = 0x62
    public static let e: UInt16 = 0x65
    public static let o: UInt16 = 0x6F
    public static let x: UInt16 = 0x78

    @inline(__always) public static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    @inline(__always) public static func isAlpha(_ c: UInt16) -> Bool { let l = c | 0x20; return l >= 0x61 && l <= 0x7A }
    @inline(__always) public static func isUpper(_ c: UInt16) -> Bool { c >= 0x41 && c <= 0x5A }
    @inline(__always) public static func isLower(_ c: UInt16) -> Bool { c >= 0x61 && c <= 0x7A }
    @inline(__always) public static func isAlnum(_ c: UInt16) -> Bool { isAlpha(c) || isDigit(c) }
    @inline(__always) public static func isHexDigit(_ c: UInt16) -> Bool { isDigit(c) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x66) }
    @inline(__always) public static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0C || c == 0x0B || c == 0xA0 || c == 0xFEFF }
    /// Letters, `_`, and any non-ASCII code unit (treated as an identifier character).
    @inline(__always) public static func isIdentStart(_ c: UInt16) -> Bool { isAlpha(c) || c == 0x5F || (c >= 0xC0 && !isSpace(c)) }
    @inline(__always) public static func isIdentChar(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
    @inline(__always) public static func lower(_ c: UInt16) -> UInt16 { (c >= 0x41 && c <= 0x5A) ? c | 0x20 : c }
    /// Characters usually rendered as operators in C-like languages.
    @inline(__always) public static func isOperator(_ c: UInt16) -> Bool {
        switch c {
        case 0x21, 0x25, 0x26, 0x2A, 0x2B, 0x2D, 0x2F, 0x3C, 0x3D, 0x3E, 0x3F, 0x5E, 0x7C, 0x7E: return true
        default: return false
        }
    }
    @inline(__always) public static func isPunctuation(_ c: UInt16) -> Bool {
        switch c {
        case 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x2C, 0x3B, 0x2E: return true
        default: return false
        }
    }
}

/// Converts a literal to UTF-16 code units.
@inline(__always)
public func u16(_ s: String) -> [UInt16] { Array(s.utf16) }
