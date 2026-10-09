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

/// Finds foldable regions: bracket pairs for JSON and C-like languages, indentation blocks for
/// YAML and Python, and heading sections for Markdown.
public enum FoldingAnalyzer {
    enum Strategy {
        case brackets(BracketSyntax)
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
    /// Hidden ranges of every folded region (may nest).
    public private(set) var folded: [NSRange] = []

    public init() {}

    public var isEmpty: Bool { folded.isEmpty }

    /// Outermost hidden ranges, sorted — what actually disappears from the layout.
    public var effective: [NSRange] {
        let sorted = folded.sorted { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }
        var result: [NSRange] = []
        for range in sorted {
            if let last = result.last, NSMaxRange(range) <= NSMaxRange(last), range.location >= last.location { continue }
            result.append(range)
        }
        return result
    }

    public func isFolded(_ range: NSRange) -> Bool { folded.contains(range) }

    public mutating func fold(_ range: NSRange) {
        guard range.length > 0, !folded.contains(range) else { return }
        folded.append(range)
    }

    public mutating func unfold(_ range: NSRange) {
        folded.removeAll { $0 == range }
    }

    /// Unfolds everything hiding any part of `range` (for find results, go-to-line...).
    @discardableResult
    public mutating func unfold(containing range: NSRange) -> Bool {
        let before = folded.count
        folded.removeAll { fold in
            let end = NSMaxRange(fold)
            return range.location > fold.location && range.location < end || (range.length > 0 && NSIntersectionRange(fold, range).length > 0 && NSMaxRange(range) > fold.location + 1)
        }
        return folded.count != before
    }

    public mutating func unfoldAll() { folded.removeAll() }

    /// Shifts folds after an edit; folds touching the edited text are dropped.
    /// - Returns: the folds that were removed.
    @discardableResult
    public mutating func applyEdit(editedRange: NSRange, changeInLength delta: Int) -> [NSRange] {
        guard !folded.isEmpty else { return [] }
        let editStart = editedRange.location
        let oldEditEnd = NSMaxRange(editedRange) - delta
        var removed: [NSRange] = []
        folded = folded.compactMap { fold in
            let end = NSMaxRange(fold)
            if end <= editStart { return fold }            // entirely before the edit
            if fold.location >= oldEditEnd { return NSRange(location: fold.location + delta, length: fold.length) } // after
            removed.append(fold)
            return nil
        }
        return removed
    }

    /// The effective fold strictly containing `location` (not at its edges), if any.
    public func hiddenRange(containing location: Int) -> NSRange? {
        effective.first { location > $0.location && location < NSMaxRange($0) }
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
