import Foundation

// MARK: - Writer

/// Append-only UTF-8 output buffer with HTML escaping helpers.
struct MDHTMLWriter {
    var bytes: [UInt8] = []

    mutating func raw(_ s: StaticString) {
        s.withUTF8Buffer { bytes.append(contentsOf: $0) }
    }

    mutating func raw(_ s: String) {
        bytes.append(contentsOf: s.utf8)
    }

    mutating func raw(_ s: ArraySlice<UInt8>) {
        bytes.append(contentsOf: s)
    }

    mutating func byte(_ c: UInt8) {
        bytes.append(c)
    }

    mutating func number(_ n: Int) {
        var value = n.magnitude
        if n < 0 { bytes.append(MDByte.minus) }
        let start = bytes.count
        repeat {
            bytes.append(UInt8(truncatingIfNeeded: 0x30 + value % 10))
            value /= 10
        } while value > 0
        bytes[start...].reverse()
    }

    /// Ensures the output ends with a line break (no-op at the very beginning).
    mutating func cr() {
        if let last = bytes.last, last != MDByte.newline {
            bytes.append(MDByte.newline)
        }
    }

    /// Appends `s[lo..<hi]` with `&`, `<`, `>` and `"` escaped.
    mutating func escaped(_ s: [UInt8], _ lo: Int, _ hi: Int) {
        var runStart = lo
        var i = lo
        while i < hi {
            let c = s[i]
            if c == MDByte.ampersand || c == MDByte.lessThan || c == MDByte.greaterThan || c == MDByte.quote {
                if i > runStart { bytes.append(contentsOf: s[runStart..<i]) }
                switch c {
                case MDByte.ampersand: raw("&amp;")
                case MDByte.lessThan: raw("&lt;")
                case MDByte.greaterThan: raw("&gt;")
                default: raw("&quot;")
                }
                runStart = i + 1
            }
            i += 1
        }
        if hi > runStart { bytes.append(contentsOf: s[runStart..<hi]) }
    }

    mutating func escaped(_ s: [UInt8]) {
        escaped(s, 0, s.count)
    }

    mutating func escaped(_ s: String) {
        escaped(Array(s.utf8))
    }
}

/// A GFM task list marker found at the start of a list item.
struct MDTaskMarker {
    var checked: Bool
    /// Index in the first paragraph's content where the item text starts.
    var contentStart: Int
}

// MARK: - Renderer

/// Renders an `MDDocument` to an HTML fragment.
struct MDHTMLRenderer {
    private let document: MDDocument
    private let options: MarkdownRenderOptions
    private let bytes: [UInt8]
    private var out = MDHTMLWriter()
    private var inline: MDInlineParser
    private var footnoteOrder: [MDBlock] = []
    private var footnoteNumbers: [ObjectIdentifier: Int] = [:]
    private var footnoteReferenceCounts: [Int] = []
    private var footnoteSlugs: [String: String] = [:]

    init(document: MDDocument, options: MarkdownRenderOptions) {
        self.document = document
        self.options = options
        self.bytes = document.source.bytes
        self.inline = MDInlineParser(references: document.references, footnotes: document.footnotes)
    }

    mutating func render() -> String {
        out.bytes.reserveCapacity(bytes.count + bytes.count / 2 + 64)
        if let matter = document.frontMatter {
            renderFrontMatter(matter)
        }
        for child in document.root.children {
            renderBlock(child, tight: false)
        }
        renderFootnotes()
        return String(decoding: out.bytes, as: UTF8.self)
    }

    private mutating func dataLine(_ line: Int) {
        guard options.sourceLineAttributes else { return }
        out.raw(" data-line=\"")
        out.number(line)
        out.byte(MDByte.quote)
    }

    // MARK: Blocks

    private mutating func renderBlock(_ block: MDBlock, tight: Bool) {
        switch block.kind {
        case .document:
            for child in block.children { renderBlock(child, tight: false) }
        case .paragraph:
            if tight {
                renderInline(block.content, 0, block.content.count)
            } else {
                out.cr()
                out.raw("<p")
                dataLine(block.startLine)
                out.byte(MDByte.greaterThan)
                renderInline(block.content, 0, block.content.count)
                out.raw("</p>")
                out.cr()
            }
        case .heading:
            out.cr()
            out.raw("<h")
            out.number(block.level)
            if !block.anchor.isEmpty {
                out.raw(" id=\"")
                out.escaped(block.anchor)
                out.byte(MDByte.quote)
            }
            dataLine(block.startLine)
            out.byte(MDByte.greaterThan)
            renderInline(block.content, 0, block.content.count)
            out.raw("</h")
            out.number(block.level)
            out.byte(MDByte.greaterThan)
            out.cr()
        case .thematicBreak:
            out.cr()
            out.raw("<hr")
            dataLine(block.startLine)
            out.raw(" />")
            out.cr()
        case .blockQuote:
            renderBlockQuote(block)
        case .list:
            renderList(block)
        case .item:
            renderItem(block, task: nil, tight: tight)
        case .codeBlock:
            renderCodeBlock(block)
        case .htmlBlock:
            renderHTMLBlock(block)
        case .table:
            renderTable(block)
        case .footnoteDefinition:
            break // rendered in the footnotes section
        }
    }

    private mutating func renderBlockQuote(_ block: MDBlock) {
        if let alert = alertKind(block), let first = block.children.first {
            out.cr()
            out.raw("<div class=\"markdown-alert markdown-alert-")
            out.raw(alert.lowercased())
            out.byte(MDByte.quote)
            dataLine(block.startLine)
            out.raw("><p class=\"markdown-alert-title\">")
            out.raw(alert)
            out.raw("</p>")
            out.cr()
            let content = first.content
            if let newline = content.firstIndex(of: MDByte.newline) {
                var start = newline + 1
                while start < content.count && MDChar.isWhitespace(content[start]) { start += 1 }
                if start < content.count {
                    out.raw("<p")
                    dataLine(first.startLine + 1)
                    out.byte(MDByte.greaterThan)
                    renderInline(content, start, content.count)
                    out.raw("</p>")
                    out.cr()
                }
            }
            for child in block.children.dropFirst() {
                renderBlock(child, tight: false)
            }
            out.cr()
            out.raw("</div>")
            out.cr()
            return
        }
        out.cr()
        out.raw("<blockquote")
        dataLine(block.startLine)
        out.byte(MDByte.greaterThan)
        out.cr()
        for child in block.children {
            renderBlock(child, tight: false)
        }
        out.cr()
        out.raw("</blockquote>")
        out.cr()
    }

    /// `> [!NOTE]` (alone on the first line of the quote) → "Note", etc.
    private func alertKind(_ block: MDBlock) -> String? {
        guard let first = block.children.first, first.kind == .paragraph else { return nil }
        let content = first.content
        var end = content.firstIndex(of: MDByte.newline) ?? content.count
        while end > 0 && MDChar.isWhitespace(content[end - 1]) { end -= 1 }
        guard end >= 5, content[0] == MDByte.leftBracket, content[1] == MDByte.bang,
              content[end - 1] == MDByte.rightBracket else { return nil }
        let name = String(decoding: content[2..<(end - 1)], as: UTF8.self).lowercased()
        switch name {
        case "note": return "Note"
        case "tip": return "Tip"
        case "important": return "Important"
        case "warning": return "Warning"
        case "caution": return "Caution"
        default: return nil
        }
    }

    private mutating func renderList(_ list: MDBlock) {
        let tasks = list.children.map(taskMarker)
        let ordered = list.list.ordered
        out.cr()
        out.raw(ordered ? "<ol" : "<ul")
        if tasks.contains(where: { $0 != nil }) {
            out.raw(" class=\"contains-task-list\"")
        }
        if ordered && list.list.start != 1 {
            out.raw(" start=\"")
            out.number(list.list.start)
            out.byte(MDByte.quote)
        }
        dataLine(list.startLine)
        out.byte(MDByte.greaterThan)
        out.cr()
        for (item, task) in zip(list.children, tasks) {
            renderItem(item, task: task, tight: list.list.tight)
        }
        out.cr()
        out.raw(ordered ? "</ol>" : "</ul>")
        out.cr()
    }

    private func taskMarker(_ item: MDBlock) -> MDTaskMarker? {
        guard let first = item.children.first, first.kind == .paragraph, first.startLine == item.startLine else { return nil }
        let content = first.content
        guard content.count >= 3, content[0] == MDByte.leftBracket, content[2] == MDByte.rightBracket else { return nil }
        let mark = content[1]
        guard mark == MDByte.space || mark == 0x78 || mark == 0x58 else { return nil } // " ", "x", "X"
        if content.count > 3 && !MDChar.isWhitespace(content[3]) { return nil }
        var start = 3
        while start < content.count && MDChar.isWhitespace(content[start]) { start += 1 }
        return MDTaskMarker(checked: mark != MDByte.space, contentStart: start)
    }

    private mutating func renderItem(_ item: MDBlock, task: MDTaskMarker?, tight: Bool) {
        out.raw("<li")
        if task != nil { out.raw(" class=\"task-list-item\"") }
        dataLine(item.startLine)
        out.byte(MDByte.greaterThan)
        var children = item.children[...]
        if let task, let first = children.first {
            children = children.dropFirst()
            if !tight {
                out.cr()
                out.raw("<p")
                dataLine(first.startLine)
                out.byte(MDByte.greaterThan)
            }
            out.raw("<input type=\"checkbox\" class=\"task-list-item-checkbox\"")
            dataLine(item.startLine)
            if task.checked { out.raw(" checked") }
            out.byte(MDByte.greaterThan)
            if task.contentStart < first.content.count {
                out.byte(MDByte.space)
                renderInline(first.content, task.contentStart, first.content.count)
            }
            if !tight {
                out.raw("</p>")
                out.cr()
            }
        }
        for child in children {
            renderBlock(child, tight: tight)
        }
        out.raw("</li>")
        out.cr()
    }

    private mutating func renderCodeBlock(_ block: MDBlock) {
        var lines = block.lines[...]
        var language: [UInt8] = []
        if block.isFenced {
            if let info = lines.first {
                let text = MDText.unescape(bytes, info.start, info.end)
                var i = 0
                while i < text.count && MDChar.isWhitespace(text[i]) { i += 1 }
                var j = i
                while j < text.count && !MDChar.isWhitespace(text[j]) { j += 1 }
                language = Array(text[i..<j])
                lines = lines.dropFirst()
            }
        } else {
            while let last = lines.last, isBlank(last) {
                lines = lines.dropLast()
            }
        }
        var code: [UInt8] = []
        for (k, line) in lines.enumerated() {
            if k > 0 { code.append(MDByte.newline) }
            code.mdAppend(line, from: bytes)
        }
        out.cr()
        out.raw("<pre")
        dataLine(block.startLine)
        out.raw("><code")
        if !language.isEmpty {
            out.raw(" class=\"language-")
            out.escaped(language)
            out.byte(MDByte.quote)
        }
        out.byte(MDByte.greaterThan)
        writeCode(code, language: language.isEmpty ? nil : String(decoding: language, as: UTF8.self))
        out.raw("</code></pre>")
        out.cr()
    }

    private mutating func writeCode(_ code: [UInt8], language: String?) {
        if let highlighter = options.codeHighlighter,
           let html = highlighter(String(decoding: code, as: UTF8.self), language) {
            out.raw(html)
        } else {
            out.escaped(code)
        }
    }

    private func isBlank(_ line: MDLineSlice) -> Bool {
        var i = line.start
        while i < line.end {
            if !MDChar.isSpaceOrTab(bytes[i]) { return false }
            i += 1
        }
        return true
    }

    private mutating func renderHTMLBlock(_ block: MDBlock) {
        out.cr()
        if options.allowRawHTML {
            for (k, line) in block.lines.enumerated() {
                if k > 0 { out.byte(MDByte.newline) }
                out.bytes.mdAppend(line, from: bytes)
            }
        } else {
            out.raw("<p")
            dataLine(block.startLine)
            out.byte(MDByte.greaterThan)
            for (k, line) in block.lines.enumerated() {
                if k > 0 { out.byte(MDByte.newline) }
                var text: [UInt8] = []
                text.mdAppend(line, from: bytes)
                out.escaped(text)
            }
            out.raw("</p>")
        }
        out.cr()
    }

    private mutating func renderTable(_ table: MDBlock) {
        guard let header = table.lines.first else { return }
        out.cr()
        out.raw("<table")
        dataLine(table.startLine)
        out.raw("><thead><tr>")
        renderRow(header, header: true, alignments: table.alignments)
        out.raw("</tr></thead>")
        if table.lines.count > 1 {
            out.raw("<tbody>")
            for row in table.lines.dropFirst() {
                out.raw("<tr>")
                renderRow(row, header: false, alignments: table.alignments)
                out.raw("</tr>")
            }
            out.raw("</tbody>")
        }
        out.raw("</table>")
        out.cr()
    }

    private mutating func renderRow(_ row: MDLineSlice, header: Bool, alignments: [MDAlignment]) {
        let cells = MDBlockScan.tableCells(bytes, row.start, row.end)
        for (column, alignment) in alignments.enumerated() {
            out.raw(header ? "<th" : "<td")
            switch alignment {
            case .left: out.raw(" style=\"text-align: left\"")
            case .center: out.raw(" style=\"text-align: center\"")
            case .right: out.raw(" style=\"text-align: right\"")
            case .none: break
            }
            out.byte(MDByte.greaterThan)
            if column < cells.count {
                let content = unescapePipes(cells[column])
                renderInline(content, 0, content.count)
            }
            out.raw(header ? "</th>" : "</td>")
        }
    }

    /// Cell content with `\|` replaced by `|` (GFM processes pipe escapes before inline parsing).
    private func unescapePipes(_ range: Range<Int>) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(range.count)
        var i = range.lowerBound
        while i < range.upperBound {
            if bytes[i] == MDByte.backslash && i + 1 < range.upperBound && bytes[i + 1] == MDByte.pipe {
                result.append(MDByte.pipe)
                i += 2
            } else {
                result.append(bytes[i])
                i += 1
            }
        }
        return result
    }

    private mutating func renderFrontMatter(_ matter: MDFrontMatter) {
        var yaml: [UInt8] = []
        for line in matter.contentLines {
            if line > matter.contentLines.lowerBound { yaml.append(MDByte.newline) }
            yaml.append(contentsOf: bytes[document.source.lineStarts[line]..<document.source.lineEnds[line]])
        }
        out.raw("<details class=\"front-matter\"")
        dataLine(0)
        out.raw("><summary>Front matter</summary><pre><code class=\"language-yaml\">")
        writeCode(yaml, language: "yaml")
        out.raw("</code></pre></details>")
        out.cr()
    }

    // MARK: Inlines

    private mutating func renderInline(_ text: [UInt8], _ lo: Int, _ hi: Int) {
        let root = inline.parse(text, lo, hi)
        var linkDepth = 0
        var node = inline.nodes[root].firstChild
        while node != -1 {
            let n = inline.nodes[node]
            var descend = false
            switch n.kind {
            case .root:
                break
            case .text:
                out.escaped(inline.src, n.start, n.end)
            case .delimiter:
                for _ in 0..<max(n.end, 0) { out.byte(UInt8(truncatingIfNeeded: n.start)) }
            case .softBreak:
                out.byte(MDByte.newline)
            case .hardBreak:
                out.raw("<br />\n")
            case .code:
                out.raw("<code>")
                let range = inline.codeSpanContent(n)
                var runStart = range.lowerBound
                for k in range where inline.src[k] == MDByte.newline {
                    out.escaped(inline.src, runStart, k)
                    out.byte(MDByte.space)
                    runStart = k + 1
                }
                out.escaped(inline.src, runStart, range.upperBound)
                out.raw("</code>")
            case .html:
                if options.allowRawHTML {
                    out.raw(inline.src[n.start..<n.end])
                } else {
                    out.escaped(inline.src, n.start, n.end)
                }
            case .entity:
                out.raw(inline.src[n.start..<n.end])
            case .emphasis:
                out.raw("<em>")
                descend = true
            case .strong:
                out.raw("<strong>")
                descend = true
            case .strikethrough:
                out.raw("<del>")
                descend = true
            case .link:
                let link = inline.links[n.payload]
                out.raw("<a href=\"")
                out.escaped(link.destination)
                out.byte(MDByte.quote)
                if let title = link.title {
                    out.raw(" title=\"")
                    out.escaped(title)
                    out.byte(MDByte.quote)
                }
                out.byte(MDByte.greaterThan)
                linkDepth += 1
                descend = true
            case .image:
                let link = inline.links[n.payload]
                out.raw("<img src=\"")
                out.escaped(link.destination)
                out.raw("\" alt=\"")
                var alt: [UInt8] = []
                inline.appendPlainText(node, to: &alt, includeImages: true)
                out.escaped(alt)
                out.byte(MDByte.quote)
                if let title = link.title {
                    out.raw(" title=\"")
                    out.escaped(title)
                    out.byte(MDByte.quote)
                }
                out.raw(" />")
            case .autolink:
                if linkDepth > 0 {
                    out.escaped(inline.src, n.start, n.end)
                } else {
                    out.raw("<a href=\"")
                    out.escaped(inline.links[n.payload].destination)
                    out.raw("\">")
                    out.escaped(inline.src, n.start, n.end)
                    out.raw("</a>")
                }
            case .footnoteReference:
                renderFootnoteReference(inline.footnoteLabels[n.payload])
            }

            if descend {
                if n.firstChild != -1 {
                    node = n.firstChild
                    continue
                }
                closeInline(n.kind, linkDepth: &linkDepth)
            }
            // Move to the next sibling, closing every container we leave on the way up.
            var current = node
            node = -1
            while current != -1 && current != root {
                let next = inline.nodes[current].next
                if next != -1 {
                    node = next
                    break
                }
                current = inline.nodes[current].parent
                if current == -1 || current == root { break }
                closeInline(inline.nodes[current].kind, linkDepth: &linkDepth)
            }
        }
    }

    private mutating func closeInline(_ kind: MDInlineKind, linkDepth: inout Int) {
        switch kind {
        case .emphasis: out.raw("</em>")
        case .strong: out.raw("</strong>")
        case .strikethrough: out.raw("</del>")
        case .link:
            out.raw("</a>")
            linkDepth -= 1
        default: break
        }
    }

    // MARK: Footnotes

    private mutating func footnoteSlug(_ definition: MDBlock) -> String {
        if let slug = footnoteSlugs[definition.footnoteLabel] { return slug }
        var scalars = String.UnicodeScalarView()
        for scalar in definition.footnoteLabel.unicodeScalars {
            if scalar.value < 0x80 {
                let c = UInt8(scalar.value)
                let keep = MDChar.isAlphanumeric(c) || c == MDByte.minus || c == MDByte.underscore || c == MDByte.dot
                scalars.append(keep ? scalar : "-")
            } else {
                scalars.append(scalar)
            }
        }
        let slug = String(scalars)
        footnoteSlugs[definition.footnoteLabel] = slug
        return slug
    }

    private mutating func renderFootnoteReference(_ key: String) {
        guard let definition = document.footnotes[key] else { return }
        let id = ObjectIdentifier(definition)
        let number: Int
        if let existing = footnoteNumbers[id] {
            number = existing
        } else {
            footnoteOrder.append(definition)
            footnoteReferenceCounts.append(0)
            number = footnoteOrder.count
            footnoteNumbers[id] = number
        }
        footnoteReferenceCounts[number - 1] += 1
        let occurrence = footnoteReferenceCounts[number - 1]
        let slug = footnoteSlug(definition)
        out.raw("<sup class=\"footnote-ref\"><a href=\"#fn-")
        out.escaped(slug)
        out.raw("\" id=\"fnref-")
        out.escaped(slug)
        if occurrence > 1 {
            out.byte(MDByte.minus)
            out.number(occurrence)
        }
        out.raw("\">")
        out.number(number)
        out.raw("</a></sup>")
    }

    private mutating func renderFootnotes() {
        guard !footnoteOrder.isEmpty else { return }
        out.cr()
        out.raw("<section class=\"footnotes\"><ol>")
        var index = 0
        while index < footnoteOrder.count {
            let definition = footnoteOrder[index]
            let slug = footnoteSlug(definition)
            out.raw("<li id=\"fn-")
            out.escaped(slug)
            out.raw("\">")
            let children = definition.children
            if children.count == 1 && children[0].kind == .paragraph {
                renderInline(children[0].content, 0, children[0].content.count)
                renderBackReferences(slug, index: index)
            } else if let last = children.last, last.kind == .paragraph {
                for child in children.dropLast() { renderBlock(child, tight: false) }
                out.cr()
                out.raw("<p")
                dataLine(last.startLine)
                out.byte(MDByte.greaterThan)
                renderInline(last.content, 0, last.content.count)
                renderBackReferences(slug, index: index)
                out.raw("</p>")
                out.cr()
            } else {
                for child in children { renderBlock(child, tight: false) }
                renderBackReferences(slug, index: index)
            }
            out.raw("</li>")
            index += 1
        }
        out.raw("</ol></section>")
        out.cr()
    }

    private mutating func renderBackReferences(_ slug: String, index: Int) {
        let count = max(footnoteReferenceCounts[index], 1)
        for occurrence in 1...count {
            out.raw(" <a href=\"#fnref-")
            out.escaped(slug)
            if occurrence > 1 {
                out.byte(MDByte.minus)
                out.number(occurrence)
            }
            out.raw("\" class=\"footnote-backref\">↩")
            if occurrence > 1 {
                out.raw("<sup>")
                out.number(occurrence)
                out.raw("</sup>")
            }
            out.raw("</a>")
        }
    }
}
