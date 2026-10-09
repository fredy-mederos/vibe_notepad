import Foundation

// MARK: - Inline tree

enum MDInlineKind: UInt8 {
    case root
    case text
    /// A run of `*`, `_` or `~` that was not (fully) used for emphasis: `start` = character, `end` = count.
    case delimiter
    case softBreak
    case hardBreak
    case code
    case html
    case entity
    case emphasis
    case strong
    case strikethrough
    case link
    case image
    case autolink
    case footnoteReference
}

/// A node in the inline arena. Leaves reference `start..<end` of the parser's source bytes.
struct MDInlineNode {
    var kind: MDInlineKind
    var start: Int
    var end: Int
    /// link/image/autolink: index into `links`; footnoteReference: index into `footnoteLabels`.
    var payload: Int
    var parent = -1
    var firstChild = -1
    var lastChild = -1
    var prev = -1
    var next = -1
}

/// Destination (normalized and sanitized) and optional title of a link, image or autolink.
struct MDInlineLink {
    var destination: [UInt8]
    var title: [UInt8]?
}

/// Entry of the emphasis delimiter stack (an array-backed doubly linked list).
struct MDDelimiter {
    var node: Int
    var char: UInt8
    var count: Int
    var originalCount: Int
    var canOpen: Bool
    var canClose: Bool
    var prev: Int
    var next: Int
}

/// Entry of the `[` / `![` bracket stack.
struct MDBracket {
    var node: Int
    /// Index of the `[`.
    var position: Int
    var isImage: Bool
    var active: Bool
    var bracketAfter: Bool
    var previousDelimiter: Int
}

// MARK: - Parser

/// CommonMark inline parser (delimiter-stack algorithm) with GFM strikethrough, extended autolinks
/// and footnote references. Reusable: storage is kept between `parse` calls.
struct MDInlineParser {
    let references: [String: MDLinkReference]
    let footnotes: [String: MDBlock]

    private(set) var src: [UInt8] = []
    private(set) var nodes: [MDInlineNode] = []
    private(set) var links: [MDInlineLink] = []
    private(set) var footnoteLabels: [String] = []

    private var pos = 0
    private var lo = 0
    private var end = 0
    private var delimiters: [MDDelimiter] = []
    private var delimiterTop = -1
    private var brackets: [MDBracket] = []
    private var openersBottom: [Int] = []
    private var hasAt = false

    // Caches against quadratic rescans of unterminated constructs.
    private var htmlCache = MDHTMLScanCache()
    private var titleQuoteFailFrom = Int.max
    private var titleApostropheFailFrom = Int.max
    private var backtickScanned = false
    private var backtickLastPosition: [Int] = []
    private var backtickLastGeneration: [Int] = []
    private var generation = 0

    init(references: [String: MDLinkReference], footnotes: [String: MDBlock]) {
        self.references = references
        self.footnotes = footnotes
    }

    /// Parses `text[lo..<hi]` and returns the index of the root node.
    mutating func parse(_ text: [UInt8], _ lo: Int, _ hi: Int) -> Int {
        src = text
        self.lo = lo
        pos = lo
        end = max(lo, min(hi, text.count))
        nodes.removeAll(keepingCapacity: true)
        links.removeAll(keepingCapacity: true)
        footnoteLabels.removeAll(keepingCapacity: true)
        delimiters.removeAll(keepingCapacity: true)
        brackets.removeAll(keepingCapacity: true)
        delimiterTop = -1
        htmlCache = MDHTMLScanCache()
        titleQuoteFailFrom = Int.max
        titleApostropheFailFrom = Int.max
        backtickScanned = false
        generation += 1
        hasAt = src[self.lo..<end].contains(MDByte.at)

        nodes.append(MDInlineNode(kind: .root, start: lo, end: end, payload: -1))
        while pos < end {
            switch src[pos] {
            case MDByte.newline: parseNewline()
            case MDByte.backslash: parseBackslash()
            case MDByte.backtick: parseBackticks()
            case MDByte.asterisk, MDByte.underscore, MDByte.tilde: parseDelimiterRun()
            case MDByte.leftBracket: parseOpenBracket(isImage: false)
            case MDByte.bang:
                if pos + 1 < end && src[pos + 1] == MDByte.leftBracket {
                    parseOpenBracket(isImage: true)
                } else {
                    parseText()
                }
            case MDByte.rightBracket: parseCloseBracket()
            case MDByte.lessThan: parseLessThan()
            case MDByte.ampersand: parseAmpersand()
            default: parseText()
            }
        }
        processEmphasis(stackBottom: -1)
        return 0
    }

    // MARK: Tree operations

    @discardableResult
    private mutating func append(_ kind: MDInlineKind, _ start: Int = 0, _ end: Int = 0, payload: Int = -1) -> Int {
        let node = newNode(kind, start, end, payload: payload)
        appendChild(0, node)
        return node
    }

    private mutating func newNode(_ kind: MDInlineKind, _ start: Int = 0, _ end: Int = 0, payload: Int = -1) -> Int {
        nodes.append(MDInlineNode(kind: kind, start: start, end: end, payload: payload))
        return nodes.count - 1
    }

    private mutating func appendChild(_ parent: Int, _ child: Int) {
        let last = nodes[parent].lastChild
        nodes[child].parent = parent
        nodes[child].prev = last
        nodes[child].next = -1
        if last == -1 {
            nodes[parent].firstChild = child
        } else {
            nodes[last].next = child
        }
        nodes[parent].lastChild = child
    }

    private mutating func unlink(_ node: Int) {
        let n = nodes[node]
        if n.prev != -1 {
            nodes[n.prev].next = n.next
        } else if n.parent != -1 {
            nodes[n.parent].firstChild = n.next
        }
        if n.next != -1 {
            nodes[n.next].prev = n.prev
        } else if n.parent != -1 {
            nodes[n.parent].lastChild = n.prev
        }
        nodes[node].parent = -1
        nodes[node].prev = -1
        nodes[node].next = -1
    }

    private mutating func insertAfter(_ node: Int, _ sibling: Int) {
        let next = nodes[node].next
        let parent = nodes[node].parent
        nodes[sibling].parent = parent
        nodes[sibling].prev = node
        nodes[sibling].next = next
        nodes[node].next = sibling
        if next != -1 {
            nodes[next].prev = sibling
        } else if parent != -1 {
            nodes[parent].lastChild = sibling
        }
    }

    private mutating func appendText(_ start: Int, _ stop: Int) {
        if stop > start { append(.text, start, stop) }
    }

    // MARK: Simple constructs

    private mutating func parseText() {
        let start = pos
        var i = pos
        let autolinks = brackets.isEmpty
        scan: while i < end {
            let c = src[i]
            switch c {
            case MDByte.newline, MDByte.backslash, MDByte.backtick, MDByte.asterisk, MDByte.underscore, MDByte.tilde,
                 MDByte.leftBracket, MDByte.rightBracket, MDByte.lessThan, MDByte.ampersand:
                break scan
            case MDByte.bang:
                if i + 1 < end && src[i + 1] == MDByte.leftBracket && i > start { break scan }
            case 0x68, 0x77, 0x48, 0x57: // h w H W
                if autolinks && (i == lo || MDAutolink.isURLBoundary(src[i - 1])), let match = MDAutolink.url(src, i, end) {
                    appendText(start, i)
                    appendAutolink(i, match.end, prefix: match.isWWW ? "http://" : nil)
                    pos = match.end
                    return
                }
            default:
                break
            }
            if autolinks && hasAt && MDAutolink.isEmailLocalChar(c) && (i == lo || !MDAutolink.isEmailLocalChar(src[i - 1])),
               let stop = MDAutolink.email(src, i, end) {
                appendText(start, i)
                appendAutolink(i, stop, prefix: "mailto:")
                pos = stop
                return
            }
            i += 1
        }
        if i == start { i += 1 } // a lone "!" not followed by "["
        appendText(start, i)
        pos = i
    }

    private mutating func appendAutolink(_ start: Int, _ stop: Int, prefix: StaticString?) {
        var href: [UInt8] = []
        if let prefix {
            prefix.withUTF8Buffer { href.append(contentsOf: $0) }
        }
        href.append(contentsOf: src[start..<stop])
        links.append(MDInlineLink(destination: MDURL.sanitize(MDURL.normalize(href)), title: nil))
        append(.autolink, start, stop, payload: links.count - 1)
    }

    private mutating func parseNewline() {
        pos += 1
        var hard = false
        let last = nodes[0].lastChild
        if last != -1 && nodes[last].kind == .text {
            let start = nodes[last].start
            var stop = nodes[last].end
            var spaces = 0
            while stop > start && src[stop - 1] == MDByte.space {
                stop -= 1
                spaces += 1
            }
            hard = spaces >= 2
            nodes[last].end = stop
        }
        append(hard ? .hardBreak : .softBreak)
        while pos < end && src[pos] == MDByte.space { pos += 1 }
    }

    private mutating func parseBackslash() {
        let next = pos + 1
        if next < end && src[next] == MDByte.newline {
            pos = next + 1
            append(.hardBreak)
            while pos < end && src[pos] == MDByte.space { pos += 1 }
        } else if next < end && MDChar.isPunctuation(src[next]) {
            appendText(next, next + 1)
            pos = next + 1
        } else {
            appendText(pos, next)
            pos = next
        }
    }

    private mutating func parseAmpersand() {
        if let stop = MDText.entityEnd(src, pos, end) {
            append(.entity, pos, stop)
            pos = stop
        } else {
            appendText(pos, pos + 1)
            pos += 1
        }
    }

    private mutating func parseLessThan() {
        if let auto = MDHTMLScan.autolink(src, pos, end) {
            let contentStart = pos + 1
            let contentEnd = auto.end - 1
            var href: [UInt8] = auto.isEmail ? Array("mailto:".utf8) : []
            href.append(contentsOf: src[contentStart..<contentEnd])
            links.append(MDInlineLink(destination: MDURL.sanitize(MDURL.normalize(href)), title: nil))
            append(.autolink, contentStart, contentEnd, payload: links.count - 1)
            pos = auto.end
        } else if let stop = MDHTMLScan.inlineHTML(src, pos, end, cache: &htmlCache) {
            append(.html, pos, stop)
            pos = stop
        } else {
            appendText(pos, pos + 1)
            pos += 1
        }
    }

    // MARK: Code spans

    private mutating func parseBackticks() {
        let start = pos
        while pos < end && src[pos] == MDByte.backtick { pos += 1 }
        let length = pos - start
        if let close = findClosingBackticks(length, from: pos) {
            append(.code, pos, close)
            pos = close + length
        } else {
            appendText(start, pos)
        }
    }

    /// Start of the next backtick run of exactly `length` at or after `from` (cmark's caching strategy).
    private mutating func findClosingBackticks(_ length: Int, from: Int) -> Int? {
        guard length <= MDLimits.maxBacktickRun else { return nil }
        if backtickLastPosition.isEmpty {
            backtickLastPosition = Array(repeating: -1, count: MDLimits.maxBacktickRun + 1)
            backtickLastGeneration = Array(repeating: 0, count: MDLimits.maxBacktickRun + 1)
        }
        if backtickScanned {
            let last = backtickLastGeneration[length] == generation ? backtickLastPosition[length] : -1
            if last < from { return nil }
        }
        var i = from
        while i < end {
            while i < end && src[i] != MDByte.backtick { i += 1 }
            guard i < end else { break }
            let runStart = i
            while i < end && src[i] == MDByte.backtick { i += 1 }
            let run = i - runStart
            if run <= MDLimits.maxBacktickRun {
                backtickLastPosition[run] = runStart
                backtickLastGeneration[run] = generation
            }
            if run == length { return runStart }
        }
        backtickScanned = true
        return nil
    }

    // MARK: Emphasis delimiters

    private mutating func parseDelimiterRun() {
        let c = src[pos]
        let start = pos
        while pos < end && src[pos] == c { pos += 1 }
        let count = pos - start
        if c == MDByte.tilde && count > 2 {
            appendText(start, pos)
            return
        }
        let before = MDUnicode.classBefore(start, in: src, lo: lo)
        let after = MDUnicode.classAt(pos, in: src, end: end)
        let leftFlanking = after != .whitespace && (after != .punctuation || before != .other)
        let rightFlanking = before != .whitespace && (before != .punctuation || after != .other)
        let canOpen: Bool
        let canClose: Bool
        if c == MDByte.underscore {
            canOpen = leftFlanking && (!rightFlanking || before == .punctuation)
            canClose = rightFlanking && (!leftFlanking || after == .punctuation)
        } else {
            canOpen = leftFlanking
            canClose = rightFlanking
        }
        let node = append(.delimiter, Int(c), count)
        guard canOpen || canClose else { return }
        delimiters.append(MDDelimiter(node: node, char: c, count: count, originalCount: count,
                                      canOpen: canOpen, canClose: canClose, prev: delimiterTop, next: -1))
        let index = delimiters.count - 1
        if delimiterTop != -1 { delimiters[delimiterTop].next = index }
        delimiterTop = index
    }

    private mutating func removeDelimiter(_ d: Int) {
        let prev = delimiters[d].prev
        let next = delimiters[d].next
        if prev != -1 { delimiters[prev].next = next }
        if next == -1 {
            delimiterTop = prev
        } else {
            delimiters[next].prev = prev
        }
    }

    /// The CommonMark "process emphasis" procedure for delimiters above `stackBottom`.
    private mutating func processEmphasis(stackBottom: Int) {
        if openersBottom.count != 14 { openersBottom = Array(repeating: -1, count: 14) }
        for k in 0..<14 { openersBottom[k] = stackBottom }

        var closer = delimiterTop
        while closer != -1 && delimiters[closer].prev != stackBottom {
            closer = delimiters[closer].prev
        }
        while closer != -1 {
            let closing = delimiters[closer]
            guard closing.canClose else {
                closer = closing.next
                continue
            }
            let c = closing.char
            let bottomIndex: Int
            switch c {
            case MDByte.underscore: bottomIndex = (closing.canOpen ? 3 : 0) + closing.originalCount % 3
            case MDByte.asterisk: bottomIndex = 6 + (closing.canOpen ? 3 : 0) + closing.originalCount % 3
            default: bottomIndex = 12 + min(closing.originalCount, 2) - 1
            }
            var opener = closing.prev
            var found = false
            while opener != -1 && opener != stackBottom && opener != openersBottom[bottomIndex] {
                let opening = delimiters[opener]
                if opening.char == c && opening.canOpen {
                    if c == MDByte.tilde {
                        if opening.count == closing.count { found = true; break }
                    } else {
                        let oddMatch = (closing.canOpen || opening.canClose) && closing.originalCount % 3 != 0
                            && (opening.originalCount + closing.originalCount) % 3 == 0
                        if !oddMatch { found = true; break }
                    }
                }
                opener = opening.prev
            }

            guard found else {
                openersBottom[bottomIndex] = closing.prev
                let next = closing.next
                if !closing.canOpen { removeDelimiter(closer) }
                closer = next
                continue
            }

            let used: Int
            if c == MDByte.tilde {
                used = closing.count
            } else {
                used = closing.count >= 2 && delimiters[opener].count >= 2 ? 2 : 1
            }
            let openerNode = delimiters[opener].node
            let closerNode = closing.node
            delimiters[opener].count -= used
            delimiters[closer].count -= used
            nodes[openerNode].end -= used
            nodes[closerNode].end -= used

            let kind: MDInlineKind = c == MDByte.tilde ? .strikethrough : (used == 1 ? .emphasis : .strong)
            let wrapper = newNode(kind)
            var child = nodes[openerNode].next
            while child != -1 && child != closerNode {
                let next = nodes[child].next
                unlink(child)
                appendChild(wrapper, child)
                child = next
            }
            insertAfter(openerNode, wrapper)

            // Delimiters between opener and closer can no longer match.
            delimiters[opener].next = closer
            delimiters[closer].prev = opener

            if delimiters[opener].count == 0 {
                unlink(openerNode)
                removeDelimiter(opener)
            }
            if delimiters[closer].count == 0 {
                unlink(closerNode)
                let next = delimiters[closer].next
                removeDelimiter(closer)
                closer = next
            }
        }
        while delimiterTop != -1 && delimiterTop != stackBottom {
            removeDelimiter(delimiterTop)
        }
    }

    // MARK: Links, images and footnote references

    private mutating func parseOpenBracket(isImage: Bool) {
        let start = pos
        pos += isImage ? 2 : 1
        let node = append(.text, start, pos)
        if brackets.count >= MDLimits.maxBracketDepth {
            // Too many unclosed openers: the oldest one can no longer start a link.
            brackets.removeFirst()
        }
        if !brackets.isEmpty { brackets[brackets.count - 1].bracketAfter = true }
        brackets.append(MDBracket(node: node, position: isImage ? start + 1 : start, isImage: isImage,
                                  active: true, bracketAfter: false, previousDelimiter: delimiterTop))
    }

    private mutating func parseCloseBracket() {
        let closePos = pos
        pos += 1
        let afterClose = pos
        guard let opener = brackets.last else {
            appendText(closePos, afterClose)
            return
        }
        guard opener.active else {
            brackets.removeLast()
            appendText(closePos, afterClose)
            return
        }

        var linkIndex: Int?
        if pos < end && src[pos] == MDByte.leftParen, let inline = parseInlineLinkTail(from: pos + 1) {
            linkIndex = inline.link
            pos = inline.next
        }

        if linkIndex == nil {
            let labelLength = MDLinkScan.label(src, afterClose, end)
            if labelLength == 0, !opener.isImage, !opener.bracketAfter, !footnotes.isEmpty,
               closePos - opener.position > 2, src[opener.position + 1] == MDByte.caret {
                let key = MDLinkScan.normalizeLabel(src, opener.position + 2, closePos)
                if footnotes[key] != nil {
                    insertFootnoteReference(key, opener: opener)
                    return
                }
            }
            var label: Range<Int>?
            if labelLength > 2 {
                label = (afterClose + 1)..<(afterClose + labelLength - 1)
            } else if !opener.bracketAfter {
                label = (opener.position + 1)..<closePos
            }
            if let label, !references.isEmpty {
                let key = MDLinkScan.normalizeLabel(src, label.lowerBound, label.upperBound)
                if let reference = references[key] {
                    links.append(MDInlineLink(destination: reference.destination, title: reference.title))
                    linkIndex = links.count - 1
                    pos = afterClose + labelLength
                }
            }
        }

        guard let linkIndex else {
            brackets.removeLast()
            pos = afterClose
            appendText(closePos, afterClose)
            return
        }

        let link = newNode(opener.isImage ? .image : .link, payload: linkIndex)
        var child = nodes[opener.node].next
        while child != -1 {
            let next = nodes[child].next
            unlink(child)
            appendChild(link, child)
            child = next
        }
        appendChild(0, link)
        processEmphasis(stackBottom: opener.previousDelimiter)
        brackets.removeLast()
        unlink(opener.node)
        if !opener.isImage {
            // No links inside links.
            for k in brackets.indices where !brackets[k].isImage {
                brackets[k].active = false
            }
        }
    }

    /// `(destination "title")` after `]`. Returns the link index and the index after `)`.
    private mutating func parseInlineLinkTail(from start: Int) -> (link: Int, next: Int)? {
        var i = MDLinkScan.skipSpaceAndNewline(src, start, end)
        guard let destination = MDLinkScan.destination(src, i, end) else { return nil }
        i = destination.next
        let beforeTitle = i
        i = MDLinkScan.skipSpaceAndNewline(src, i, end)
        var titleRange: Range<Int>?
        if i > beforeTitle, let title = scanTitle(at: i) {
            titleRange = title.content
            i = MDLinkScan.skipSpaceAndNewline(src, title.next, end)
        }
        guard i < end, src[i] == MDByte.rightParen else { return nil }
        let href = MDText.unescape(src, destination.content.lowerBound, destination.content.upperBound)
        let title = titleRange.map { MDText.unescape(src, $0.lowerBound, $0.upperBound) }
        links.append(MDInlineLink(destination: MDURL.sanitize(MDURL.normalize(href)), title: title))
        return (links.count - 1, i + 1)
    }

    private mutating func scanTitle(at i: Int) -> (content: Range<Int>, next: Int)? {
        guard i < end else { return nil }
        let quote = src[i]
        if quote == MDByte.quote && i >= titleQuoteFailFrom { return nil }
        if quote == MDByte.apostrophe && i >= titleApostropheFailFrom { return nil }
        if let title = MDLinkScan.title(src, i, end) { return title }
        if quote == MDByte.quote {
            titleQuoteFailFrom = min(titleQuoteFailFrom, i)
        } else if quote == MDByte.apostrophe {
            titleApostropheFailFrom = min(titleApostropheFailFrom, i)
        }
        return nil
    }

    private mutating func insertFootnoteReference(_ key: String, opener: MDBracket) {
        var node = opener.node
        while node != -1 {
            let next = nodes[node].next
            unlink(node)
            node = next
        }
        while delimiterTop != -1 && delimiterTop != opener.previousDelimiter {
            removeDelimiter(delimiterTop)
        }
        brackets.removeLast()
        footnoteLabels.append(key)
        append(.footnoteReference, payload: footnoteLabels.count - 1)
    }

    // MARK: Plain text

    /// Text content of the subtree under `root` (entities decoded, markup dropped).
    func plainText(_ root: Int, includeImages: Bool = false) -> String {
        var out: [UInt8] = []
        appendPlainText(root, to: &out, includeImages: includeImages)
        var lo = 0
        var hi = out.count
        while lo < hi && MDChar.isWhitespace(out[lo]) { lo += 1 }
        while hi > lo && MDChar.isWhitespace(out[hi - 1]) { hi -= 1 }
        return String(decoding: out[lo..<hi], as: UTF8.self)
    }

    func appendPlainText(_ root: Int, to out: inout [UInt8], includeImages: Bool) {
        var node = nodes[root].firstChild
        while node != -1 {
            let n = nodes[node]
            var descend = false
            switch n.kind {
            case .text, .autolink:
                out.append(contentsOf: src[n.start..<n.end])
            case .delimiter:
                out.append(contentsOf: repeatElement(UInt8(truncatingIfNeeded: n.start), count: max(n.end, 0)))
            case .code:
                let range = codeSpanContent(n)
                for k in range { out.append(src[k] == MDByte.newline ? MDByte.space : src[k]) }
            case .entity:
                out.append(contentsOf: MDText.decodeEntities(src, n.start, n.end))
            case .softBreak, .hardBreak:
                out.append(MDByte.space)
            case .html, .footnoteReference, .root:
                break
            case .image:
                descend = includeImages
            case .emphasis, .strong, .strikethrough, .link:
                descend = true
            }
            if descend && n.firstChild != -1 {
                node = n.firstChild
            } else {
                node = nextNode(after: node, within: root)
            }
        }
    }

    /// Next node in pre-order that is not a descendant of `node`, staying inside `root`.
    func nextNode(after node: Int, within root: Int) -> Int {
        var current = node
        while current != -1 && current != root {
            let next = nodes[current].next
            if next != -1 { return next }
            current = nodes[current].parent
        }
        return -1
    }

    /// Content range of a code span: one leading and trailing space (or line ending) is stripped
    /// when both are present and the content is not all spaces.
    func codeSpanContent(_ node: MDInlineNode) -> Range<Int> {
        let start = node.start
        let stop = node.end
        guard stop - start >= 2 else { return start..<stop }
        let first = src[start]
        let last = src[stop - 1]
        let firstIsSpace = first == MDByte.space || first == MDByte.newline
        let lastIsSpace = last == MDByte.space || last == MDByte.newline
        guard firstIsSpace && lastIsSpace else { return start..<stop }
        for k in start..<stop where src[k] != MDByte.space && src[k] != MDByte.newline {
            return (start + 1)..<(stop - 1)
        }
        return start..<stop
    }
}
