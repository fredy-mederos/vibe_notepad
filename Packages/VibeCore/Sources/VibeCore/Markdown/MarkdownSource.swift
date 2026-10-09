import Foundation

// MARK: - Limits

/// Hard limits that keep the renderer linear-time and stack-safe on pathological input.
enum MDLimits {
    /// Maximum number of simultaneously open blocks (document, quotes, lists, items, footnotes).
    static let maxBlockDepth = 64
    /// Maximum number of simultaneously open `[` / `![` link openers in one inline run.
    static let maxBracketDepth = 64
    /// Maximum nesting of unescaped parentheses inside a raw link destination.
    static let maxLinkParenDepth = 32
    /// Maximum length of a link label (CommonMark: 999 characters).
    static let maxLabelLength = 999
    /// Longest backtick string that can open a code span.
    static let maxBacktickRun = 1000
}

// MARK: - Bytes

/// ASCII byte constants used by the scanners.
enum MDByte {
    static let tab: UInt8 = 0x09
    static let newline: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let bang: UInt8 = 0x21
    static let quote: UInt8 = 0x22
    static let hash: UInt8 = 0x23
    static let percent: UInt8 = 0x25
    static let ampersand: UInt8 = 0x26
    static let apostrophe: UInt8 = 0x27
    static let leftParen: UInt8 = 0x28
    static let rightParen: UInt8 = 0x29
    static let asterisk: UInt8 = 0x2A
    static let plus: UInt8 = 0x2B
    static let comma: UInt8 = 0x2C
    static let minus: UInt8 = 0x2D
    static let dot: UInt8 = 0x2E
    static let slash: UInt8 = 0x2F
    static let colon: UInt8 = 0x3A
    static let semicolon: UInt8 = 0x3B
    static let lessThan: UInt8 = 0x3C
    static let equals: UInt8 = 0x3D
    static let greaterThan: UInt8 = 0x3E
    static let question: UInt8 = 0x3F
    static let at: UInt8 = 0x40
    static let leftBracket: UInt8 = 0x5B
    static let backslash: UInt8 = 0x5C
    static let rightBracket: UInt8 = 0x5D
    static let caret: UInt8 = 0x5E
    static let underscore: UInt8 = 0x5F
    static let backtick: UInt8 = 0x60
    static let pipe: UInt8 = 0x7C
    static let tilde: UInt8 = 0x7E
}

/// Byte classification helpers (ASCII only; non-ASCII bytes are "other").
enum MDChar {
    @inline(__always) static func isSpaceOrTab(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }

    /// Space, tab, LF, VT, FF, CR.
    @inline(__always) static func isWhitespace(_ c: UInt8) -> Bool {
        c == 0x20 || (c >= 0x09 && c <= 0x0D)
    }

    @inline(__always) static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    @inline(__always) static func isHexDigit(_ c: UInt8) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }

    @inline(__always) static func isLetter(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    @inline(__always) static func isAlphanumeric(_ c: UInt8) -> Bool { isLetter(c) || isDigit(c) }

    /// ASCII punctuation as defined by CommonMark (the characters that can be backslash-escaped).
    @inline(__always) static func isPunctuation(_ c: UInt8) -> Bool {
        (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
    }

    @inline(__always) static func lowercased(_ c: UInt8) -> UInt8 {
        (c >= 0x41 && c <= 0x5A) ? c + 32 : c
    }

    static func hexValue(_ c: UInt8) -> UInt32 {
        switch c {
        case 0x30...0x39: return UInt32(c - 0x30)
        case 0x41...0x46: return UInt32(c - 0x41 + 10)
        case 0x61...0x66: return UInt32(c - 0x61 + 10)
        default: return 0
        }
    }

    /// Case-insensitive comparison of `bytes[at...]` with a lowercase ASCII `literal`.
    static func matchesLowercase(_ bytes: [UInt8], _ at: Int, _ end: Int, _ literal: StaticString) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard at >= 0, at + count <= end else { return false }
        return literal.withUTF8Buffer { lit in
            for k in 0..<count where lowercased(bytes[at + k]) != lit[k] {
                return false
            }
            return true
        }
    }

    /// Exact comparison of `bytes[at...]` with an ASCII `literal`.
    static func matches(_ bytes: [UInt8], _ at: Int, _ end: Int, _ literal: StaticString) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard at >= 0, at + count <= end else { return false }
        return literal.withUTF8Buffer { lit in
            for k in 0..<count where bytes[at + k] != lit[k] {
                return false
            }
            return true
        }
    }
}

// MARK: - Unicode classification

/// Character classes used by the emphasis flanking rules.
enum MDCharClass {
    case whitespace
    case punctuation
    case other
}

enum MDUnicode {
    /// Decodes the scalar starting at `i` (which must be < `end`). Returns nil for malformed sequences.
    static func scalar(at i: Int, in s: [UInt8], end: Int) -> Unicode.Scalar? {
        let b0 = s[i]
        if b0 < 0x80 { return Unicode.Scalar(b0) }
        var length = 0
        var value: UInt32 = 0
        if b0 & 0xE0 == 0xC0 {
            length = 2; value = UInt32(b0 & 0x1F)
        } else if b0 & 0xF0 == 0xE0 {
            length = 3; value = UInt32(b0 & 0x0F)
        } else if b0 & 0xF8 == 0xF0 {
            length = 4; value = UInt32(b0 & 0x07)
        } else {
            return nil
        }
        guard i + length <= end else { return nil }
        for k in 1..<length {
            let b = s[i + k]
            guard b & 0xC0 == 0x80 else { return nil }
            value = (value << 6) | UInt32(b & 0x3F)
        }
        return Unicode.Scalar(value)
    }

    /// Decodes the scalar that ends right before `i` (not looking before `lo`).
    static func scalar(before i: Int, in s: [UInt8], lo: Int) -> Unicode.Scalar? {
        var j = i - 1
        guard j >= lo else { return nil }
        if s[j] < 0x80 { return Unicode.Scalar(s[j]) }
        var steps = 0
        while j > lo && s[j] & 0xC0 == 0x80 && steps < 3 {
            j -= 1
            steps += 1
        }
        return scalar(at: j, in: s, end: i)
    }

    static func classify(_ scalar: Unicode.Scalar?) -> MDCharClass {
        guard let scalar else { return .whitespace }
        if scalar.value < 0x80 {
            let c = UInt8(scalar.value)
            if MDChar.isWhitespace(c) { return .whitespace }
            return MDChar.isPunctuation(c) ? .punctuation : .other
        }
        switch scalar.properties.generalCategory {
        case .spaceSeparator:
            return .whitespace
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return .punctuation
        default:
            return .other
        }
    }

    /// Class of the character before `i` (start of input counts as whitespace).
    static func classBefore(_ i: Int, in s: [UInt8], lo: Int) -> MDCharClass {
        guard i > lo else { return .whitespace }
        let c = s[i - 1]
        if c < 0x80 {
            if MDChar.isWhitespace(c) { return .whitespace }
            return MDChar.isPunctuation(c) ? .punctuation : .other
        }
        return classify(scalar(before: i, in: s, lo: lo))
    }

    /// Class of the character at `i` (end of input counts as whitespace).
    static func classAt(_ i: Int, in s: [UInt8], end: Int) -> MDCharClass {
        guard i < end else { return .whitespace }
        let c = s[i]
        if c < 0x80 {
            if MDChar.isWhitespace(c) { return .whitespace }
            return MDChar.isPunctuation(c) ? .punctuation : .other
        }
        return classify(scalar(at: i, in: s, end: end))
    }
}

// MARK: - Source

/// The document as UTF-8 bytes plus the byte range of every line (line terminators excluded).
struct MDSource {
    let bytes: [UInt8]
    let lineStarts: [Int]
    let lineEnds: [Int]

    var lineCount: Int { lineStarts.count }

    init(_ text: String) {
        var bytes = Array(text.utf8)
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }
        if bytes.contains(0) {
            // CommonMark: U+0000 is replaced by U+FFFD.
            var cleaned: [UInt8] = []
            cleaned.reserveCapacity(bytes.count + 16)
            for b in bytes {
                if b == 0 {
                    cleaned.append(contentsOf: [0xEF, 0xBF, 0xBD])
                } else {
                    cleaned.append(b)
                }
            }
            bytes = cleaned
        }
        var starts: [Int] = []
        var ends: [Int] = []
        starts.reserveCapacity(bytes.count / 40 + 1)
        ends.reserveCapacity(bytes.count / 40 + 1)
        let count = bytes.count
        var i = 0
        var lineStart = 0
        while i < count {
            let b = bytes[i]
            if b == MDByte.newline {
                starts.append(lineStart)
                ends.append(i)
                i += 1
                lineStart = i
            } else if b == MDByte.carriageReturn {
                starts.append(lineStart)
                ends.append(i)
                i += 1
                if i < count && bytes[i] == MDByte.newline { i += 1 }
                lineStart = i
            } else {
                i += 1
            }
        }
        if lineStart < count {
            starts.append(lineStart)
            ends.append(count)
        }
        self.bytes = bytes
        self.lineStarts = starts
        self.lineEnds = ends
    }

    /// True when the line consists only of spaces and tabs.
    func isBlankLine(_ line: Int) -> Bool {
        var i = lineStarts[line]
        let end = lineEnds[line]
        while i < end {
            if !MDChar.isSpaceOrTab(bytes[i]) { return false }
            i += 1
        }
        return true
    }

    /// True when the line equals `literal` after removing trailing spaces/tabs.
    func lineEquals(_ line: Int, _ literal: StaticString) -> Bool {
        let start = lineStarts[line]
        var end = lineEnds[line]
        while end > start && MDChar.isSpaceOrTab(bytes[end - 1]) { end -= 1 }
        return end - start == literal.utf8CodeUnitCount && MDChar.matches(bytes, start, end, literal)
    }
}

/// A piece of a source line assigned to a block: `pad` virtual spaces (from a partially consumed tab)
/// followed by `bytes[start..<end]`.
struct MDLineSlice {
    var start: Int
    var end: Int
    var pad: Int
    var line: Int
}

extension Array where Element == UInt8 {
    /// Appends a line slice (including its virtual padding) from `source`.
    mutating func mdAppend(_ slice: MDLineSlice, from source: [UInt8]) {
        if slice.pad > 0 {
            append(contentsOf: repeatElement(MDByte.space, count: slice.pad))
        }
        if slice.end > slice.start {
            append(contentsOf: source[slice.start..<slice.end])
        }
    }
}
