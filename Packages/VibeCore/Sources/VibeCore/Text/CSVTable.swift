import Foundation

/// A table read from delimiter-separated text (CSV, TSV…), following RFC 4180 loosely: fields may be
/// quoted (`"a, b"`, with `""` for a quote and line breaks inside the quotes), lines end in LF, CRLF or
/// CR, and records may have different numbers of fields. Fields are kept as UTF-16 ranges of the text,
/// which are the editor's offsets too, and are read when shown, so large files cost little memory.
public struct CSVTable: Sendable {
    /// What separates the fields of a record.
    public enum Delimiter: UInt16, CaseIterable, Sendable {
        case comma = 0x2C
        case semicolon = 0x3B
        case tab = 0x09
        case pipe = 0x7C

        public var name: String {
            switch self {
            case .comma: "Comma"
            case .semicolon: "Semicolon"
            case .tab: "Tab"
            case .pipe: "Pipe"
            }
        }

        /// How the delimiter shows in menus: `,` `;` `⇥` `|`.
        public var symbol: String {
            switch self {
            case .comma: ","
            case .semicolon: ";"
            case .tab: "⇥"
            case .pipe: "|"
            }
        }
    }

    public let delimiter: Delimiter
    /// The most fields any record has.
    public let columnCount: Int
    private let units: [UInt16]
    /// Field `i` is `units[fieldStarts[i]..<fieldEnds[i]]`, quotes included.
    private let fieldStarts: [Int32]
    private let fieldEnds: [Int32]
    /// Record `r` is fields `rowStarts[r]..<rowStarts[r + 1]`.
    private let rowStarts: [Int32]
    /// The line (0-based) each record starts on.
    private let rowLines: [Int32]

    /// Reads `text` with `delimiter`, or with the one it seems to use (`preferred` when unsure).
    public init(_ text: String, delimiter: Delimiter? = nil, preferred: Delimiter = .comma) {
        let units = Self.utf16(text)
        self.init(units: units, delimiter: delimiter ?? Self.detectDelimiter(units, preferred: preferred))
    }

    public init(units: [UInt16], delimiter: Delimiter) {
        let scan = Self.scan(units, delimiter: delimiter.rawValue, limit: .max)
        self.units = units
        self.delimiter = delimiter
        columnCount = scan.columnCount
        fieldStarts = scan.fieldStarts
        fieldEnds = scan.fieldEnds
        rowStarts = scan.rowStarts
        rowLines = scan.rowLines
    }

    /// The number of records, the header (if any) included.
    public var rowCount: Int { rowStarts.count - 1 }

    public func fieldCount(row: Int) -> Int {
        guard row >= 0, row < rowCount else { return 0 }
        return Int(rowStarts[row + 1] - rowStarts[row])
    }

    /// The line (0-based) record `row` starts on.
    public func line(ofRow row: Int) -> Int { Int(rowLines[row]) }

    /// The text of field `column` of record `row`, without its quotes; empty past the record's end.
    public func value(row: Int, column: Int) -> String {
        guard let field = fieldIndex(row: row, column: column) else { return "" }
        return Self.unquote(units, from: Int(fieldStarts[field]), to: Int(fieldEnds[field]))
    }

    /// Every field of record `row`.
    public func values(row: Int) -> [String] {
        (0..<fieldCount(row: row)).map { value(row: row, column: $0) }
    }

    /// Where field `column` of record `row` is in the text, quotes included; nil past the record's end.
    public func range(row: Int, column: Int) -> NSRange? {
        guard let field = fieldIndex(row: row, column: column) else { return nil }
        return NSRange(location: Int(fieldStarts[field]), length: Int(fieldEnds[field] - fieldStarts[field]))
    }

    /// Where the value of field `column` of record `row` is: inside the quotes of a quoted field.
    public func contentRange(row: Int, column: Int) -> NSRange? {
        guard let field = fieldIndex(row: row, column: column) else { return nil }
        let start = Int(fieldStarts[field]), end = Int(fieldEnds[field])
        guard start < end, units[start] == Ch.quote else { return NSRange(location: start, length: end - start) }
        var i = start + 1
        while i < end {
            if units[i] == Ch.quote {
                if i + 1 < end, units[i + 1] == Ch.quote {
                    i += 2
                    continue
                }
                break
            }
            i += 1
        }
        return NSRange(location: start + 1, length: i - start - 1)
    }

    /// Where record `row` is in the text, from its first field's start to its last field's end.
    public func rowRange(_ row: Int) -> NSRange {
        let start = Int(fieldStarts[Int(rowStarts[row])])
        let end = Int(fieldEnds[Int(rowStarts[row + 1]) - 1])
        return NSRange(location: start, length: end - start)
    }

    /// The record and field holding text offset `offset` (a delimiter belongs to the field before it,
    /// a line break to the record before it); nil for an empty table.
    public func cell(at offset: Int) -> (row: Int, column: Int)? {
        guard rowCount > 0 else { return nil }
        let field = Self.lastIndex(in: fieldStarts, count: fieldStarts.count, notAfter: offset)
        let row = Self.lastIndex(in: rowStarts, count: rowCount, notAfter: field)
        return (row, field - Int(rowStarts[row]))
    }

    private func fieldIndex(row: Int, column: Int) -> Int? {
        guard row >= 0, row < rowCount, column >= 0 else { return nil }
        let field = Int(rowStarts[row]) + column
        return field < Int(rowStarts[row + 1]) ? field : nil
    }

    /// The last index `i < count` with `values[i] <= limit` (0 when there's none).
    private static func lastIndex(in values: [Int32], count: Int, notAfter limit: Int) -> Int {
        var low = 0, high = count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if Int(values[middle]) <= limit { low = middle } else { high = middle - 1 }
        }
        return low
    }

    // MARK: Reading

    private struct Scan {
        var fieldStarts: [Int32] = []
        var fieldEnds: [Int32] = []
        var rowStarts: [Int32] = [0]
        var rowLines: [Int32] = []
        var columnCount = 0
    }

    /// Reads at most `limit` records from the start of `units`.
    private static func scan(_ units: [UInt16], delimiter: UInt16, limit: Int) -> Scan {
        var scan = Scan()
        // Offsets are stored as Int32: nobody edits a text of two billion characters.
        let n = min(units.count, Int(Int32.max))
        guard n > 0 else { return scan }
        units.withUnsafeBufferPointer { u in
            var i = 0
            var line: Int32 = 0
            var fields = 0
            scan.rowLines.append(0)
            while true {
                let start = i
                if i < n, u[i] == Ch.quote {
                    // A quoted field runs to the quote closing it (`""` is a quote), across lines.
                    i += 1
                    while i < n {
                        let c = u[i]
                        if c == Ch.quote {
                            if i + 1 < n, u[i + 1] == Ch.quote {
                                i += 2
                                continue
                            }
                            i += 1
                            break
                        }
                        if c == Ch.newline || (c == Ch.cr && (i + 1 == n || u[i + 1] != Ch.newline)) { line += 1 }
                        i += 1
                    }
                }
                // Up to the delimiter or the end of the line (text after a closing quote is kept).
                while i < n {
                    let c = u[i]
                    if c == delimiter || c == Ch.newline || c == Ch.cr { break }
                    i += 1
                }
                scan.fieldStarts.append(Int32(start))
                scan.fieldEnds.append(Int32(i))
                fields += 1
                if i < n, u[i] == delimiter {
                    i += 1
                    continue
                }
                scan.rowStarts.append(Int32(scan.fieldStarts.count))
                scan.columnCount = max(scan.columnCount, fields)
                fields = 0
                guard i < n else { break }
                i += u[i] == Ch.cr && i + 1 < n && u[i + 1] == Ch.newline ? 2 : 1
                line += 1
                // A line break at the very end doesn't start another record.
                guard i < n, scan.rowStarts.count - 1 < limit else { break }
                scan.rowLines.append(line)
            }
        }
        return scan
    }

    /// The delimiter that splits the first records of `units` most consistently into the same number of
    /// fields (two or more); `preferred` when none does better.
    public static func detectDelimiter(_ units: [UInt16], preferred: Delimiter = .comma) -> Delimiter {
        var best = preferred
        var bestScore = (records: 0, fields: 0)
        for candidate in [preferred] + Delimiter.allCases.filter({ $0 != preferred }) {
            let scan = scan(units, delimiter: candidate.rawValue, limit: 40)
            var frequency: [Int: Int] = [:]
            for row in 0..<(scan.rowStarts.count - 1) {
                let fields = Int(scan.rowStarts[row + 1] - scan.rowStarts[row])
                if fields > 1 { frequency[fields, default: 0] += 1 }
            }
            guard let top = frequency.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }) else { continue }
            if (top.value, top.key) > (bestScore.records, bestScore.fields) {
                best = candidate
                bestScore = (top.value, top.key)
            }
        }
        return best
    }

    public static func detectDelimiter(_ text: String, preferred: Delimiter = .comma) -> Delimiter {
        // The first records are enough.
        detectDelimiter(utf16(String(text.prefix(65_536))), preferred: preferred)
    }

    /// Whether the first record reads as column titles: nothing in it is a number.
    public var firstRowLooksLikeHeader: Bool {
        guard rowCount > 0 else { return false }
        let titles = values(row: 0)
        return titles.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } && !titles.contains { Self.number($0) != nil }
    }

    // MARK: Values

    /// A field's text: the part inside the quotes of a quoted field, `""` read as `"`, and anything
    /// after the closing quote kept as is.
    private static func unquote(_ units: [UInt16], from start: Int, to end: Int) -> String {
        guard start < end, units[start] == Ch.quote else { return String(decoding: units[start..<end], as: UTF16.self) }
        var value: [UInt16] = []
        value.reserveCapacity(end - start)
        var i = start + 1
        while i < end {
            let c = units[i]
            if c == Ch.quote {
                if i + 1 < end, units[i + 1] == Ch.quote {
                    value.append(Ch.quote)
                    i += 2
                    continue
                }
                value.append(contentsOf: units[(i + 1)..<end])
                break
            }
            value.append(c)
            i += 1
        }
        return String(decoding: value, as: UTF16.self)
    }

    /// The number a value holds: `42`, `-3.5`, `1,25` (a decimal comma), `.5`, `6.02e23` or `15%`,
    /// with spaces around it or not; nil for anything else (dates, `1.2.3`, `1,234,567`).
    public static func number(_ value: String) -> Double? {
        let units = Array(value.utf16)
        var i = 0, end = units.count
        while i < end, units[i] == Ch.space { i += 1 }
        while end > i, units[end - 1] == Ch.space { end -= 1 }
        if end > i, units[end - 1] == Ch.percent { end -= 1 }
        var ascii: [UInt8] = []
        if i < end, units[i] == Ch.minus || units[i] == Ch.plus {
            ascii.append(UInt8(units[i]))
            i += 1
        }
        var digits = 0
        while i < end, Ch.isDigit(units[i]) {
            ascii.append(UInt8(units[i]))
            i += 1
            digits += 1
        }
        if i < end, units[i] == Ch.dot || units[i] == Ch.comma {
            ascii.append(UInt8(Ch.dot))
            i += 1
            while i < end, Ch.isDigit(units[i]) {
                ascii.append(UInt8(units[i]))
                i += 1
                digits += 1
            }
        }
        guard digits > 0 else { return nil }
        if i < end, units[i] == Ch.e || units[i] == 0x45 {
            ascii.append(UInt8(Ch.e))
            i += 1
            if i < end, units[i] == Ch.minus || units[i] == Ch.plus {
                ascii.append(UInt8(units[i]))
                i += 1
            }
            var exponent = 0
            while i < end, Ch.isDigit(units[i]) {
                ascii.append(UInt8(units[i]))
                i += 1
                exponent += 1
            }
            guard exponent > 0 else { return nil }
        }
        guard i == end else { return nil }
        return Double(String(decoding: ascii, as: UTF8.self))
    }

    /// Records `rows` in the order of their values in `column`: numbers by value before text, which sorts
    /// naturally (`file2` before `file10`, ignoring case); empty values last either way, and equal
    /// values keep their order.
    public func sorted(_ rows: [Int], byColumn column: Int, ascending: Bool) -> [Int] {
        enum Key {
            case number(Double)
            case text([UInt16])
            case empty
        }
        let keys: [Key] = rows.map { row in
            let value = self.value(row: row, column: column).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return .empty }
            if let number = Self.number(value) { return .number(number) }
            return .text(Self.sortKey(value))
        }
        let order = rows.indices.sorted { a, b in
            let order: ComparisonResult
            switch (keys[a], keys[b]) {
            case (.empty, .empty): return a < b
            case (.empty, _): return false
            case (_, .empty): return true
            case let (.number(x), .number(y)): order = x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
            case (.number, .text): order = .orderedAscending
            case (.text, .number): order = .orderedDescending
            case let (.text(x), .text(y)): order = Self.compare(x, y)
            }
            if order == .orderedSame { return a < b }
            return order == (ascending ? .orderedAscending : .orderedDescending)
        }
        return order.map { rows[$0] }
    }

    /// `value` folded for sorting: case and accents ignored, and every run of digits written as its
    /// length (a control character) then its digits without leading zeros, so `file2` sorts before
    /// `file10` and digits before letters.
    static func sortKey(_ value: String) -> [UInt16] {
        let units: [UInt16]
        if value.utf8.allSatisfy({ $0 < 0x80 }) {
            units = value.utf16.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
        } else {
            units = Array(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).utf16)
        }
        var key: [UInt16] = []
        key.reserveCapacity(units.count + 2)
        var i = 0
        while i < units.count {
            guard Ch.isDigit(units[i]) else {
                key.append(units[i])
                i += 1
                continue
            }
            var first = i
            while i < units.count, Ch.isDigit(units[i]) { i += 1 }
            while first < i - 1, units[first] == Ch.zero { first += 1 }
            key.append(UInt16(min(i - first, 31)))
            key.append(contentsOf: units[first..<i])
        }
        return key
    }

    private static func compare(_ a: [UInt16], _ b: [UInt16]) -> ComparisonResult {
        for i in 0..<min(a.count, b.count) where a[i] != b[i] {
            return a[i] < b[i] ? .orderedAscending : .orderedDescending
        }
        return a.count == b.count ? .orderedSame : (a.count < b.count ? .orderedAscending : .orderedDescending)
    }

    // MARK: Writing

    /// `value` as a field: quoted when it holds the delimiter, a quote or a line break.
    public static func field(_ value: String, delimiter: Delimiter) -> String {
        let special: Set<UInt16> = [delimiter.rawValue, Ch.quote, Ch.newline, Ch.cr]
        guard value.utf16.contains(where: special.contains) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Spreadsheet column names: A…Z, then AA, AB…
    public static func columnName(_ index: Int) -> String {
        var name = ""
        var n = index + 1
        while n > 0 {
            let letter = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + letter))) + name
            n = (n - 1) / 26
        }
        return name
    }

    /// The text as UTF-16, copied in one go.
    static func utf16(_ text: String) -> [UInt16] {
        let string = text as NSString
        let length = string.length
        return [UInt16](unsafeUninitializedCapacity: length) { buffer, count in
            if let base = buffer.baseAddress, length > 0 { string.getCharacters(base, range: NSRange(location: 0, length: length)) }
            count = length
        }
    }
}
