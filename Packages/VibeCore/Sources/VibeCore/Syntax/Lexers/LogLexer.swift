import Foundation

/// Log files: timestamps, levels, strings, numbers, URLs, identifiers, exception names and stack
/// frames. Stateless: each line stands alone.
public struct LogLexer: SyntaxLexer {
    public init() {}

    private struct Word {
        let upper: [UInt16]
        let lower: [UInt16]
        let kind: TokenKind

        init(_ word: String, _ kind: TokenKind) {
            upper = u16(word)
            lower = u16(word.lowercased())
            self.kind = kind
        }
    }

    private static let levels: [Word] =
        ["ERROR", "ERR", "FATAL", "CRITICAL", "CRIT", "SEVERE", "PANIC", "EMERG", "EMERGENCY", "ALERT"].map { Word($0, .logError) }
        + ["WARN", "WARNING"].map { Word($0, .logWarning) }
        + ["INFO", "NOTICE"].map { Word($0, .logInfo) }
        + ["DEBUG", "TRACE", "VERBOSE", "FINE", "FINER", "FINEST"].map { Word($0, .logDebug) }
    private static let httpMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "CONNECT"].map(u16)
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].map(u16)
    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map(u16)
    private static let levelKeys = ["level", "lvl", "severity", "loglevel", "log_level", "levelname", "log.level"].map(u16)
    private static let units = ["ms", "us", "\u{B5}s", "ns", "s", "m", "h", "d", "b", "k", "kb", "kib", "mb", "mib", "gb", "gib",
                                "tb", "tib", "pb", "x", "rps", "qps", "fps"].map(u16)
    private static let exceptionSuffix = u16("Exception")
    private static let errorSuffix = u16("Error")
    private static let warningSuffix = u16("Warning")
    private static let causedBy = u16("Caused by")
    private static let traceback = u16("Traceback")
    private static let atFrame = u16("at ")
    private static let moreFrames = u16("... ")
    private static let pythonFrame = u16("File \"")

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        let end = line.trimmedEnd
        let first = line.firstNonSpace
        guard first < end else { return }
        if isStackFrame(line, first, end) {
            tokens.add(first, end, .comment)
            return
        }
        var i = line.start
        var afterTimestamp = false
        var atStart = true
        var levelPending = false
        var previousNumber = false
        while i < end {
            let c = line[i]
            if Ch.isSpace(c) {
                i += 1
                continue
            }
            let boundary = i == line.start || !isWordChar(line[i - 1])
            if c == Ch.lbracket, let t = scanTimestamp(line, i + 1, end) ?? scanWordTimestamp(line, i + 1, end), line[t] == Ch.rbracket {
                tokens.add(i, t + 1, .comment)
                i = t + 1
                afterTimestamp = true
                continue
            }
            if c == Ch.quote {
                i = lexString(line, at: i, end: end, levelPending: &levelPending, tokens: &tokens)
                afterTimestamp = false
                atStart = false
                previousNumber = false
                continue
            }
            if c == Ch.apostrophe, boundary, let close = ConfigLexKit.find(line, Ch.apostrophe, from: i + 1, limit: end),
               close + 1 >= end || !isWordChar(line[close + 1]) {
                tokens.add(i, close + 1, .string)
                i = close + 1
                afterTimestamp = false
                atStart = false
                continue
            }
            if boundary, Ch.isDigit(c) || (c == Ch.colon && line[i + 1] == Ch.colon) || (c == Ch.minus && Ch.isDigit(line[i + 1])) {
                if let t = scanTimestamp(line, i, end) {
                    tokens.add(i, t, .comment)
                    i = t
                    afterTimestamp = true
                    continue
                }
                let (e, kind) = scanNumeric(line, at: i, end: end)
                if kind != .plain { tokens.add(i, e, kind) }
                previousNumber = kind == .number
                i = e
                afterTimestamp = false
                atStart = false
                levelPending = false
                continue
            }
            if boundary, Ch.isAlpha(c) {
                if let t = scanWordTimestamp(line, i, end) {
                    tokens.add(i, t, .comment)
                    i = t
                    afterTimestamp = true
                    continue
                }
                i = lexWord(line, at: i, end: end, afterTimestamp: afterTimestamp, atStart: atStart, levelPending: &levelPending,
                            previousNumber: previousNumber, tokens: &tokens)
                afterTimestamp = false
                atStart = false
                previousNumber = false
                continue
            }
            if !isSeparator(c) {
                afterTimestamp = false
                atStart = false
            }
            i += 1
        }
    }

    // MARK: Words

    @inline(__always)
    private func isWordChar(_ c: UInt16) -> Bool {
        Ch.isAlnum(c) || c == Ch.underscore
    }

    @inline(__always)
    private func isSeparator(_ c: UInt16) -> Bool {
        c == Ch.lbracket || c == Ch.rbracket || c == Ch.minus || c == Ch.pipe || c == Ch.lparen || c == Ch.rparen || c == Ch.comma
    }

    private func lexWord(_ line: LineBuffer, at i: Int, end: Int, afterTimestamp: Bool, atStart: Bool, levelPending: inout Bool,
                         previousNumber: Bool, tokens: inout TokenBuffer) -> Int {
        if let u = scanUUID(line, i, end) {
            tokens.add(i, u, .constant)
            return u
        }
        if let u = scanURL(line, i, end) {
            tokens.add(i, u, .url)
            return u
        }
        if Ch.isHexDigit(line[i]), let ip = scanIPv6(line, i, end) {
            tokens.add(i, ip, .number)
            return ip
        }
        if let h = scanHexWord(line, i, end) {
            tokens.add(i, h, .constant)
            levelPending = false
            return h
        }
        var we = i
        while we < end, isWordChar(line[we]) { we += 1 }
        // key=value
        var ke = we
        while ke < end, isWordChar(line[ke]) || line[ke] == Ch.dot || line[ke] == Ch.minus { ke += 1 }
        if line[ke] == Ch.equals, line[ke + 1] != Ch.equals, ke < end {
            tokens.add(i, ke, .property)
            tokens.add(ke, ke + 1, .operator)
            levelPending = matchesAny(line, i, ke, Self.levelKeys, ignoringCase: true)
            return ke + 1
        }
        let wasPending = levelPending
        levelPending = false
        if we >= end || !isWordChar(line[we]) {
            if let kind = level(line, i, we, anyCase: false) {
                tokens.add(i, we, kind)
                return we
            }
            let enclosed = i > line.start && (line[i - 1] == Ch.lbracket || line[i - 1] == Ch.lparen || line[i - 1] == Ch.lt)
                && (line[we] == Ch.rbracket || line[we] == Ch.rparen || line[we] == Ch.gt)
            let clear = wasPending || enclosed || ((afterTimestamp || atStart) && line[we] == Ch.colon)
                || (afterTimestamp && Ch.isSpace(line[we]))
            if clear, let kind = level(line, i, we, anyCase: true) {
                tokens.add(i, we, kind)
                return we
            }
            if we - i == 1, let kind = logcatLevel(line[i]), line[we] == Ch.slash || (previousNumber && Ch.isSpace(line[we])) {
                tokens.add(i, we, kind)
                return we
            }
            if matchesAny(line, i, we, Self.httpMethods, ignoringCase: false) {
                tokens.add(i, we, .keyword)
                return we
            }
            if we - i == 6, line.matches(Self.causedBy, at: i), line[i + 9] == Ch.colon {
                tokens.add(i, i + 9, .keyword)
                return i + 9
            }
            if we - i == 9, line.matches(Self.traceback, at: i) {
                tokens.add(i, we, .keyword)
                return we
            }
        }
        // Exception and error types, possibly qualified: java.lang.NullPointerException, ValueError
        var qe = we
        while qe < end, isWordChar(line[qe]) || line[qe] == Ch.dot || line[qe] == Ch.dollar { qe += 1 }
        while qe > we, line[qe - 1] == Ch.dot { qe -= 1 }
        if isExceptionName(line, i, qe) {
            tokens.add(i, qe, .type)
            return qe
        }
        return max(we, i + 1)
    }

    private func matchesAny(_ line: LineBuffer, _ s: Int, _ e: Int, _ words: [[UInt16]], ignoringCase: Bool) -> Bool {
        let length = e - s
        for w in words where w.count == length {
            if ignoringCase ? line.matchesIgnoringCase(w, at: s) : line.matches(w, at: s) { return true }
        }
        return false
    }

    private func level(_ line: LineBuffer, _ s: Int, _ e: Int, anyCase: Bool) -> TokenKind? {
        let length = e - s
        guard length >= 3, length <= 9 else { return nil }
        for w in Self.levels where w.upper.count == length {
            if line.matches(w.upper, at: s) || (anyCase && line.matchesIgnoringCase(w.lower, at: s)) { return w.kind }
        }
        return nil
    }

    /// Android logcat levels: `E/Tag:` or `… 1234 5678 E Tag: …`.
    private func logcatLevel(_ c: UInt16) -> TokenKind? {
        switch c {
        case 0x45, 0x46, 0x41: .logError   // E F A
        case 0x57: .logWarning              // W
        case 0x49: .logInfo                 // I
        case 0x44, 0x56: .logDebug          // D V
        default: nil
        }
    }

    private func isExceptionName(_ line: LineBuffer, _ s: Int, _ e: Int) -> Bool {
        var segment = s
        var k = s
        while k < e {
            if line[k] == Ch.dot || line[k] == Ch.dollar { segment = k + 1 }
            k += 1
        }
        guard segment < e, Ch.isUpper(line[segment]) else { return false }
        let length = e - segment
        if length >= 9, line.matches(Self.exceptionSuffix, at: e - 9) { return true }
        if length > 5, line.matches(Self.errorSuffix, at: e - 5) { return true }
        if length > 7, line.matches(Self.warningSuffix, at: e - 7) { return true }
        return false
    }

    // MARK: Strings

    /// `"…"`: JSON keys become properties, `"level":"warn"` values levels, quoted timestamps
    /// timestamps, and `"GET /path HTTP/1.1"` keeps its method highlighted.
    private func lexString(_ line: LineBuffer, at i: Int, end: Int, levelPending: inout Bool, tokens: inout TokenBuffer) -> Int {
        guard let close = ConfigLexKit.closingQuote(line, from: i, limit: end) else {
            tokens.add(i, end, .string)
            levelPending = false
            return end
        }
        let after = line.skipSpaces(close)
        if after < end, line[after] == Ch.colon {
            tokens.add(i, close, .property)
            levelPending = matchesAny(line, i + 1, close - 1, Self.levelKeys, ignoringCase: true)
            return close
        }
        if levelPending, let kind = level(line, i + 1, close - 1, anyCase: true) {
            tokens.add(i, close, kind)
            levelPending = false
            return close
        }
        levelPending = false
        if let t = scanTimestamp(line, i + 1, close - 1) ?? scanWordTimestamp(line, i + 1, close - 1), t == close - 1 {
            tokens.add(i, close, .comment)
            return close
        }
        var me = i + 1
        while me < close, Ch.isUpper(line[me]) { me += 1 }
        if line[me] == Ch.space, matchesAny(line, i + 1, me, Self.httpMethods, ignoringCase: false) {
            tokens.add(i, i + 1, .string)
            tokens.add(i + 1, me, .keyword)
            tokens.add(me, close, .string)
            return close
        }
        tokens.add(i, close, .string)
        return close
    }

    // MARK: Stack frames

    private func isStackFrame(_ line: LineBuffer, _ f: Int, _ end: Int) -> Bool {
        let indented = f > line.start
        if indented, line.matches(Self.atFrame, at: f) { return true }
        if indented, line.matches(Self.moreFrames, at: f), Ch.isDigit(line[f + 4]) { return true }
        if indented, line.matches(Self.pythonFrame, at: f) { return true }
        // gdb/lldb: `#3  0x00007fff… in foo () at x.c:12`
        if line[f] == Ch.hash, Ch.isDigit(line[f + 1]) {
            var k = f + 1
            while k < end, Ch.isDigit(line[k]) { k += 1 }
            return Ch.isSpace(line[k])
        }
        // Apple crash reports: `3   libsystem_kernel.dylib   0x00007fff… __pthread_kill + 10`
        if !indented, Ch.isDigit(line[f]) {
            var k = f
            while k < end, Ch.isDigit(line[k]) { k += 1 }
            guard k - f <= 4, Ch.isSpace(line[k]) else { return false }
            k = line.skipSpaces(k)
            let ws = k
            while k < end, !Ch.isSpace(line[k]) { k += 1 }
            guard k > ws else { return false }
            k = line.skipSpaces(k)
            return line[k] == Ch.zero && line[k + 1] == Ch.x
        }
        return false
    }

    // MARK: Timestamps

    private func digits(_ line: LineBuffer, _ k: Int, _ n: Int, _ end: Int) -> Bool {
        guard k + n <= end else { return false }
        for m in 0..<n where !Ch.isDigit(line[k + m]) { return false }
        return true
    }

    /// `HH:MM:SS[.fff|,fff]` (one-digit hours allowed).
    private func scanTime(_ line: LineBuffer, _ k: Int, _ end: Int) -> Int? {
        var h = k
        if digits(line, k, 2, end) {
            h = k + 2
        } else if digits(line, k, 1, end) {
            h = k + 1
        } else {
            return nil
        }
        guard line[h] == Ch.colon, digits(line, h + 1, 2, end), line[h + 3] == Ch.colon, digits(line, h + 4, 2, end) else { return nil }
        var e = h + 6
        if line[e] == Ch.dot || line[e] == Ch.comma, e + 1 < end, Ch.isDigit(line[e + 1]) {
            e += 1
            while e < end, Ch.isDigit(line[e]) { e += 1 }
        }
        return e
    }

    /// `Z`, `+01:00`, `-0500`, ` +0000`.
    private func scanZone(_ line: LineBuffer, _ k: Int, _ end: Int) -> Int {
        if k < end, line[k] == 0x5A { return k + 1 }
        var s = k
        if line[s] == Ch.space, line[s + 1] == Ch.plus || line[s + 1] == Ch.minus { s += 1 }
        guard line[s] == Ch.plus || line[s] == Ch.minus, digits(line, s + 1, 2, end) else { return k }
        if line[s + 3] == Ch.colon, digits(line, s + 4, 2, end) { return s + 6 }
        if digits(line, s + 3, 2, end) { return s + 5 }
        return s == k ? s + 3 : k
    }

    /// Numeric timestamps: ISO dates with optional time, logcat `MM-DD HH:MM:SS.mmm`, Apache
    /// `15/Jan/2024:10:30:00 +0000` and bare times.
    private func scanTimestamp(_ line: LineBuffer, _ i: Int, _ end: Int) -> Int? {
        if digits(line, i, 4, end), line[i + 4] == Ch.minus || line[i + 4] == Ch.slash || line[i + 4] == Ch.dot,
           digits(line, i + 5, 2, end), line[i + 7] == line[i + 4], digits(line, i + 8, 2, end) {
            var k = i + 10
            let sep = line[k]
            if sep == 0x54 || sep == Ch.space || sep == Ch.underscore, let t = scanTime(line, k + 1, end) {
                k = scanZone(line, t, end)
            }
            return k
        }
        if digits(line, i, 2, end), line[i + 2] == Ch.minus, digits(line, i + 3, 2, end), line[i + 5] == Ch.space,
           let t = scanTime(line, i + 6, end) {
            return t
        }
        if digits(line, i, 2, end), line[i + 2] == Ch.slash, Ch.isAlpha(line[i + 3]), Ch.isAlpha(line[i + 4]), Ch.isAlpha(line[i + 5]),
           line[i + 6] == Ch.slash, digits(line, i + 7, 4, end), line[i + 11] == Ch.colon, let t = scanTime(line, i + 12, end) {
            return scanZone(line, t, end)
        }
        if let t = scanTime(line, i, end), t >= end || !isWordChar(line[t]) {
            return scanZone(line, t, end)
        }
        return nil
    }

    /// Timestamps starting with a name: syslog `Jan 15 10:30:00`, ctime `Mon Jan 15 10:30:00 2024`,
    /// RFC 2822 `Mon, 15 Jan 2024 10:30:00 +0000`.
    private func scanWordTimestamp(_ line: LineBuffer, _ i: Int, _ end: Int) -> Int? {
        var k = i
        if matchesAny(line, k, k + 3, Self.weekdays, ignoringCase: false), !Ch.isAlpha(line[k + 3]) {
            k += 3
            if line[k] == Ch.comma { k += 1 }
            k = line.skipSpaces(k)
        }
        if matchesAny(line, k, k + 3, Self.months, ignoringCase: false), !Ch.isAlpha(line[k + 3]) {
            var m = line.skipSpaces(k + 3)
            let ds = m
            while m < end, m - ds < 2, Ch.isDigit(line[m]) { m += 1 }
            guard m > ds else { return nil }
            m = line.skipSpaces(m)
            if digits(line, m, 4, end), line[m + 4] == Ch.space, let t = scanTime(line, m + 5, end) {
                return scanZone(line, t, end)
            }
            guard let t = scanTime(line, m, end) else { return nil }
            var e = t
            if line[e] == Ch.space, digits(line, e + 1, 4, end), !Ch.isDigit(line[e + 5]) { e += 5 }
            return scanZone(line, e, end)
        }
        if k > i, Ch.isDigit(line[k]) {
            var m = k
            while m < end, m - k < 2, Ch.isDigit(line[m]) { m += 1 }
            m = line.skipSpaces(m)
            guard matchesAny(line, m, m + 3, Self.months, ignoringCase: false) else { return nil }
            m = line.skipSpaces(m + 3)
            guard digits(line, m, 4, end) else { return nil }
            m = line.skipSpaces(m + 4)
            guard let t = scanTime(line, m, end) else { return nil }
            return scanZone(line, t, end)
        }
        return nil
    }

    // MARK: Numbers and identifiers

    /// Numbers (with units), IPv4/IPv6 addresses, UUIDs, MAC addresses and hex values.
    private func scanNumeric(_ line: LineBuffer, at i: Int, end: Int) -> (Int, TokenKind) {
        if let u = scanUUID(line, i, end) { return (u, .constant) }
        if let m = scanMAC(line, i, end) { return (m, .constant) }
        if let ip = scanIPv4(line, i, end) { return (ip, .number) }
        if let h = scanHexWord(line, i, end) { return (h, .constant) }
        if let ip = scanIPv6(line, i, end) { return (ip, .number) }
        var k = i
        if line[k] == Ch.minus { k += 1 }
        guard Ch.isDigit(line[k]) else { return (i + 1, .plain) }
        while k < end, Ch.isDigit(line[k]) { k += 1 }
        while k < end, line[k] == Ch.dot, Ch.isDigit(line[k + 1]) {
            k += 1
            while k < end, Ch.isDigit(line[k]) { k += 1 }
        }
        if line[k] == Ch.percent { return (k + 1, .number) }
        var u = k
        while u < end, Ch.isAlpha(line[u]) || line[u] == 0xB5 { u += 1 }
        if u > k {
            if u < end, isWordChar(line[u]) { return (skipWord(line, u, end), .plain) }
            if matchesAny(line, k, u, Self.units, ignoringCase: true) { return (u, .number) }
            return (u, .plain)
        }
        if k < end, isWordChar(line[k]) { return (skipWord(line, k, end), .plain) }
        return (k, .number)
    }

    private func skipWord(_ line: LineBuffer, _ k: Int, _ end: Int) -> Int {
        var e = k
        while e < end, isWordChar(line[e]) { e += 1 }
        return e
    }

    private func hexRun(_ line: LineBuffer, _ k: Int, _ n: Int, _ end: Int) -> Bool {
        guard k + n <= end else { return false }
        for m in 0..<n where !Ch.isHexDigit(line[k + m]) { return false }
        return true
    }

    /// `123e4567-e89b-12d3-a456-426614174000`
    private func scanUUID(_ line: LineBuffer, _ i: Int, _ end: Int) -> Int? {
        guard hexRun(line, i, 8, end), line[i + 8] == Ch.minus, hexRun(line, i + 9, 4, end), line[i + 13] == Ch.minus,
              hexRun(line, i + 14, 4, end), line[i + 18] == Ch.minus, hexRun(line, i + 19, 4, end), line[i + 23] == Ch.minus,
              hexRun(line, i + 24, 12, end), i + 36 >= end || !isWordChar(line[i + 36]) else { return nil }
        return i + 36
    }

    /// `00:1a:2b:3c:4d:5e`
    private func scanMAC(_ line: LineBuffer, _ i: Int, _ end: Int) -> Int? {
        let sep = line[i + 2]
        guard sep == Ch.colon || sep == Ch.minus else { return nil }
        for g in 0..<6 {
            let k = i + g * 3
            guard hexRun(line, k, 2, end) else { return nil }
            if g < 5, line[k + 2] != sep { return nil }
        }
        let e = i + 17
        return e >= end || !isWordChar(line[e]) ? e : nil
    }

    /// `192.168.1.10`, `10.0.0.0/8`, `127.0.0.1:8080`
    private func scanIPv4(_ line: LineBuffer, _ i: Int, _ end: Int) -> Int? {
        var k = i
        for group in 0..<4 {
            let s = k
            while k < end, k - s < 3, Ch.isDigit(line[k]) { k += 1 }
            guard k > s else { return nil }
            if group < 3 {
                guard line[k] == Ch.dot else { return nil }
                k += 1
            }
        }
        if Ch.isDigit(line[k]) || (line[k] == Ch.dot && Ch.isDigit(line[k + 1])) { return nil }
        if line[k] == Ch.slash || line[k] == Ch.colon, Ch.isDigit(line[k + 1]) {
            k += 1
            while k < end, Ch.isDigit(line[k]) { k += 1 }
        }
        return k
    }

    /// `2001:db8::1`, `::1`, `fe80::1%en0`
    private func scanIPv6(_ line: LineBuffer, _ i: Int, _ end: Int) -> Int? {
        var k = i
        var colons = 0
        var doubleColon = false
        var hex = 0
        while k < end, k - i < 45 {
            let c = line[k]
            if c == Ch.colon {
                colons += 1
                if line[k + 1] == Ch.colon { doubleColon = true }
            } else if Ch.isHexDigit(c) {
                hex += 1
            } else {
                break
            }
            k += 1
        }
        guard hex > 0, colons >= 2, doubleColon || colons == 7 else { return nil }
        if line[k] == Ch.percent, Ch.isAlnum(line[k + 1]) {
            k += 1
            while k < end, Ch.isAlnum(line[k]) { k += 1 }
        }
        if k < end, isWordChar(line[k]) || line[k] == Ch.dot { return nil }
        return k
    }

    /// `0x7fff5fbff8c0`, or a run of 7+ hex characters with at least one digit and one letter
    /// (commit hashes, digests).
    private func scanHexWord(_ line: LineBuffer, _ i: Int, _ end: Int) -> Int? {
        if line[i] == Ch.zero, line[i + 1] == Ch.x, Ch.isHexDigit(line[i + 2]) {
            var k = i + 2
            while k < end, Ch.isHexDigit(line[k]) { k += 1 }
            return k >= end || !isWordChar(line[k]) ? k : nil
        }
        var k = i
        var digits = false
        var letters = false
        while k < end, Ch.isHexDigit(line[k]) {
            if Ch.isDigit(line[k]) { digits = true } else { letters = true }
            k += 1
        }
        guard k - i >= 7, digits, letters, k >= end || !isWordChar(line[k]) else { return nil }
        return k
    }

    /// `https://example.com/path?q=1`, `s3://bucket/key`, `file:///tmp/x`
    private func scanURL(_ line: LineBuffer, _ i: Int, _ end: Int) -> Int? {
        var k = i
        while k < end, k - i <= 16, Ch.isAlnum(line[k]) || line[k] == Ch.plus || line[k] == Ch.dot || line[k] == Ch.minus { k += 1 }
        guard k > i, line[k] == Ch.colon, line[k + 1] == Ch.slash, line[k + 2] == Ch.slash else { return nil }
        var e = k + 3
        while e < end {
            let c = line[e]
            if Ch.isSpace(c) || c == Ch.quote || c == Ch.apostrophe || c == Ch.lt || c == Ch.gt || c == Ch.backtick { break }
            e += 1
        }
        while e > k + 3 {
            let c = line[e - 1]
            guard c == Ch.dot || c == Ch.comma || c == Ch.semicolon || c == Ch.colon || c == Ch.bang || c == Ch.question
                || c == Ch.rparen || c == Ch.rbracket || c == Ch.rbrace else { break }
            e -= 1
        }
        return e > k + 3 ? e : nil
    }
}
