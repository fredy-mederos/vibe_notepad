import Foundation

/// Stateless scanners for block-level syntax. All functions look at `s[from..<end]` only, where
/// `from` is usually the first non-space byte of the (container-stripped) line.
enum MDBlockScan {
    // MARK: Thematic breaks and headings

    /// `***`, `---`, `___` (three or more, optional spaces/tabs in between).
    static func isThematicBreak(_ s: [UInt8], _ from: Int, _ end: Int) -> Bool {
        guard from < end else { return false }
        let marker = s[from]
        guard marker == MDByte.asterisk || marker == MDByte.minus || marker == MDByte.underscore else { return false }
        var count = 0
        var i = from
        while i < end {
            let c = s[i]
            if c == marker {
                count += 1
            } else if !MDChar.isSpaceOrTab(c) {
                return false
            }
            i += 1
        }
        return count >= 3
    }

    /// ATX heading: returns the level and the trimmed content range (closing `#`s removed).
    static func atxHeading(_ s: [UInt8], _ from: Int, _ end: Int) -> (level: Int, start: Int, end: Int)? {
        var i = from
        while i < end && s[i] == MDByte.hash && i - from < 7 { i += 1 }
        let level = i - from
        guard level >= 1 && level <= 6 else { return nil }
        guard i == end || MDChar.isSpaceOrTab(s[i]) else { return nil }
        while i < end && MDChar.isSpaceOrTab(s[i]) { i += 1 }
        let contentStart = i
        var e = end
        while e > contentStart && MDChar.isSpaceOrTab(s[e - 1]) { e -= 1 }
        var h = e
        while h > contentStart && s[h - 1] == MDByte.hash { h -= 1 }
        if h < e {
            if h == contentStart {
                e = contentStart
            } else if MDChar.isSpaceOrTab(s[h - 1]) {
                e = h
                while e > contentStart && MDChar.isSpaceOrTab(s[e - 1]) { e -= 1 }
            }
        }
        return (level, contentStart, e)
    }

    /// Setext underline (`===` → 1, `---` → 2).
    static func setextLevel(_ s: [UInt8], _ from: Int, _ end: Int) -> Int? {
        guard from < end else { return nil }
        let marker = s[from]
        guard marker == MDByte.equals || marker == MDByte.minus else { return nil }
        var i = from
        while i < end && s[i] == marker { i += 1 }
        while i < end && MDChar.isSpaceOrTab(s[i]) { i += 1 }
        guard i == end else { return nil }
        return marker == MDByte.equals ? 1 : 2
    }

    // MARK: Code fences

    /// Opening code fence: three or more backticks or tildes. Backtick fences may not have backticks in the info string.
    static func openingFence(_ s: [UInt8], _ from: Int, _ end: Int) -> (char: UInt8, length: Int)? {
        guard from < end else { return nil }
        let c = s[from]
        guard c == MDByte.backtick || c == MDByte.tilde else { return nil }
        var i = from
        while i < end && s[i] == c { i += 1 }
        let length = i - from
        guard length >= 3 else { return nil }
        if c == MDByte.backtick {
            while i < end {
                if s[i] == MDByte.backtick { return nil }
                i += 1
            }
        }
        return (c, length)
    }

    /// Closing fence of at least `minLength` `char`s followed only by spaces/tabs.
    static func isClosingFence(_ s: [UInt8], _ from: Int, _ end: Int, char: UInt8, minLength: Int) -> Bool {
        var i = from
        while i < end && s[i] == char { i += 1 }
        guard i - from >= minLength else { return false }
        while i < end && MDChar.isSpaceOrTab(s[i]) { i += 1 }
        return i == end
    }

    // MARK: HTML blocks

    private static let type1Tags: [StaticString] = ["script", "pre", "style", "textarea"]

    private static let type6Tags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
        "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
        "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
        "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot",
        "th", "thead", "title", "tr", "track", "ul",
    ]

    /// CommonMark HTML block start condition (1...7) for a line starting with `<` at `from`.
    static func htmlBlockStart(_ s: [UInt8], _ from: Int, _ end: Int) -> Int? {
        guard from < end, s[from] == MDByte.lessThan else { return nil }
        let p = from + 1
        for tag in type1Tags where MDChar.matchesLowercase(s, p, end, tag) {
            let after = p + tag.utf8CodeUnitCount
            if after == end || MDChar.isSpaceOrTab(s[after]) || s[after] == MDByte.greaterThan {
                return 1
            }
        }
        if MDChar.matches(s, p, end, "!--") { return 2 }
        if p < end && s[p] == MDByte.question { return 3 }
        if MDChar.matches(s, p, end, "![CDATA[") { return 5 }
        if p + 1 < end && s[p] == MDByte.bang && MDChar.isLetter(s[p + 1]) { return 4 }

        var q = p
        if q < end && s[q] == MDByte.slash { q += 1 }
        var nameEnd = q
        while nameEnd < end && MDChar.isAlphanumeric(s[nameEnd]) && nameEnd - q <= 10 { nameEnd += 1 }
        if nameEnd > q && MDChar.isLetter(s[q]) {
            let name = String(decoding: s[q..<nameEnd].map(MDChar.lowercased), as: UTF8.self)
            if type6Tags.contains(name) {
                if nameEnd == end || MDChar.isSpaceOrTab(s[nameEnd]) || s[nameEnd] == MDByte.greaterThan
                    || (s[nameEnd] == MDByte.slash && nameEnd + 1 < end && s[nameEnd + 1] == MDByte.greaterThan) {
                    return 6
                }
            }
            // Type 7: a complete open or closing tag alone on the line.
            let isRaw = name == "script" || name == "style" || name == "pre" || name == "textarea"
            if !isRaw {
                let tagEnd = q > p ? MDHTMLScan.closingTag(s, from, end) : MDHTMLScan.openTag(s, from, end)
                if let tagEnd {
                    var i = tagEnd
                    while i < end && MDChar.isSpaceOrTab(s[i]) { i += 1 }
                    if i == end { return 7 }
                }
            }
        }
        return nil
    }

    /// Whether a line satisfies the end condition of an HTML block of `type` 1...5.
    static func htmlBlockEnds(_ type: Int, _ s: [UInt8], _ from: Int, _ end: Int) -> Bool {
        var i = from
        switch type {
        case 1:
            while i + 1 < end {
                if s[i] == MDByte.lessThan && s[i + 1] == MDByte.slash {
                    for tag in type1Tags where MDChar.matchesLowercase(s, i + 2, end, tag) {
                        let close = i + 2 + tag.utf8CodeUnitCount
                        if close < end && s[close] == MDByte.greaterThan { return true }
                    }
                }
                i += 1
            }
            return false
        case 2:
            return contains(s, from, end, "-->")
        case 3:
            return contains(s, from, end, "?>")
        case 4:
            return contains(s, from, end, ">")
        case 5:
            return contains(s, from, end, "]]>")
        default:
            return false
        }
    }

    private static func contains(_ s: [UInt8], _ from: Int, _ end: Int, _ literal: StaticString) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard count > 0, end - from >= count else { return false }
        let first = literal.utf8Start.pointee
        var i = from
        while i + count <= end {
            if s[i] == first && MDChar.matches(s, i, end, literal) { return true }
            i += 1
        }
        return false
    }

    // MARK: Tables

    /// Splits a table row into trimmed cell ranges. Leading/trailing pipes are optional; `\|` does not split
    /// (like cmark-gfm, a pipe preceded by a backslash never splits, even inside code spans).
    static func tableCells(_ s: [UInt8], _ from: Int, _ end: Int) -> [Range<Int>] {
        var lo = from
        var hi = end
        while lo < hi && MDChar.isWhitespace(s[lo]) { lo += 1 }
        while hi > lo && MDChar.isWhitespace(s[hi - 1]) { hi -= 1 }
        if lo < hi && s[lo] == MDByte.pipe { lo += 1 }
        var cells: [Range<Int>] = []
        var cellStart = lo
        var i = lo
        while i < hi {
            let c = s[i]
            if c == MDByte.backslash && i + 1 < hi && s[i + 1] == MDByte.pipe {
                i += 2
                continue
            }
            if c == MDByte.pipe {
                cells.append(trimmed(s, cellStart, i))
                cellStart = i + 1
            }
            i += 1
        }
        if cellStart < hi {
            cells.append(trimmed(s, cellStart, hi))
        }
        return cells
    }

    private static func trimmed(_ s: [UInt8], _ lo: Int, _ hi: Int) -> Range<Int> {
        var a = lo
        var b = hi
        while a < b && MDChar.isWhitespace(s[a]) { a += 1 }
        while b > a && MDChar.isWhitespace(s[b - 1]) { b -= 1 }
        return a..<b
    }

    /// Parses a delimiter row (`| :--- | :-: | --: |`) into column alignments.
    static func tableDelimiterRow(_ s: [UInt8], _ from: Int, _ end: Int) -> [MDAlignment]? {
        // Quick reject: only pipes, dashes, colons and whitespace may appear.
        var i = from
        var sawDash = false
        while i < end {
            let c = s[i]
            if c == MDByte.minus {
                sawDash = true
            } else if c != MDByte.pipe && c != MDByte.colon && !MDChar.isSpaceOrTab(c) {
                return nil
            }
            i += 1
        }
        guard sawDash else { return nil }
        let cells = tableCells(s, from, end)
        guard !cells.isEmpty else { return nil }
        var result: [MDAlignment] = []
        result.reserveCapacity(cells.count)
        for cell in cells {
            var lo = cell.lowerBound
            var hi = cell.upperBound
            guard lo < hi else { return nil }
            let left = s[lo] == MDByte.colon
            if left { lo += 1 }
            let right = hi > lo && s[hi - 1] == MDByte.colon
            if right { hi -= 1 }
            guard lo < hi else { return nil }
            for k in lo..<hi where s[k] != MDByte.minus {
                return nil
            }
            result.append(left && right ? .center : left ? .left : right ? .right : .none)
        }
        return result
    }

    /// Whether `s[from..<end]` contains an unescaped pipe.
    static func containsPipe(_ s: [UInt8], _ from: Int, _ end: Int) -> Bool {
        var i = from
        while i < end {
            if s[i] == MDByte.pipe && (i == from || s[i - 1] != MDByte.backslash) { return true }
            i += 1
        }
        return false
    }

    // MARK: Footnotes

    /// `[^label]:` at `from`. Returns the label range and the index after the colon.
    static func footnoteDefinition(_ s: [UInt8], _ from: Int, _ end: Int) -> (label: Range<Int>, after: Int)? {
        guard end - from >= 5, s[from] == MDByte.leftBracket, s[from + 1] == MDByte.caret else { return nil }
        var i = from + 2
        while i < end {
            let c = s[i]
            if c == MDByte.rightBracket { break }
            if MDChar.isWhitespace(c) || c == MDByte.leftBracket || c == MDByte.backslash { return nil }
            if i - from > MDLimits.maxLabelLength { return nil }
            i += 1
        }
        guard i < end, i > from + 2, i + 1 < end, s[i + 1] == MDByte.colon else { return nil }
        return ((from + 2)..<i, i + 2)
    }
}
