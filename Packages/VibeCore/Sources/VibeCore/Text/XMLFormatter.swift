import Foundation

// MARK: XML

extension TextTransforms {
    public enum XMLFormatError: Error, LocalizedError, Equatable {
        case invalid(line: Int, message: String)
        public var errorDescription: String? {
            if case .invalid(let line, let message) = self { return "Invalid XML (line \(line)): \(message)" }
            return nil
        }
    }

    /// Pretty-prints XML, one element per line indented by nesting. Only whitespace between tags
    /// changes: attributes keep their order and quotes, comments, CDATA and the prolog stay as written,
    /// and an element holding text (or marked `xml:space="preserve"`) keeps its content as is.
    /// A selection of several elements (a fragment) is formatted too.
    public static func formatXML(_ source: String, indent: String = "  ") throws -> String {
        let xml = XMLMarkup(source)
        try xml.validate()
        return xml.render(indent: indent)
    }

    /// Drops the whitespace between tags; text, comments and CDATA are kept.
    public static func minifyXML(_ source: String) throws -> String {
        let xml = XMLMarkup(source)
        try xml.validate()
        return xml.render(indent: nil)
    }
}

/// XML split into tags, text and other markup (comments, CDATA, processing instructions, DOCTYPE),
/// working on UTF-8 bytes: every delimiter is ASCII, so slices never split a character.
struct XMLMarkup {
    enum Kind { case text, start, selfClosing, end, comment, cdata, instruction, declaration }

    struct Token {
        var kind: Kind
        var range: Range<Int>
        /// The closing delimiter is missing (a comment or tag that runs to the end of the text).
        var unterminated = false
    }

    /// How an element's content is written.
    enum Content {
        /// Child elements (and comments) only: one per line, indented.
        case block
        /// Nothing but whitespace with line breaks, or nothing at all: `<a></a>`.
        case empty
        /// Text, CDATA, `xml:space="preserve"` or a few spaces: kept exactly as written.
        case verbatim
    }

    let bytes: [UInt8]
    let tokens: [Token]

    init(_ source: String) {
        bytes = Array(source.utf8)
        tokens = Self.tokenize(bytes)
    }

    // MARK: Tokens

    private static func tokenize(_ b: [UInt8]) -> [Token] {
        var tokens: [Token] = []
        tokens.reserveCapacity(b.count / 16)
        let n = b.count
        var i = 0

        func has(_ literal: StaticString, at index: Int) -> Bool {
            let count = literal.utf8CodeUnitCount
            guard index + count <= n else { return false }
            let pointer = literal.utf8Start
            for k in 0..<count where b[index + k] != pointer[k] { return false }
            return true
        }
        /// The index just past `literal`, searching from `index` (nil when it never comes).
        func end(of literal: StaticString, from index: Int) -> Int? {
            var j = index
            while j < n {
                if b[j] == literal.utf8Start[0], has(literal, at: j) { return j + literal.utf8CodeUnitCount }
                j += 1
            }
            return nil
        }
        func append(_ kind: Kind, _ start: Int, _ stop: Int?) {
            tokens.append(Token(kind: kind, range: start..<(stop ?? n), unterminated: stop == nil))
            i = stop ?? n
        }

        while i < n {
            guard b[i] == Byte.lt else {
                var j = i
                while j < n, b[j] != Byte.lt { j += 1 }
                tokens.append(Token(kind: .text, range: i..<j))
                i = j
                continue
            }
            let next = i + 1 < n ? b[i + 1] : 0
            if has("<!--", at: i) {
                append(.comment, i, end(of: "-->", from: i + 4))
            } else if has("<![CDATA[", at: i) {
                append(.cdata, i, end(of: "]]>", from: i + 9))
            } else if next == Byte.question {
                append(.instruction, i, end(of: "?>", from: i + 2))
            } else if next == Byte.bang {
                // DOCTYPE, whose internal subset (in brackets) holds declarations and comments of its own.
                var j = i + 2, depth = 0, quote: UInt8 = 0
                var stop: Int?
                while j < n {
                    let c = b[j]
                    if quote != 0 {
                        if c == quote { quote = 0 }
                    } else if c == Byte.lt, has("<!--", at: j) {
                        guard let after = end(of: "-->", from: j + 4) else { break }
                        j = after
                        continue
                    } else if c == Byte.quote || c == Byte.apostrophe {
                        quote = c
                    } else if c == Byte.lbracket {
                        depth += 1
                    } else if c == Byte.rbracket {
                        depth -= 1
                    } else if c == Byte.gt, depth <= 0 {
                        stop = j + 1
                        break
                    }
                    j += 1
                }
                append(.declaration, i, stop)
            } else if next == Byte.slash {
                var j = i + 2
                while j < n, b[j] != Byte.gt { j += 1 }
                append(.end, i, j < n ? j + 1 : nil)
            } else if isNameStart(next) {
                var j = i + 1, quote: UInt8 = 0
                while j < n {
                    let c = b[j]
                    if quote != 0 {
                        if c == quote { quote = 0 }
                    } else if c == Byte.quote || c == Byte.apostrophe {
                        quote = c
                    } else if c == Byte.gt {
                        break
                    }
                    j += 1
                }
                append(j < n && b[j - 1] == Byte.slash ? .selfClosing : .start, i, j < n ? j + 1 : nil)
            } else {
                // A stray "<" is text (the parser reports it).
                tokens.append(Token(kind: .text, range: i..<(i + 1)))
                i += 1
            }
        }
        return tokens
    }

    private static func isNameStart(_ c: UInt8) -> Bool {
        let lower = c | 0x20
        return (lower >= 0x61 && lower <= 0x7A) || c == Byte.underscore || c == Byte.colon || c >= 0x80
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == Byte.space || c == Byte.newline || c == Byte.tab || c == Byte.cr
    }

    private func isBlank(_ token: Token) -> Bool {
        bytes[token.range].allSatisfy(Self.isSpace)
    }

    /// The tag's name: `<name …>`, `</name>`.
    private func name(of token: Token) -> ArraySlice<UInt8> {
        var start = token.range.lowerBound + 1
        if token.kind == .end { start += 1 }
        var stop = start
        while stop < token.range.upperBound, !Self.isSpace(bytes[stop]), bytes[stop] != Byte.gt, bytes[stop] != Byte.slash { stop += 1 }
        return bytes[start..<stop]
    }

    private func line(at offset: Int) -> Int {
        bytes[..<offset].reduce(1) { $0 + ($1 == Byte.newline ? 1 : 0) }
    }

    // MARK: Validation

    /// Checks the nesting here (for messages that name both tags) and everything else with the system
    /// XML parser. A fragment (several top-level elements, or text beside them) is checked inside a
    /// wrapper element.
    func validate() throws {
        var open: [Int] = []
        var topLevelElements = 0
        var topLevelText = false
        for (index, token) in tokens.enumerated() {
            if token.unterminated {
                let what = switch token.kind {
                case .comment: "the comment never ends (-->)"
                case .cdata: "the CDATA section never ends (]]>)"
                case .instruction: "the processing instruction never ends (?>)"
                case .declaration: "the declaration never ends (>)"
                default: "the tag never ends (>)"
                }
                throw TextTransforms.XMLFormatError.invalid(line: line(at: token.range.lowerBound), message: what)
            }
            switch token.kind {
            case .start:
                if open.isEmpty { topLevelElements += 1 }
                open.append(index)
            case .selfClosing:
                if open.isEmpty { topLevelElements += 1 }
            case .end:
                let closing = String(decoding: name(of: token), as: UTF8.self)
                guard let last = open.popLast() else {
                    throw TextTransforms.XMLFormatError.invalid(line: line(at: token.range.lowerBound),
                                                                message: "</\(closing)> has no start tag")
                }
                let opening = String(decoding: name(of: tokens[last]), as: UTF8.self)
                if opening != closing {
                    throw TextTransforms.XMLFormatError.invalid(
                        line: line(at: token.range.lowerBound),
                        message: "</\(closing)> doesn’t match <\(opening)> on line \(line(at: tokens[last].range.lowerBound))")
                }
            case .text, .cdata:
                if open.isEmpty, token.kind == .cdata || !isBlank(token) { topLevelText = true }
            default:
                break
            }
        }
        if let last = open.last {
            throw TextTransforms.XMLFormatError.invalid(line: line(at: tokens[last].range.lowerBound),
                                                        message: "<\(String(decoding: name(of: tokens[last]), as: UTF8.self))> is never closed")
        }

        var data = bytes
        // The parser gets UTF-8 whatever the declaration says, so blank the declaration out
        // (spaces keep the line and column numbers).
        if let first = tokens.first(where: { $0.kind != .text || !isBlank($0) }), first.kind == .instruction,
           bytes[first.range].starts(with: Array("<?xml".utf8)), first.range.count > 5, Self.isSpace(bytes[first.range.lowerBound + 5]) {
            for k in first.range where data[k] != Byte.newline { data[k] = Byte.space }
        }
        let isFragment = topLevelElements != 1 || topLevelText
        if isFragment {
            data = Array("<fragment>".utf8) + data + Array("</fragment>".utf8)
        }
        let parser = XMLParser(data: Data(data))
        let catcher = XMLErrorCatcher()
        parser.delegate = catcher
        parser.shouldResolveExternalEntities = false
        guard !parser.parse() else { return }
        let message = catcher.message ?? (parser.parserError as NSError?)?.localizedDescription ?? "the parser stopped"
        throw TextTransforms.XMLFormatError.invalid(line: max(1, catcher.line ?? parser.lineNumber), message: message)
    }

    // MARK: Rendering

    /// For each start tag (by token index): how its content is written, and the index of its end tag
    /// (-1 for other tokens).
    private func structure() -> (content: [Content], end: [Int]) {
        struct Frame {
            var start: Int
            var hasText = false
            var hasChildren = false
            var hasSpacesOnly = false
        }
        var content = [Content](repeating: .verbatim, count: tokens.count)
        var end = [Int](repeating: -1, count: tokens.count)
        var stack: [Frame] = []
        for (index, token) in tokens.enumerated() {
            switch token.kind {
            case .start:
                stack.append(Frame(start: index))
            case .end:
                guard let frame = stack.popLast() else { continue }
                end[frame.start] = index
                content[frame.start] = if frame.hasText || preservesSpace(tokens[frame.start]) {
                    .verbatim
                } else if frame.hasChildren {
                    .block
                } else {
                    frame.hasSpacesOnly ? .verbatim : .empty
                }
                if !stack.isEmpty { stack[stack.count - 1].hasChildren = true }
            case .text:
                guard !stack.isEmpty else { continue }
                if !isBlank(token) {
                    stack[stack.count - 1].hasText = true
                } else if !bytes[token.range].contains(Byte.newline) {
                    stack[stack.count - 1].hasSpacesOnly = true
                }
            case .cdata:
                if !stack.isEmpty { stack[stack.count - 1].hasText = true }
            default:
                if !stack.isEmpty { stack[stack.count - 1].hasChildren = true }
            }
        }
        return (content, end)
    }

    /// `xml:space="preserve"` on a start tag.
    private func preservesSpace(_ token: Token) -> Bool {
        func matches(_ literal: [UInt8], at index: Int) -> Bool {
            index + literal.count <= token.range.upperBound && bytes[index..<(index + literal.count)].elementsEqual(literal)
        }
        var i = token.range.lowerBound
        while i < token.range.upperBound {
            if bytes[i] == Self.xmlSpace[0], matches(Self.xmlSpace, at: i) {
                var j = i + Self.xmlSpace.count
                while j < token.range.upperBound, Self.isSpace(bytes[j]) || bytes[j] == Byte.equals || bytes[j] == Byte.quote || bytes[j] == Byte.apostrophe { j += 1 }
                return matches(Self.preserve, at: j)
            }
            i += 1
        }
        return false
    }

    private static let xmlSpace = Array("xml:space".utf8)
    private static let preserve = Array("preserve".utf8)

    /// The formatted text (`indent` nil: minified).
    func render(indent: String?) -> String {
        let (content, end) = structure()
        let pretty = indent != nil
        let unit = Array((indent ?? "").utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 4)
        var depth = 0
        // Whitespace since the last thing written: its line breaks, and whether there was any.
        var gapLines = 0
        var gapHasSpace = false
        // A start tag was just written: its first child never gets a blank line above it.
        var justOpened = true

        func newline(blankLine: Bool = false) {
            guard pretty, !out.isEmpty else { return }
            out.append(Byte.newline)
            if blankLine { out.append(Byte.newline) }
            for _ in 0..<depth { out.append(contentsOf: unit) }
        }
        /// Puts the next node on a line of its own, keeping one blank line where the source had some.
        func startNode(trailing: Bool = false) {
            if pretty, trailing, gapLines == 0, gapHasSpace, !out.isEmpty {
                out.append(Byte.space) // a comment after something on the same line stays there
            } else {
                newline(blankLine: gapLines >= 2 && !justOpened)
            }
            gapLines = 0
            gapHasSpace = false
            justOpened = false
        }

        var t = 0
        while t < tokens.count {
            let token = tokens[t]
            switch token.kind {
            case .text:
                if isBlank(token) {
                    gapLines += bytes[token.range].reduce(0) { $0 + ($1 == Byte.newline ? 1 : 0) }
                    gapHasSpace = true
                } else {
                    // Text beside elements at the top of a fragment: on a line of its own.
                    startNode()
                    let text = bytes[token.range]
                    let first = text.firstIndex { !Self.isSpace($0) } ?? text.startIndex
                    let last = text.lastIndex { !Self.isSpace($0) } ?? text.startIndex
                    out.append(contentsOf: text[first...last])
                }
            case .start:
                startNode()
                writeTag(token, depth: depth, pretty: pretty, unit: unit, into: &out)
                let close = end[t]
                guard close >= 0 else { break }
                switch content[t] {
                case .block:
                    depth += 1
                    justOpened = true
                case .empty:
                    writeEndTag(tokens[close], into: &out)
                    t = close
                case .verbatim:
                    out.append(contentsOf: bytes[token.range.upperBound..<tokens[close].range.upperBound])
                    t = close
                }
            case .end:
                depth = max(0, depth - 1)
                gapLines = 0
                justOpened = false
                newline()
                writeEndTag(token, into: &out)
            case .selfClosing:
                startNode()
                writeTag(token, depth: depth, pretty: pretty, unit: unit, into: &out)
            case .comment, .declaration:
                startNode(trailing: token.kind == .comment)
                if pretty {
                    writeMoved(token, depth: depth, unit: unit, into: &out)
                } else {
                    out.append(contentsOf: bytes[token.range])
                }
            case .cdata, .instruction:
                startNode()
                out.append(contentsOf: bytes[token.range])
            }
            t += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// A comment or DOCTYPE written over several lines moves with its first line: the indentation it
    /// started with in the source gives way to the new one on each of its lines (a line indented less
    /// loses its indentation). One that followed something else on its line is kept as is.
    private func writeMoved(_ token: Token, depth: Int, unit: [UInt8], into out: inout [UInt8]) {
        let range = token.range
        var lineStart = range.lowerBound
        while lineStart > 0, bytes[lineStart - 1] != Byte.newline { lineStart -= 1 }
        let oldIndent = bytes[lineStart..<range.lowerBound]
        guard oldIndent.allSatisfy({ $0 == Byte.space || $0 == Byte.tab }), bytes[range].contains(Byte.newline) else {
            out.append(contentsOf: bytes[range])
            return
        }
        var i = range.lowerBound
        while i < range.upperBound {
            let c = bytes[i]
            out.append(c)
            i += 1
            guard c == Byte.newline else { continue }
            if bytes[i..<range.upperBound].starts(with: oldIndent) {
                i += oldIndent.count
            } else {
                while i < range.upperBound, bytes[i] == Byte.space || bytes[i] == Byte.tab { i += 1 }
            }
            if i < range.upperBound, bytes[i] != Byte.newline {
                for _ in 0..<depth { out.append(contentsOf: unit) }
            }
        }
    }

    /// `</name>`, without whitespace inside.
    private func writeEndTag(_ token: Token, into out: inout [UInt8]) {
        out.append(contentsOf: [Byte.lt, Byte.slash])
        out.append(contentsOf: name(of: token))
        out.append(Byte.gt)
    }

    /// A start tag with its attributes as written: one space between attributes on a line, none
    /// around `=`. Attributes that began a line in the source begin one here too, lined up under the
    /// first attribute, or a level deeper than the tag when its name is alone on the first line.
    /// Minified, everything goes on one line.
    private func writeTag(_ token: Token, depth: Int, pretty: Bool, unit: [UInt8], into out: inout [UInt8]) {
        let name = name(of: token)
        let stop = token.range.upperBound - (token.kind == .selfClosing ? 2 : 1)
        out.append(Byte.lt)
        out.append(contentsOf: name)
        var isFirst = true
        var alignsUnderFirst = true
        func lineBreak(continuation: Bool) {
            out.append(Byte.newline)
            for _ in 0..<depth { out.append(contentsOf: unit) }
            guard continuation else { return }
            if alignsUnderFirst {
                out.append(contentsOf: repeatElement(Byte.space, count: name.count + 2))
            } else {
                out.append(contentsOf: unit)
            }
        }
        var i = name.endIndex
        while true {
            var newlines = false
            var spaces = false
            while i < stop, Self.isSpace(bytes[i]) {
                if bytes[i] == Byte.newline { newlines = true }
                spaces = true
                i += 1
            }
            guard i < stop else {
                if pretty, newlines, !isFirst {
                    lineBreak(continuation: false)
                } else if pretty, spaces {
                    out.append(Byte.space)
                }
                break
            }
            if isFirst {
                alignsUnderFirst = !newlines
                isFirst = false
            }
            if pretty, newlines {
                lineBreak(continuation: true)
            } else {
                out.append(Byte.space)
            }
            // name, optional spaces, "=", optional spaces, quoted value
            let start = i
            while i < stop, !Self.isSpace(bytes[i]), bytes[i] != Byte.equals { i += 1 }
            out.append(contentsOf: bytes[start..<i])
            var j = i
            while j < stop, Self.isSpace(bytes[j]) { j += 1 }
            guard j < stop, bytes[j] == Byte.equals else { continue }
            out.append(Byte.equals)
            j += 1
            while j < stop, Self.isSpace(bytes[j]) { j += 1 }
            let valueStart = j
            if j < stop, bytes[j] == Byte.quote || bytes[j] == Byte.apostrophe {
                let quote = bytes[j]
                j += 1
                while j < stop, bytes[j] != quote { j += 1 }
                j = min(j + 1, stop)
            } else {
                while j < stop, !Self.isSpace(bytes[j]) { j += 1 }
            }
            out.append(contentsOf: bytes[valueStart..<j])
            i = j
        }
        if token.kind == .selfClosing { out.append(Byte.slash) }
        out.append(Byte.gt)
    }
}

/// Keeps the first error the XML parser reports, with libxml2's message and line.
private final class XMLErrorCatcher: NSObject, XMLParserDelegate {
    var message: String?
    var line: Int?

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        guard message == nil else { return }
        let info = (parseError as NSError).userInfo
        message = (info["NSXMLParserErrorMessage"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        line = info["NSXMLParserErrorLineNumber"] as? Int
    }
}

/// ASCII bytes used by the XML scanner.
private enum Byte {
    static let tab: UInt8 = 0x09
    static let newline: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let bang: UInt8 = 0x21
    static let quote: UInt8 = 0x22
    static let apostrophe: UInt8 = 0x27
    static let slash: UInt8 = 0x2F
    static let colon: UInt8 = 0x3A
    static let lt: UInt8 = 0x3C
    static let equals: UInt8 = 0x3D
    static let gt: UInt8 = 0x3E
    static let question: UInt8 = 0x3F
    static let lbracket: UInt8 = 0x5B
    static let rbracket: UInt8 = 0x5D
    static let underscore: UInt8 = 0x5F
}
