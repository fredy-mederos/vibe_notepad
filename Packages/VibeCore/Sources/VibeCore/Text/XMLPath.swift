import Foundation

/// Where a position is in an XML document: the elements around it, from the root down, and the
/// attribute it's in, as an XPath such as `/project/dependencies/dependency[3]/version`.
public struct XMLPath: Equatable, Sendable {
    public struct Element: Equatable, Sendable {
        public var name: String
        /// Its place among its parent's children of the same name (1-based), when there are several.
        public var index: Int?
        /// Where its start tag begins (UTF-16 offset).
        public var start: Int

        /// `name`, or `name[index]`.
        public var step: String { index.map { "\(name)[\($0)]" } ?? name }
    }

    public var elements: [Element]
    /// The attribute the position is in (on its name or value), if any.
    public var attribute: String?
    /// The innermost element, from its start tag through its end tag (nil when it's never closed).
    public var elementRange: NSRange?

    public var xpath: String {
        "/" + elements.map(\.step).joined(separator: "/") + (attribute.map { "/@" + $0 } ?? "")
    }

    /// The path at `location` (a UTF-16 offset: the caret), or nil outside the root element.
    public static func at(_ location: Int, in text: NSString) -> XMLPath? {
        at(location, scanner: XMLTagScanner(text))
    }

    static func at(_ location: Int, scanner: XMLTagScanner) -> XMLPath? {
        let c = location
        // 1. The elements open at the caret, and where to look on from.
        var open: [(name: Range<Int>, start: Int)] = []
        var tagAtCaret: Range<Int>?
        var innermostEnd: Int?
        var resume = scanner.s.count
        scanner.scan { markup, range in
            guard range.lowerBound < c else {
                resume = range.lowerBound
                return false
            }
            let inside = c < range.upperBound
            resume = range.upperBound
            switch markup {
            case .startTag(let name, let selfClosing):
                if selfClosing {
                    guard inside else { break }
                    open.append((name, range.lowerBound)) // in an element without content
                    innermostEnd = range.upperBound
                } else {
                    open.append((name, range.lowerBound))
                }
                if inside { tagAtCaret = range }
            case .endTag(let name):
                if inside {
                    resume = range.lowerBound // still in the element: its end tag is read below
                } else if let index = open.lastIndex(where: { scanner.sameName($0.name, name) }) {
                    open.removeSubrange(index...)
                }
            default:
                break
            }
            return !inside
        }
        guard !open.isEmpty else { return nil }
        let ancestors = open
        let count = ancestors.count

        // 2. Siblings of the same name before each of them.
        var before = [Int](repeating: 0, count: count)
        var stack: [(name: Range<Int>, start: Int)] = []
        let last = ancestors[count - 1].start
        scanner.scan { markup, range in
            guard range.lowerBound < last else { return false }
            switch markup {
            case .startTag(let name, let selfClosing):
                let depth = stack.count
                if depth < count, range.lowerBound < ancestors[depth].start,
                   depth == 0 || stack[depth - 1].start == ancestors[depth - 1].start,
                   scanner.sameName(name, ancestors[depth].name) {
                    before[depth] += 1
                }
                if !selfClosing { stack.append((name, range.lowerBound)) }
            case .endTag(let name):
                if let index = stack.lastIndex(where: { scanner.sameName($0.name, name) }) { stack.removeSubrange(index...) }
            default:
                break
            }
            return true
        }

        // 3. Siblings of the same name after them (the root is the only one of its kind), and where
        // the innermost one ends. Stops once that's all known: usually right after the caret.
        var after = [Bool](repeating: false, count: count)
        var undecided = Set(1..<count)
        stack = innermostEnd == nil ? ancestors : Array(ancestors.dropLast())
        var openAncestors = stack.count // ancestors still open (at the bottom of the stack)
        scanner.scan(from: resume) { markup, range in
            switch markup {
            case .startTag(let name, let selfClosing):
                let depth = stack.count
                if depth > 0, depth < count, depth <= openAncestors, !after[depth],
                   stack[depth - 1].start == ancestors[depth - 1].start, scanner.sameName(name, ancestors[depth].name) {
                    after[depth] = true
                    undecided.remove(depth)
                }
                if !selfClosing { stack.append((name, range.lowerBound)) }
            case .endTag(let name):
                if let index = stack.lastIndex(where: { scanner.sameName($0.name, name) }) {
                    for level in index..<max(index, openAncestors) {
                        undecided.remove(level + 1) // no more siblings once the parent closes
                        if level == count - 1 { innermostEnd = range.upperBound }
                    }
                    openAncestors = min(openAncestors, index)
                    stack.removeSubrange(index...)
                }
            default:
                break
            }
            return !undecided.isEmpty || innermostEnd == nil
        }

        let elements = ancestors.indices.map { level in
            Element(name: scanner.string(ancestors[level].name),
                    index: before[level] > 0 || after[level] ? before[level] + 1 : nil,
                    start: ancestors[level].start)
        }
        return XMLPath(elements: elements, attribute: tagAtCaret.flatMap { attribute(at: c, in: $0, scanner: scanner) },
                       elementRange: innermostEnd.map { NSRange(location: ancestors[count - 1].start, length: $0 - ancestors[count - 1].start) })
    }

    /// The attribute whose name or value holds `c` in the start tag at `tag`.
    private static func attribute(at c: Int, in tag: Range<Int>, scanner: XMLTagScanner) -> String? {
        let s = scanner.s
        let stop = tag.upperBound - 1
        var i = scanner.name(at: tag.lowerBound + 1).upperBound
        while i < stop {
            while i < stop, scanner.isSpace(s[i]) { i += 1 }
            let nameStart = i
            while i < stop, !scanner.isSpace(s[i]), s[i] != Ch.equals, s[i] != Ch.slash { i += 1 }
            guard i > nameStart else {
                i += 1
                continue
            }
            let nameEnd = i
            while i < stop, scanner.isSpace(s[i]) { i += 1 }
            if i < stop, s[i] == Ch.equals {
                i += 1
                while i < stop, scanner.isSpace(s[i]) { i += 1 }
                if i < stop, s[i] == Ch.quote || s[i] == Ch.apostrophe {
                    let quote = s[i]
                    i += 1
                    while i < stop, s[i] != quote { i += 1 }
                    i = min(i + 1, stop)
                } else {
                    while i < stop, !scanner.isSpace(s[i]) { i += 1 }
                }
            } else {
                i = nameEnd
            }
            if c >= nameStart, c <= i { return scanner.string(nameStart..<nameEnd) }
        }
        return nil
    }
}
