import Foundation

// MARK: - Link syntax

/// Scanners for link labels, destinations, titles and link reference definitions.
enum MDLinkScan {
    /// Length of a link label `[...]` at `pos` including both brackets, or 0.
    static func label(_ s: [UInt8], _ pos: Int, _ end: Int) -> Int {
        guard pos < end, s[pos] == MDByte.leftBracket else { return 0 }
        var i = pos + 1
        while i < end {
            let c = s[i]
            if c == MDByte.backslash && i + 1 < end {
                i += 2
            } else if c == MDByte.leftBracket {
                return 0
            } else if c == MDByte.rightBracket {
                return i - pos - 1 <= MDLimits.maxLabelLength ? i - pos + 1 : 0
            } else {
                i += 1
            }
            if i - pos - 1 > MDLimits.maxLabelLength { return 0 }
        }
        return 0
    }

    /// Skips spaces/tabs, at most one line ending, then spaces/tabs.
    static func skipSpaceAndNewline(_ s: [UInt8], _ pos: Int, _ end: Int) -> Int {
        var i = pos
        while i < end && MDChar.isSpaceOrTab(s[i]) { i += 1 }
        if i < end && s[i] == MDByte.newline {
            i += 1
            while i < end && MDChar.isSpaceOrTab(s[i]) { i += 1 }
        }
        return i
    }

    /// Link destination at `pos`: `<...>` or a raw destination with balanced parentheses.
    /// Returns the raw content range and the index after the destination.
    static func destination(_ s: [UInt8], _ pos: Int, _ end: Int) -> (content: Range<Int>, next: Int)? {
        if pos < end && s[pos] == MDByte.lessThan {
            var i = pos + 1
            while i < end {
                let c = s[i]
                if c == MDByte.backslash && i + 1 < end && MDChar.isPunctuation(s[i + 1]) {
                    i += 2
                    continue
                }
                if c == MDByte.greaterThan { return ((pos + 1)..<i, i + 1) }
                if c == MDByte.lessThan || c == MDByte.newline { return nil }
                i += 1
            }
            return nil
        }
        var i = pos
        var depth = 0
        while i < end {
            let c = s[i]
            if c == MDByte.backslash && i + 1 < end && MDChar.isPunctuation(s[i + 1]) {
                i += 2
                continue
            }
            if c == MDByte.leftParen {
                depth += 1
                if depth > MDLimits.maxLinkParenDepth { return nil }
            } else if c == MDByte.rightParen {
                if depth == 0 { break }
                depth -= 1
            } else if c <= 0x20 || c == 0x7F {
                break
            }
            i += 1
        }
        guard depth == 0 else { return nil }
        if i == pos && (i >= end || s[i] != MDByte.rightParen) { return nil }
        return (pos..<i, i)
    }

    /// Link title at `pos` in `"..."`, `'...'` or `(...)`. Returns the raw content range and the index after it.
    static func title(_ s: [UInt8], _ pos: Int, _ end: Int) -> (content: Range<Int>, next: Int)? {
        guard pos < end else { return nil }
        let open = s[pos]
        let close: UInt8
        switch open {
        case MDByte.quote: close = MDByte.quote
        case MDByte.apostrophe: close = MDByte.apostrophe
        case MDByte.leftParen: close = MDByte.rightParen
        default: return nil
        }
        var i = pos + 1
        while i < end {
            let c = s[i]
            if c == MDByte.backslash && i + 1 < end && MDChar.isPunctuation(s[i + 1]) {
                i += 2
                continue
            }
            if c == close { return ((pos + 1)..<i, i + 1) }
            if open == MDByte.leftParen && c == MDByte.leftParen { return nil }
            i += 1
        }
        return nil
    }

    /// Normalized reference label: trimmed, internal whitespace collapsed, case-folded. Empty if blank.
    static func normalizeLabel(_ s: [UInt8], _ lo: Int, _ hi: Int) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hi - lo)
        var pendingSpace = false
        var i = lo
        while i < hi {
            let c = s[i]
            if MDChar.isWhitespace(c) {
                pendingSpace = !bytes.isEmpty
            } else {
                if pendingSpace {
                    bytes.append(MDByte.space)
                    pendingSpace = false
                }
                bytes.append(c)
            }
            i += 1
        }
        let text = String(decoding: bytes, as: UTF8.self)
        if bytes.allSatisfy({ $0 < 0x80 }) {
            return text.lowercased()
        }
        return text.lowercased().uppercased().lowercased()
    }

    /// Parses one link reference definition at `pos` (which must be `[`).
    /// Returns the normalized label, the reference and the index after the definition (past its line end).
    static func referenceDefinition(_ s: [UInt8], _ pos: Int, _ end: Int) -> (label: String, reference: MDLinkReference, next: Int)? {
        let labelLength = label(s, pos, end)
        guard labelLength > 2 else { return nil }
        let labelRange = (pos + 1)..<(pos + labelLength - 1)
        if s[labelRange.lowerBound] == MDByte.caret { return nil } // footnote syntax
        var i = pos + labelLength
        guard i < end, s[i] == MDByte.colon else { return nil }
        i = skipSpaceAndNewline(s, i + 1, end)
        guard let dest = destination(s, i, end) else { return nil }
        // A raw destination must not be empty (`<>` is fine).
        if dest.content.isEmpty && s[i] != MDByte.lessThan { return nil }
        let beforeTitle = dest.next
        var titleRange: Range<Int>?
        var after = beforeTitle
        let titleStart = skipSpaceAndNewline(s, beforeTitle, end)
        if titleStart != beforeTitle, let t = title(s, titleStart, end) {
            titleRange = t.content
            after = t.next
        }
        if let lineEnd = restOfLineIsBlank(s, after, end) {
            after = lineEnd
        } else if titleRange != nil, let lineEnd = restOfLineIsBlank(s, beforeTitle, end) {
            titleRange = nil
            after = lineEnd
        } else {
            return nil
        }
        let normalized = normalizeLabel(s, labelRange.lowerBound, labelRange.upperBound)
        guard !normalized.isEmpty else { return nil }
        let rawDestination = MDText.unescape(s, dest.content.lowerBound, dest.content.upperBound)
        let reference = MDLinkReference(
            destination: MDURL.sanitize(MDURL.normalize(rawDestination)),
            title: titleRange.map { MDText.unescape(s, $0.lowerBound, $0.upperBound) }
        )
        return (normalized, reference, after)
    }

    /// If only spaces/tabs remain before the next line ending (or the end), returns the index after that line ending.
    private static func restOfLineIsBlank(_ s: [UInt8], _ pos: Int, _ end: Int) -> Int? {
        var i = pos
        while i < end && MDChar.isSpaceOrTab(s[i]) { i += 1 }
        if i == end { return end }
        if s[i] == MDByte.newline { return i + 1 }
        return nil
    }
}

// MARK: - URLs

/// URL normalization (percent-encoding) and sanitization of dangerous schemes.
enum MDURL {
    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    /// Characters that are kept verbatim (besides ASCII alphanumerics), as in markdown-it/commonmark.js.
    @inline(__always) private static func isSafe(_ c: UInt8) -> Bool {
        if MDChar.isAlphanumeric(c) { return true }
        switch c {
        case 0x3B, 0x2F, 0x3F, 0x3A, 0x40, 0x26, 0x3D, 0x2B, 0x24, 0x2C, // ; / ? : @ & = + $ ,
             0x2D, 0x5F, 0x2E, 0x21, 0x7E, 0x2A, 0x27, 0x28, 0x29, 0x23: // - _ . ! ~ * ' ( ) #
            return true
        default:
            return false
        }
    }

    /// Percent-encodes everything except safe characters and existing `%XX` escapes.
    static func normalize(_ url: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(url.count + 8)
        var i = 0
        let n = url.count
        while i < n {
            let c = url[i]
            if isSafe(c) {
                out.append(c)
            } else if c == MDByte.percent && i + 2 < n && MDChar.isHexDigit(url[i + 1]) && MDChar.isHexDigit(url[i + 2]) {
                out.append(c)
            } else {
                out.append(MDByte.percent)
                out.append(hexDigits[Int(c >> 4)])
                out.append(hexDigits[Int(c & 0x0F)])
            }
            i += 1
        }
        return out
    }

    /// Replaces `javascript:`, `vbscript:` and non-image `data:` URLs with `#`.
    static func sanitize(_ url: [UInt8]) -> [UInt8] {
        if MDChar.matchesLowercase(url, 0, url.count, "javascript:")
            || MDChar.matchesLowercase(url, 0, url.count, "vbscript:")
            || (MDChar.matchesLowercase(url, 0, url.count, "data:")
                && !MDChar.matchesLowercase(url, 0, url.count, "data:image/")) {
            return [MDByte.hash]
        }
        return url
    }
}
