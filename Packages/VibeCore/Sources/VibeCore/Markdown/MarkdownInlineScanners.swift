import Foundation

// MARK: - Raw HTML

/// Remembers scans that ran to the end of the input without finding a terminator, so repeated
/// unterminated constructs (`<!--`, `<a title="`, …) cost linear instead of quadratic time.
struct MDHTMLScanCache {
    var commentFailFrom = Int.max
    var processingFailFrom = Int.max
    var cdataFailFrom = Int.max
    var declarationFailFrom = Int.max
    var doubleQuoteFailFrom = Int.max
    var singleQuoteFailFrom = Int.max
}

/// Scanners for CommonMark raw HTML and `<...>` autolinks. `pos` always points at `<`.
enum MDHTMLScan {
    /// Inline raw HTML (open/closing tag, comment, processing instruction, declaration, CDATA).
    static func inlineHTML(_ s: [UInt8], _ pos: Int, _ end: Int, cache: inout MDHTMLScanCache) -> Int? {
        let p = pos + 1
        guard p < end else { return nil }
        switch s[p] {
        case MDByte.slash:
            return closingTag(s, pos, end)
        case MDByte.question:
            return scanUntil(s, p + 1, end, "?>", failFrom: &cache.processingFailFrom)
        case MDByte.bang:
            if MDChar.matches(s, p, end, "!--") {
                let q = p + 3
                if MDChar.matches(s, q, end, ">") { return q + 1 }
                if MDChar.matches(s, q, end, "->") { return q + 2 }
                return scanUntil(s, q, end, "-->", failFrom: &cache.commentFailFrom)
            }
            if MDChar.matches(s, p, end, "![CDATA[") {
                return scanUntil(s, p + 8, end, "]]>", failFrom: &cache.cdataFailFrom)
            }
            if p + 1 < end && MDChar.isLetter(s[p + 1]) {
                return scanUntil(s, p + 2, end, ">", failFrom: &cache.declarationFailFrom)
            }
            return nil
        default:
            return openTag(s, pos, end, cache: &cache)
        }
    }

    /// `<tag attr="value" ...>` or `<tag/>`.
    static func openTag(_ s: [UInt8], _ pos: Int, _ end: Int) -> Int? {
        var cache = MDHTMLScanCache()
        return openTag(s, pos, end, cache: &cache)
    }

    static func openTag(_ s: [UInt8], _ pos: Int, _ end: Int, cache: inout MDHTMLScanCache) -> Int? {
        var i = pos + 1
        guard i < end, MDChar.isLetter(s[i]) else { return nil }
        while i < end && (MDChar.isAlphanumeric(s[i]) || s[i] == MDByte.minus) { i += 1 }
        while true {
            let whitespaceStart = i
            while i < end && MDChar.isWhitespace(s[i]) { i += 1 }
            guard i < end else { return nil }
            let c = s[i]
            if c == MDByte.greaterThan { return i + 1 }
            if c == MDByte.slash {
                return i + 1 < end && s[i + 1] == MDByte.greaterThan ? i + 2 : nil
            }
            guard i > whitespaceStart else { return nil }
            guard MDChar.isLetter(c) || c == MDByte.underscore || c == MDByte.colon else { return nil }
            i += 1
            while i < end && isAttributeNameChar(s[i]) { i += 1 }
            var j = i
            while j < end && MDChar.isWhitespace(s[j]) { j += 1 }
            guard j < end, s[j] == MDByte.equals else { continue }
            j += 1
            while j < end && MDChar.isWhitespace(s[j]) { j += 1 }
            guard j < end else { return nil }
            let quote = s[j]
            if quote == MDByte.quote || quote == MDByte.apostrophe {
                let failFrom = quote == MDByte.quote ? cache.doubleQuoteFailFrom : cache.singleQuoteFailFrom
                guard j < failFrom else { return nil }
                var k = j + 1
                while k < end && s[k] != quote { k += 1 }
                guard k < end else {
                    if quote == MDByte.quote {
                        cache.doubleQuoteFailFrom = min(cache.doubleQuoteFailFrom, j)
                    } else {
                        cache.singleQuoteFailFrom = min(cache.singleQuoteFailFrom, j)
                    }
                    return nil
                }
                i = k + 1
            } else {
                var k = j
                while k < end && isUnquotedValueChar(s[k]) { k += 1 }
                guard k > j else { return nil }
                i = k
            }
        }
    }

    /// `</tag>` with optional whitespace before `>`.
    static func closingTag(_ s: [UInt8], _ pos: Int, _ end: Int) -> Int? {
        var i = pos + 2
        guard i < end, s[pos + 1] == MDByte.slash, MDChar.isLetter(s[i]) else { return nil }
        while i < end && (MDChar.isAlphanumeric(s[i]) || s[i] == MDByte.minus) { i += 1 }
        while i < end && MDChar.isWhitespace(s[i]) { i += 1 }
        guard i < end, s[i] == MDByte.greaterThan else { return nil }
        return i + 1
    }

    @inline(__always) private static func isAttributeNameChar(_ c: UInt8) -> Bool {
        MDChar.isAlphanumeric(c) || c == MDByte.underscore || c == MDByte.dot || c == MDByte.colon || c == MDByte.minus
    }

    @inline(__always) private static func isUnquotedValueChar(_ c: UInt8) -> Bool {
        !(MDChar.isWhitespace(c) || c == MDByte.quote || c == MDByte.apostrophe || c == MDByte.equals
            || c == MDByte.lessThan || c == MDByte.greaterThan || c == MDByte.backtick)
    }

    /// Index after the first occurrence of `terminator` at or after `from`.
    private static func scanUntil(_ s: [UInt8], _ from: Int, _ end: Int, _ terminator: StaticString, failFrom: inout Int) -> Int? {
        guard from < failFrom else { return nil }
        let length = terminator.utf8CodeUnitCount
        let first = terminator.utf8Start.pointee
        var i = from
        while i + length <= end {
            if s[i] == first && MDChar.matches(s, i, end, terminator) { return i + length }
            i += 1
        }
        failFrom = min(failFrom, from)
        return nil
    }

    // MARK: Autolinks

    /// `<scheme:...>` or `<user@example.com>`. Returns the index after `>`.
    static func autolink(_ s: [UInt8], _ pos: Int, _ end: Int) -> (end: Int, isEmail: Bool)? {
        let p = pos + 1
        guard p < end else { return nil }
        if MDChar.isLetter(s[p]) {
            var j = p + 1
            while j < end && j - p <= 32
                && (MDChar.isAlphanumeric(s[j]) || s[j] == MDByte.plus || s[j] == MDByte.dot || s[j] == MDByte.minus) {
                j += 1
            }
            let schemeLength = j - p
            if schemeLength >= 2 && schemeLength <= 32 && j < end && s[j] == MDByte.colon {
                var k = j + 1
                while k < end {
                    let c = s[k]
                    if c == MDByte.greaterThan { return (k + 1, false) }
                    if c <= 0x20 || c == MDByte.lessThan || c == 0x7F { break }
                    k += 1
                }
            }
        }
        // Email (HTML5 "valid e-mail address" grammar).
        var i = p
        while i < end && isEmailLocalChar(s[i]) { i += 1 }
        guard i > p, i < end, s[i] == MDByte.at else { return nil }
        i += 1
        var labelLength = 0
        while i < end {
            let c = s[i]
            if MDChar.isAlphanumeric(c) {
                labelLength += 1
            } else if c == MDByte.minus {
                guard labelLength > 0 else { return nil }
                labelLength += 1
            } else if c == MDByte.dot {
                guard labelLength > 0, s[i - 1] != MDByte.minus else { return nil }
                labelLength = 0
            } else if c == MDByte.greaterThan {
                guard labelLength > 0, s[i - 1] != MDByte.minus else { return nil }
                return (i + 1, true)
            } else {
                return nil
            }
            if labelLength > 63 { return nil }
            i += 1
        }
        return nil
    }

    @inline(__always) private static func isEmailLocalChar(_ c: UInt8) -> Bool {
        if MDChar.isAlphanumeric(c) { return true }
        switch c {
        case 0x2E, 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2F, 0x3D, 0x3F, 0x5E, 0x5F, 0x60, 0x7B, 0x7C, 0x7D, 0x7E, 0x2D:
            return true // . ! # $ % & ' * + / = ? ^ _ ` { | } ~ -
        default:
            return false
        }
    }
}

// MARK: - GFM extended autolinks

/// Bare `www.` / `http(s)://` URLs and email addresses (GFM "extended autolinks").
enum MDAutolink {
    /// Characters after which a URL autolink may start.
    @inline(__always) static func isURLBoundary(_ c: UInt8) -> Bool {
        MDChar.isWhitespace(c) || c == MDByte.asterisk || c == MDByte.underscore || c == MDByte.tilde || c == MDByte.leftParen
    }

    @inline(__always) static func isEmailLocalChar(_ c: UInt8) -> Bool {
        MDChar.isAlphanumeric(c) || c == MDByte.dot || c == MDByte.minus || c == MDByte.underscore || c == MDByte.plus
    }

    /// Matches `www.`, `http://` or `https://` at `pos`. Returns the end of the link and whether it is a `www.` link.
    static func url(_ s: [UInt8], _ pos: Int, _ end: Int) -> (end: Int, isWWW: Bool)? {
        let domainStart: Int
        let isWWW: Bool
        if MDChar.matchesLowercase(s, pos, end, "www.") {
            domainStart = pos
            isWWW = true
        } else if MDChar.matchesLowercase(s, pos, end, "https://") {
            domainStart = pos + 8
            isWWW = false
        } else if MDChar.matchesLowercase(s, pos, end, "http://") {
            domainStart = pos + 7
            isWWW = false
        } else {
            return nil
        }
        var i = domainStart
        while i < end {
            let c = s[i]
            guard MDChar.isAlphanumeric(c) || c == MDByte.minus || c == MDByte.underscore || c == MDByte.dot || c >= 0x80 else { break }
            i += 1
        }
        let domainEnd = i
        while i < end && !MDChar.isWhitespace(s[i]) && s[i] != MDByte.lessThan { i += 1 }
        let linkEnd = trimTrailing(s, pos, i)
        guard isValidDomain(s, domainStart, min(domainEnd, linkEnd), requirePeriod: isWWW) else { return nil }
        return (linkEnd, isWWW)
    }

    /// Matches an email address whose local part starts at `pos`. Returns the end of the address.
    static func email(_ s: [UInt8], _ pos: Int, _ end: Int) -> Int? {
        var i = pos
        while i < end && isEmailLocalChar(s[i]) { i += 1 }
        guard i > pos, i < end, s[i] == MDByte.at else { return nil }
        let domainStart = i + 1
        var j = domainStart
        var periods = 0
        while j < end {
            let c = s[j]
            if MDChar.isAlphanumeric(c) || c == MDByte.minus || c == MDByte.underscore {
                j += 1
            } else if c == MDByte.dot && j > domainStart && s[j - 1] != MDByte.dot
                        && j + 1 < end && (MDChar.isAlphanumeric(s[j + 1]) || s[j + 1] == MDByte.minus || s[j + 1] == MDByte.underscore) {
                periods += 1
                j += 1
            } else {
                break
            }
        }
        guard periods >= 1, j > domainStart else { return nil }
        let last = s[j - 1]
        guard last != MDByte.minus && last != MDByte.underscore else { return nil }
        return j
    }

    /// GFM trailing punctuation rules: drop `?!.,:*_~'"`, unbalanced `)`, and entity-like `&name;` suffixes.
    static func trimTrailing(_ s: [UInt8], _ lo: Int, _ hi: Int) -> Int {
        var opening = 0
        var closing = 0
        for k in lo..<hi {
            if s[k] == MDByte.leftParen {
                opening += 1
            } else if s[k] == MDByte.rightParen {
                closing += 1
            }
        }
        var e = hi
        while e > lo {
            switch s[e - 1] {
            case MDByte.question, MDByte.bang, MDByte.dot, MDByte.comma, MDByte.colon, MDByte.asterisk,
                 MDByte.underscore, MDByte.tilde, MDByte.apostrophe, MDByte.quote:
                e -= 1
            case MDByte.rightParen:
                guard closing > opening else { return e }
                closing -= 1
                e -= 1
            case MDByte.semicolon:
                var k = e - 2
                while k >= lo && MDChar.isAlphanumeric(s[k]) { k -= 1 }
                if k >= lo && k < e - 2 && s[k] == MDByte.ampersand {
                    e = k
                } else {
                    e -= 1
                }
            default:
                return e
            }
        }
        return e
    }

    /// Domain segments of alphanumerics, `-` and `_` separated by `.`; no `_` in the last two segments.
    private static func isValidDomain(_ s: [UInt8], _ lo: Int, _ hi: Int, requirePeriod: Bool) -> Bool {
        guard hi > lo else { return false }
        var periods = 0
        var underscoreInLast = false
        var underscoreInSecondLast = false
        var segmentLength = 0
        for k in lo..<hi {
            let c = s[k]
            if c == MDByte.dot {
                if segmentLength == 0 { return false }
                periods += 1
                underscoreInSecondLast = underscoreInLast
                underscoreInLast = false
                segmentLength = 0
            } else {
                if c == MDByte.underscore { underscoreInLast = true }
                segmentLength += 1
            }
        }
        if underscoreInLast || underscoreInSecondLast { return false }
        guard requirePeriod else { return true }
        // `www.` alone is not a domain: a trailing period does not count.
        return (segmentLength == 0 ? periods - 1 : periods) >= 1
    }
}
