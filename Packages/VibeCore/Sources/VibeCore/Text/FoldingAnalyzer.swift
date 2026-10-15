import Foundation

/// A collapsible section of a document.
///
/// The hidden text starts at the line feed that ends the region's first line and stops
/// right before the closing bracket (or at the end of the block's last line), so a folded
/// JSON object reads `"meta": {⋯},` — the first line and the closing bracket stay visible.
public struct FoldRegion: Hashable, Sendable {
    /// UTF-16 offset of the line feed ending the first line.
    public var hiddenStart: Int
    /// Exclusive end of the hidden text.
    public var hiddenEnd: Int
    /// Nesting depth (0 = outermost).
    public var depth: Int

    public init(hiddenStart: Int, hiddenEnd: Int, depth: Int) {
        self.hiddenStart = hiddenStart
        self.hiddenEnd = hiddenEnd
        self.depth = depth
    }

    public var hiddenRange: NSRange { NSRange(location: hiddenStart, length: max(0, hiddenEnd - hiddenStart)) }
}

/// Finds foldable regions: bracket pairs for JSON and C-like languages, elements for XML,
/// indentation blocks for YAML and Python, and heading sections for Markdown.
public enum FoldingAnalyzer {
    enum Strategy {
        case brackets(BracketSyntax)
        case tags
        case indentation
        case headings
    }

    struct BracketSyntax {
        var lineComments: [[UInt16]] = [u16("//")]
        var blockComment = true
        var singleQuoteStrings = true
        var backtickStrings = false
        var tripleQuoteStrings = false
    }

    static func strategy(for language: LanguageID) -> Strategy? {
        switch language {
        case .json:
            return .brackets(BracketSyntax(singleQuoteStrings: false))
        case .javascript, .typescript:
            return .brackets(BracketSyntax(backtickStrings: true))
        case .swift, .kotlin, .scala, .groovy:
            return .brackets(BracketSyntax(singleQuoteStrings: language == .groovy, tripleQuoteStrings: true))
        case .java, .c, .cpp, .objectiveC, .csharp, .dart, .php:
            return .brackets(BracketSyntax())
        case .go:
            return .brackets(BracketSyntax(backtickStrings: true))
        case .rust:
            return .brackets(BracketSyntax(singleQuoteStrings: false))
        case .css, .scss, .less:
            return .brackets(BracketSyntax(lineComments: language == .css ? [] : [u16("//")]))
        case .graphql:
            return .brackets(BracketSyntax(lineComments: [u16("#")], blockComment: false, singleQuoteStrings: false, tripleQuoteStrings: true))
        case .protobuf:
            return .brackets(BracketSyntax())
        case .hcl:
            return .brackets(BracketSyntax(lineComments: [u16("#"), u16("//")]))
        case .xml:
            return .tags
        case .yaml, .python:
            return .indentation
        case .markdown:
            return .headings
        default:
            return nil
        }
    }

    public static func supportsFolding(_ language: LanguageID) -> Bool {
        strategy(for: language) != nil
    }

    /// Regions sorted by `hiddenStart`; only regions spanning at least two lines are returned.
    public static func regions(in text: NSString, language: LanguageID) -> [FoldRegion] {
        guard let strategy = strategy(for: language), text.length > 0 else { return [] }
        let units = characters(of: text)
        var result: [FoldRegion]
        switch strategy {
        case .brackets(let syntax): result = bracketRegions(units, syntax)
        case .tags: result = tagRegions(units)
        case .indentation: result = indentationRegions(units, isYAML: language == .yaml)
        case .headings: result = headingRegions(units)
        }
        result.sort { $0.hiddenStart == $1.hiddenStart ? $0.hiddenEnd > $1.hiddenEnd : $0.hiddenStart < $1.hiddenStart }
        // Keep one region per starting line (the outermost).
        var unique: [FoldRegion] = []
        unique.reserveCapacity(result.count)
        for region in result where unique.last?.hiddenStart != region.hiddenStart {
            unique.append(region)
        }
        return unique
    }

    private static func characters(of text: NSString) -> [UInt16] {
        var units = [UInt16](repeating: 0, count: text.length)
        units.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { text.getCharacters(base, range: NSRange(location: 0, length: text.length)) }
        }
        return units
    }

    // MARK: Brackets

    private static func bracketRegions(_ s: [UInt16], _ syntax: BracketSyntax) -> [FoldRegion] {
        var regions: [FoldRegion] = []
        // Open brackets: (character, offset of the line feed ending its line, or -1 when unknown yet).
        var stack: [(open: UInt16, lineEnd: Int, line: Int)] = []
        var pendingLineEnds: [Int] = [] // stack indexes whose line hasn't ended yet
        var line = 0
        var i = 0
        let n = s.count

        @inline(__always) func matches(_ lit: [UInt16], _ at: Int) -> Bool {
            guard at + lit.count <= n else { return false }
            for k in 0..<lit.count where s[at + k] != lit[k] { return false }
            return true
        }

        while i < n {
            let c = s[i]
            if c == Ch.newline {
                for index in pendingLineEnds where index < stack.count { stack[index].lineEnd = i }
                pendingLineEnds.removeAll(keepingCapacity: true)
                line += 1
                i += 1
                continue
            }
            // Comments
            var skipped = false
            for marker in syntax.lineComments where matches(marker, i) {
                while i < n, s[i] != Ch.newline { i += 1 }
                skipped = true
                break
            }
            if skipped { continue }
            if syntax.blockComment, c == Ch.slash, i + 1 < n, s[i + 1] == Ch.star {
                i += 2
                while i < n, !(s[i] == Ch.star && i + 1 < n && s[i + 1] == Ch.slash) {
                    if s[i] == Ch.newline {
                        for index in pendingLineEnds where index < stack.count { stack[index].lineEnd = i }
                        pendingLineEnds.removeAll(keepingCapacity: true)
                        line += 1
                    }
                    i += 1
                }
                i += 2
                continue
            }
            // Strings
            if c == Ch.quote || (syntax.singleQuoteStrings && c == Ch.apostrophe) || (syntax.backtickStrings && c == Ch.backtick) {
                let triple = syntax.tripleQuoteStrings && c == Ch.quote && i + 2 < n && s[i + 1] == Ch.quote && s[i + 2] == Ch.quote
                let multiline = triple || c == Ch.backtick
                i += triple ? 3 : 1
                while i < n {
                    let d = s[i]
                    if d == Ch.backslash { i += 2; continue }
                    if d == Ch.newline {
                        if !multiline { break }
                        for index in pendingLineEnds where index < stack.count { stack[index].lineEnd = i }
                        pendingLineEnds.removeAll(keepingCapacity: true)
                        line += 1
                    }
                    if triple {
                        if d == Ch.quote, i + 2 < n, s[i + 1] == Ch.quote, s[i + 2] == Ch.quote { i += 3; break }
                    } else if d == c {
                        i += 1
                        break
                    }
                    i += 1
                }
                continue
            }
            if c == Ch.lbrace || c == Ch.lbracket {
                stack.append((c, -1, line))
                pendingLineEnds.append(stack.count - 1)
            } else if c == Ch.rbrace || c == Ch.rbracket {
                let expected = c == Ch.rbrace ? Ch.lbrace : Ch.lbracket
                if let index = stack.lastIndex(where: { $0.open == expected }) {
                    let open = stack[index]
                    let depth = index
                    stack.removeSubrange(index...)
                    pendingLineEnds.removeAll { $0 >= index }
                    if open.line < line, open.lineEnd >= 0, open.lineEnd < i {
                        regions.append(FoldRegion(hiddenStart: open.lineEnd, hiddenEnd: i, depth: depth))
                    }
                }
            }
            i += 1
        }
        return regions
    }

    // MARK: XML tags

    /// Elements whose end tag is on a later line than their start tag, folded from the end of the
    /// first line to the `</name>`, which stays visible. Multi-line comments, CDATA sections, DOCTYPE
    /// subsets and self-closing tags fold too, up to their `-->`, `]]>`, `]>` or `/>`.
    private static func tagRegions(_ s: [UInt16]) -> [FoldRegion] {
        let n = s.count
        var lineEnds: [Int] = []
        for i in 0..<n where s[i] == Ch.newline { lineEnds.append(i) }
        var regions: [FoldRegion] = []
        // Open elements: where the tag starts, and its name.
        var stack: [(start: Int, name: Range<Int>)] = []

        @inline(__always) func matches(_ lit: [UInt16], _ at: Int) -> Bool {
            guard at + lit.count <= n else { return false }
            for k in 0..<lit.count where s[at + k] != lit[k] { return false }
            return true
        }
        func find(_ lit: [UInt16], from start: Int) -> Int? {
            var j = start
            while j < n {
                if s[j] == lit[0], matches(lit, j) { return j }
                j += 1
            }
            return nil
        }
        /// A region from the end of the line holding `start` to `end`, if they're on different lines.
        func add(_ start: Int, _ end: Int, depth: Int) {
            // The first line feed at or after `start` ends its line.
            var lo = 0, hi = lineEnds.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if lineEnds[mid] < start { lo = mid + 1 } else { hi = mid }
            }
            guard lo < lineEnds.count, lineEnds[lo] < end else { return }
            regions.append(FoldRegion(hiddenStart: lineEnds[lo], hiddenEnd: end, depth: depth))
        }
        func name(at start: Int) -> Range<Int> {
            var j = start
            while j < n, s[j] != Ch.space, s[j] != Ch.newline, s[j] != Ch.tab, s[j] != Ch.cr, s[j] != Ch.gt, s[j] != Ch.slash { j += 1 }
            return start..<j
        }
        /// The `>` ending the tag that starts at `start`, skipping quoted attribute values.
        func tagEnd(from start: Int) -> Int {
            var j = start
            var quote: UInt16 = 0
            while j < n {
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
            return n
        }

        var i = 0
        while i < n {
            guard s[i] == Ch.lt, i + 1 < n else {
                i += 1
                continue
            }
            let next = s[i + 1]
            if matches(xmlCommentStart, i) {
                guard let end = find(xmlCommentEnd, from: i + 4) else { break }
                add(i, end, depth: stack.count)
                i = end + 3
            } else if matches(cdataStart, i) {
                guard let end = find(cdataEnd, from: i + 9) else { break }
                add(i, end, depth: stack.count)
                i = end + 3
            } else if next == Ch.question {
                guard let end = find(piEnd, from: i + 2) else { break }
                i = end + 2
            } else if next == Ch.bang {
                // DOCTYPE: its internal subset (in brackets) folds up to the `]`.
                var j = i + 2, depth = 0, quote: UInt16 = 0
                var subsetEnd: Int?
                while j < n {
                    let c = s[j]
                    if quote != 0 {
                        if c == quote { quote = 0 }
                    } else if c == Ch.lt, matches(xmlCommentStart, j) {
                        j = (find(xmlCommentEnd, from: j + 4) ?? n) + 3
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
                add(i, subsetEnd ?? j, depth: stack.count)
                i = j + 1
            } else if next == Ch.slash {
                let closing = name(at: i + 2)
                let length = closing.count
                if let index = stack.lastIndex(where: { open in
                    open.name.count == length && !zip(open.name, closing).contains { s[$0] != s[$1] }
                }) {
                    let start = stack[index].start
                    stack.removeSubrange(index...)
                    add(start, i, depth: index)
                }
                i = tagEnd(from: closing.upperBound) + 1
            } else if Ch.isAlpha(next) || next == Ch.underscore || next == Ch.colon || next >= 0x80 {
                let end = tagEnd(from: i + 1)
                if end < n, s[end - 1] == Ch.slash {
                    add(i, end - 1, depth: stack.count) // a self-closing tag written over several lines
                } else {
                    stack.append((i, name(at: i + 1)))
                }
                i = end + 1
            } else {
                i += 1
            }
        }
        return regions
    }

    private static let xmlCommentStart = u16("<!--")
    private static let xmlCommentEnd = u16("-->")
    private static let cdataStart = u16("<![CDATA[")
    private static let cdataEnd = u16("]]>")
    private static let piEnd = u16("?>")

    // MARK: Indentation

    private static func indentationRegions(_ s: [UInt16], isYAML: Bool) -> [FoldRegion] {
        struct Line { var start: Int; var end: Int; var indent: Int; var blank: Bool }
        var lines: [Line] = []
        var start = 0
        let n = s.count
        var i = 0
        while i <= n {
            if i == n || s[i] == Ch.newline {
                var indent = 0
                var k = start
                while k < i, s[k] == Ch.space || s[k] == Ch.tab {
                    indent += s[k] == Ch.tab ? 4 : 1
                    k += 1
                }
                var blank = k >= i || s[k] == Ch.cr
                if !blank, s[k] == Ch.hash { blank = true } // comments don't shape the structure
                if isYAML, !blank, k + 2 < i, s[k] == Ch.minus, s[k + 1] == Ch.minus, s[k + 2] == Ch.minus { blank = true }
                lines.append(Line(start: start, end: i, indent: indent, blank: blank))
                start = i + 1
            }
            i += 1
        }

        var regions: [FoldRegion] = []
        var stack: [(line: Int, indent: Int)] = []
        var lastContent = -1
        func close(upTo indent: Int?) {
            while let top = stack.last, indent == nil || top.indent >= indent! {
                stack.removeLast()
                if lastContent > top.line {
                    regions.append(FoldRegion(hiddenStart: lines[top.line].end, hiddenEnd: lines[lastContent].end, depth: stack.count))
                }
            }
        }
        for (index, line) in lines.enumerated() where !line.blank {
            close(upTo: line.indent)
            stack.append((index, line.indent))
            lastContent = index
        }
        close(upTo: nil)
        return regions.filter { $0.hiddenEnd > $0.hiddenStart }
    }

    // MARK: Markdown headings

    private static func headingRegions(_ s: [UInt16]) -> [FoldRegion] {
        struct Heading { var line: Int; var level: Int }
        var lineEnds: [Int] = []
        var headings: [Heading] = []
        var nonBlank: [Bool] = []
        var fence: UInt16 = 0
        var start = 0
        let n = s.count
        var i = 0
        while i <= n {
            if i == n || s[i] == Ch.newline {
                var k = start
                while k < i, s[k] == Ch.space { k += 1 }
                let lineIndex = lineEnds.count
                nonBlank.append(k < i && s[k] != Ch.cr)
                if k + 2 < i, (s[k] == Ch.backtick || s[k] == Ch.tilde), s[k + 1] == s[k], s[k + 2] == s[k] {
                    fence = fence == 0 ? s[k] : (fence == s[k] ? 0 : fence)
                } else if fence == 0, k < i, s[k] == Ch.hash {
                    var level = 0
                    while k + level < i, s[k + level] == Ch.hash { level += 1 }
                    if level <= 6, k + level == i || s[k + level] == Ch.space || s[k + level] == Ch.tab {
                        headings.append(Heading(line: lineIndex, level: level))
                    }
                }
                lineEnds.append(i)
                start = i + 1
            }
            i += 1
        }
        var regions: [FoldRegion] = []
        for (index, heading) in headings.enumerated() {
            var endLine = lineEnds.count - 1
            if let next = headings[(index + 1)...].first(where: { $0.level <= heading.level }) {
                endLine = next.line - 1
            }
            while endLine > heading.line, !nonBlank[endLine] { endLine -= 1 }
            if endLine > heading.line {
                regions.append(FoldRegion(hiddenStart: lineEnds[heading.line], hiddenEnd: lineEnds[endLine], depth: heading.level - 1))
            }
        }
        return regions
    }
}

/// Folded ranges of a document, kept in sync with edits.
public struct FoldState: Sendable {
    /// Hidden ranges of every folded region (may nest), sorted by location (outermost first).
    public private(set) var folded: [NSRange] = []
    /// Outermost hidden ranges, sorted — what actually disappears from the layout.
    public private(set) var effective: [NSRange] = []

    public init() {}

    public var isEmpty: Bool { folded.isEmpty }

    public func isFolded(_ range: NSRange) -> Bool { index(of: range) != nil }

    public mutating func fold(_ range: NSRange) {
        guard range.length > 0, index(of: range) == nil else { return }
        folded.insert(range, at: insertionIndex(for: range))
        recompute()
    }

    /// Folds many ranges at once (Fold All).
    public mutating func fold(contentsOf ranges: [NSRange]) {
        folded.append(contentsOf: ranges.filter { $0.length > 0 })
        folded.sort(by: Self.precedes)
        // Drop duplicates (equal ranges are adjacent once sorted).
        var unique: [NSRange] = []
        unique.reserveCapacity(folded.count)
        for range in folded where unique.last != range { unique.append(range) }
        folded = unique
        recompute()
    }

    public mutating func unfold(_ range: NSRange) {
        guard let index = index(of: range) else { return }
        folded.remove(at: index)
        recompute()
    }

    /// Unfolds every fold that hides part of `range` (find results, go to line…).
    @discardableResult
    public mutating func unfold(containing range: NSRange) -> Bool {
        let before = folded.count
        let start = range.location, end = NSMaxRange(range)
        folded.removeAll { fold in
            let foldEnd = NSMaxRange(fold)
            // Positions strictly inside the fold are hidden; its first character (the line feed) is not shown either.
            return (start > fold.location && start < foldEnd) || (end > fold.location + 1 && start < foldEnd && end > start)
        }
        guard folded.count != before else { return false }
        recompute()
        return true
    }

    public mutating func unfoldAll() {
        folded.removeAll()
        effective.removeAll()
    }

    /// Shifts folds after an edit; folds touching the edited text are dropped.
    /// - Returns: the dropped folds (in pre-edit coordinates).
    @discardableResult
    public mutating func applyEdit(editedRange: NSRange, changeInLength delta: Int) -> [NSRange] {
        guard !folded.isEmpty else { return [] }
        let editStart = editedRange.location
        let oldEditEnd = NSMaxRange(editedRange) - delta
        var removed: [NSRange] = []
        // Folds before the edit stay put and the ones after it all move by `delta`, so the order holds.
        folded = folded.compactMap { fold in
            if NSMaxRange(fold) <= editStart { return fold }
            if fold.location >= oldEditEnd { return NSRange(location: fold.location + delta, length: fold.length) }
            removed.append(fold)
            return nil
        }
        recompute()
        return removed
    }

    /// The effective fold strictly containing `location` (not at its first position), if any.
    public func hiddenRange(containing location: Int) -> NSRange? {
        guard let index = Self.lastIndex(in: effective, atOrBefore: location) else { return nil }
        let range = effective[index]
        return location > range.location && location < NSMaxRange(range) ? range : nil
    }

    /// Binary search: index of the last range whose location is <= `location`.
    public static func lastIndex(in ranges: [NSRange], atOrBefore location: Int) -> Int? {
        var lo = 0, hi = ranges.count - 1
        var found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if ranges[mid].location <= location {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found
    }

    /// Sort order of `folded`: by location, longer (outer) ranges first.
    private static func precedes(_ a: NSRange, _ b: NSRange) -> Bool {
        a.location == b.location ? a.length > b.length : a.location < b.location
    }

    private func insertionIndex(for range: NSRange) -> Int {
        var lo = 0, hi = folded.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Self.precedes(folded[mid], range) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func index(of range: NSRange) -> Int? {
        let index = insertionIndex(for: range)
        return index < folded.count && folded[index] == range ? index : nil
    }

    private mutating func recompute() {
        var result: [NSRange] = []
        for range in folded {
            if let last = result.last, range.location < NSMaxRange(last) { continue } // nested or overlapping
            result.append(range)
        }
        effective = result
    }
}

public extension Array where Element == FoldRegion {
    /// Region whose first line ends at `lineEnd` (binary search; the array is sorted by `hiddenStart`).
    func region(startingAtLineEnd lineEnd: Int) -> FoldRegion? {
        var lo = 0, hi = count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let value = self[mid].hiddenStart
            if value == lineEnd { return self[mid] }
            if value < lineEnd { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// Shifts regions after an edit and drops those touching it (they come back on the next analysis).
    mutating func applyEdit(editedRange: NSRange, changeInLength delta: Int) {
        guard !isEmpty else { return }
        let editStart = editedRange.location
        let oldEditEnd = NSMaxRange(editedRange) - delta
        self = compactMap { region in
            if region.hiddenEnd <= editStart { return region }
            if region.hiddenStart >= oldEditEnd {
                return FoldRegion(hiddenStart: region.hiddenStart + delta, hiddenEnd: region.hiddenEnd + delta, depth: region.depth)
            }
            return nil
        }
    }
}
