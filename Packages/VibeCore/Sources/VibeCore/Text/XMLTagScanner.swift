import Foundation

/// Walks the markup of XML text (UTF-16 units): tags, comments, CDATA sections and DOCTYPE
/// declarations, skipping text and processing instructions. Tolerant: a `<` that starts nothing is
/// text, and a comment or tag that never ends stops the walk.
struct XMLTagScanner {
    enum Markup {
        case startTag(name: Range<Int>, selfClosing: Bool)
        case endTag(name: Range<Int>)
        case comment
        case cdata
        /// `<!DOCTYPE …>`; `subsetEnd` is the `]` closing its internal subset, if it has one.
        case doctype(subsetEnd: Int?)
    }

    let s: [UInt16]

    init(_ units: [UInt16]) {
        s = units
    }

    init(_ text: NSString) {
        var units = [UInt16](repeating: 0, count: text.length)
        units.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { text.getCharacters(base, range: NSRange(location: 0, length: text.length)) }
        }
        s = units
    }

    /// Calls `visit` with each piece of markup from `start` on, and its range (from `<` to just past
    /// its last character), until `visit` returns false.
    func scan(from start: Int = 0, _ visit: (Markup, Range<Int>) -> Bool) {
        let n = s.count
        var i = start
        while i < n {
            guard s[i] == Ch.lt, i + 1 < n else {
                i += 1
                continue
            }
            let next = s[i + 1]
            let markup: Markup
            let end: Int
            if matches(Self.commentStart, i) {
                guard let close = find(Self.commentEnd, from: i + 4) else { return }
                (markup, end) = (.comment, close + 3)
            } else if matches(Self.cdataStart, i) {
                guard let close = find(Self.cdataEnd, from: i + 9) else { return }
                (markup, end) = (.cdata, close + 3)
            } else if next == Ch.question {
                guard let close = find(Self.instructionEnd, from: i + 2) else { return }
                i = close + 2
                continue
            } else if next == Ch.bang {
                // DOCTYPE: its internal subset (in brackets) holds declarations and comments of its own.
                var j = i + 2, depth = 0, quote: UInt16 = 0
                var subsetEnd: Int?
                while j < n {
                    let c = s[j]
                    if quote != 0 {
                        if c == quote { quote = 0 }
                    } else if c == Ch.lt, matches(Self.commentStart, j) {
                        j = (find(Self.commentEnd, from: j + 4) ?? n) + 3
                        continue
                    } else if c == Ch.quote || c == Ch.apostrophe {
                        quote = c
                    } else if c == Ch.lbracket {
                        depth += 1
                    } else if c == Ch.rbracket {
                        depth -= 1
                        if depth == 0 { subsetEnd = j }
                    } else if c == Ch.gt, depth <= 0 {
                        break
                    }
                    j += 1
                }
                guard j < n else { return }
                (markup, end) = (.doctype(subsetEnd: subsetEnd), j + 1)
            } else if next == Ch.slash {
                let name = self.name(at: i + 2)
                var j = name.upperBound
                while j < n, s[j] != Ch.gt { j += 1 }
                guard j < n else { return }
                (markup, end) = (.endTag(name: name), j + 1)
            } else if Ch.isAlpha(next) || next == Ch.underscore || next == Ch.colon || next >= 0x80 {
                let close = tagEnd(from: i + 1)
                guard close < n else { return }
                (markup, end) = (.startTag(name: name(at: i + 1), selfClosing: s[close - 1] == Ch.slash), close + 1)
            } else {
                i += 1
                continue
            }
            guard visit(markup, i..<end) else { return }
            i = end
        }
    }

    /// Whether two names (ranges of the text) are spelled the same.
    func sameName(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        a.count == b.count && !zip(a, b).contains { s[$0] != s[$1] }
    }

    func string(_ range: Range<Int>) -> String {
        String(decoding: s[range], as: UTF16.self)
    }

    /// The name starting at `start`, up to a space, `>` or `/`.
    func name(at start: Int) -> Range<Int> {
        var j = start
        while j < s.count, !isSpace(s[j]), s[j] != Ch.gt, s[j] != Ch.slash { j += 1 }
        return start..<j
    }

    func isSpace(_ c: UInt16) -> Bool {
        c == Ch.space || c == Ch.newline || c == Ch.tab || c == Ch.cr
    }

    /// The `>` ending the tag whose name starts at `start`, skipping quoted attribute values
    /// (the text's length when it never comes).
    private func tagEnd(from start: Int) -> Int {
        var j = start
        var quote: UInt16 = 0
        while j < s.count {
            let c = s[j]
            if quote != 0 {
                if c == quote { quote = 0 }
            } else if c == Ch.quote || c == Ch.apostrophe {
                quote = c
            } else if c == Ch.gt {
                return j
            }
            j += 1
        }
        return s.count
    }

    @inline(__always) private func matches(_ literal: [UInt16], _ at: Int) -> Bool {
        guard at + literal.count <= s.count else { return false }
        for k in 0..<literal.count where s[at + k] != literal[k] { return false }
        return true
    }

    private func find(_ literal: [UInt16], from start: Int) -> Int? {
        var j = start
        while j < s.count {
            if s[j] == literal[0], matches(literal, j) { return j }
            j += 1
        }
        return nil
    }

    private static let commentStart = u16("<!--")
    private static let commentEnd = u16("-->")
    private static let cdataStart = u16("<![CDATA[")
    private static let cdataEnd = u16("]]>")
    private static let instructionEnd = u16("?>")
}
