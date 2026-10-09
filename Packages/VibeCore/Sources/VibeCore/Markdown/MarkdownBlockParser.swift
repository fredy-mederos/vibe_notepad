import Foundation

/// Result of trying to continue an open block on the current line.
enum MDContinuation {
    case matched
    case failed
    /// The line was fully consumed (closing code fence).
    case finished
}

/// Result of trying to open a new block on the current line.
enum MDBlockStart {
    case none
    case container
    case leaf
}

/// CommonMark block-structure parser (the open-block algorithm of the reference implementation),
/// extended with GFM tables, footnote definitions and YAML front matter.
///
/// Each line is processed once; the cost per line is bounded by the (capped) container depth.
struct MDBlockParser {
    let source: MDSource
    let root: MDBlock
    private(set) var references: [String: MDLinkReference] = [:]
    private(set) var footnotes: [String: MDBlock] = [:]
    private(set) var frontMatter: MDFrontMatter?

    private let bytes: [UInt8]
    /// Open blocks from the document (index 0) down to the tip.
    private var stack: [MDBlock]

    // MARK: Per-line state

    private var lineIndex = 0
    private var lineEnd = 0
    private var offset = 0
    private var column = 0
    private var nextNonspace = 0
    private var nextNonspaceColumn = 0
    private var indent = 0
    private var blank = false
    private var partiallyConsumedTab = false
    private var allClosed = true
    private var lastMatchedIndex = 0
    /// The current line's known whitespace run `[spaceRunStart, spaceRunEnd)`, so the per-container
    /// `findNextNonspace` calls don't rescan deep indentation (keeps nested lists linear).
    private var spaceRunStart = -1
    private var spaceRunEnd = 0
    private var spaceRunHasTab = false

    init(source: MDSource) {
        self.source = source
        self.bytes = source.bytes
        let root = MDBlock(kind: .document, startLine: 0)
        self.root = root
        self.stack = [root]
    }

    private var tip: MDBlock { stack[stack.count - 1] }
    private var indented: Bool { indent >= 4 }

    @inline(__always) private func peek(_ i: Int) -> UInt8 {
        i < lineEnd ? bytes[i] : 0
    }

    // MARK: Driver

    mutating func parse() {
        let count = source.lineCount
        var first = 0
        if let matter = detectFrontMatter() {
            frontMatter = matter
            first = matter.contentLines.upperBound + 1
        }
        var line = first
        while line < count {
            processLine(line)
            line += 1
        }
        lineIndex = count
        while stack.count > 1 {
            finalizeTip(endLine: count - 1)
        }
        root.endLine = max(count - 1, 0)
    }

    private func detectFrontMatter() -> MDFrontMatter? {
        guard source.lineCount >= 2, source.lineEquals(0, "---") else { return nil }
        for line in 1..<source.lineCount where source.lineEquals(line, "---") || source.lineEquals(line, "...") {
            return MDFrontMatter(contentLines: 1..<line)
        }
        return nil
    }

    private mutating func processLine(_ index: Int) {
        lineIndex = index
        offset = source.lineStarts[index]
        lineEnd = source.lineEnds[index]
        column = 0
        blank = false
        partiallyConsumedTab = false
        spaceRunStart = -1

        // 1. Walk the open blocks and match their continuation markers.
        var matched = 0
        var i = 1
        walk: while i < stack.count {
            findNextNonspace()
            switch continueBlock(stack[i]) {
            case .matched:
                matched = i
                i += 1
            case .failed:
                break walk
            case .finished:
                return
            }
        }
        allClosed = matched == stack.count - 1
        lastMatchedIndex = matched
        var container = stack[matched]

        // 2. Try to open new blocks (unless the matched block takes raw lines).
        var matchedLeaf = container.kind == .codeBlock || container.kind == .htmlBlock
        starts: while !matchedLeaf {
            findNextNonspace()
            if !indented && !mayStartBlock(peek(nextNonspace)) {
                advanceNextNonspace()
                break
            }
            switch openBlock(container) {
            case .none:
                advanceNextNonspace()
                break starts
            case .container:
                container = tip
            case .leaf:
                container = tip
                matchedLeaf = true
            }
        }

        // 3. Add the remaining text to the right block.
        if !allClosed && !blank && tip.kind == .paragraph {
            addLine(to: tip) // lazy paragraph continuation
            return
        }
        closeUnmatchedBlocks()
        let target = tip
        switch target.kind {
        case .paragraph, .codeBlock, .htmlBlock:
            addLine(to: target)
            if target.kind == .htmlBlock, (1...5).contains(target.htmlType),
               MDBlockScan.htmlBlockEnds(target.htmlType, bytes, offset, lineEnd) {
                finalizeTip(endLine: lineIndex)
            }
        case .table:
            if offset < lineEnd && !blank { addLine(to: target) }
        default:
            if offset < lineEnd && !blank {
                let paragraph = addChild(.paragraph)
                advanceNextNonspace()
                addLine(to: paragraph)
            }
        }
    }

    @inline(__always) private func mayStartBlock(_ c: UInt8) -> Bool {
        switch c {
        case MDByte.hash, MDByte.backtick, MDByte.tilde, MDByte.asterisk, MDByte.plus, MDByte.underscore,
             MDByte.equals, MDByte.lessThan, MDByte.greaterThan, MDByte.minus, MDByte.leftBracket,
             MDByte.pipe, MDByte.colon, 0x30...0x39:
            return true
        default:
            return false
        }
    }

    // MARK: Continuation

    private mutating func continueBlock(_ block: MDBlock) -> MDContinuation {
        switch block.kind {
        case .document, .list:
            return .matched
        case .blockQuote:
            guard !indented && peek(nextNonspace) == MDByte.greaterThan else { return .failed }
            advanceNextNonspace()
            advanceOffset(1, columns: false)
            if MDChar.isSpaceOrTab(peek(offset)) { advanceOffset(1, columns: true) }
            return .matched
        case .item:
            if blank {
                if block.children.isEmpty { return .failed }
                advanceNextNonspace()
                return .matched
            }
            let width = block.list.markerOffset + block.list.padding
            guard indent >= width else { return .failed }
            advanceOffset(width, columns: true)
            return .matched
        case .footnoteDefinition:
            if blank {
                advanceNextNonspace()
                return .matched
            }
            guard indent >= 4 else { return .failed }
            advanceOffset(4, columns: true)
            return .matched
        case .paragraph, .table:
            return blank ? .failed : .matched
        case .heading, .thematicBreak:
            return .failed
        case .codeBlock:
            if block.isFenced {
                if indent <= 3 && peek(nextNonspace) == block.fenceChar
                    && MDBlockScan.isClosingFence(bytes, nextNonspace, lineEnd, char: block.fenceChar, minLength: block.fenceLength) {
                    finalizeTip(endLine: lineIndex)
                    return .finished
                }
                var remaining = block.fenceOffset
                while remaining > 0 && MDChar.isSpaceOrTab(peek(offset)) {
                    advanceOffset(1, columns: true)
                    remaining -= 1
                }
                return .matched
            }
            if indent >= 4 {
                advanceOffset(4, columns: true)
                return .matched
            }
            if blank {
                advanceNextNonspace()
                return .matched
            }
            return .failed
        case .htmlBlock:
            return blank && (block.htmlType == 6 || block.htmlType == 7) ? .failed : .matched
        }
    }

    // MARK: Block starts

    private mutating func openBlock(_ container: MDBlock) -> MDBlockStart {
        let c = peek(nextNonspace)
        let canNest = stack.count < MDLimits.maxBlockDepth
        if !indented {
            switch c {
            case MDByte.greaterThan where canNest:
                advanceNextNonspace()
                advanceOffset(1, columns: false)
                if MDChar.isSpaceOrTab(peek(offset)) { advanceOffset(1, columns: true) }
                closeUnmatchedBlocks()
                _ = addChild(.blockQuote)
                return .container
            case MDByte.hash:
                if let atx = MDBlockScan.atxHeading(bytes, nextNonspace, lineEnd) {
                    closeUnmatchedBlocks()
                    let heading = addChild(.heading)
                    heading.level = atx.level
                    heading.content = Array(bytes[atx.start..<atx.end])
                    offset = lineEnd
                    return .leaf
                }
            case MDByte.backtick, MDByte.tilde:
                if let fence = MDBlockScan.openingFence(bytes, nextNonspace, lineEnd) {
                    closeUnmatchedBlocks()
                    let code = addChild(.codeBlock)
                    code.isFenced = true
                    code.fenceChar = fence.char
                    code.fenceLength = fence.length
                    code.fenceOffset = indent
                    advanceNextNonspace()
                    advanceOffset(fence.length, columns: false)
                    return .leaf
                }
            case MDByte.lessThan:
                if let type = MDBlockScan.htmlBlockStart(bytes, nextNonspace, lineEnd) {
                    let maybeLazy = !allClosed && !blank && tip.kind == .paragraph
                    if type < 7 || (container.kind != .paragraph && !maybeLazy) {
                        closeUnmatchedBlocks()
                        let html = addChild(.htmlBlock)
                        html.htmlType = type
                        return .leaf
                    }
                }
            default:
                break
            }
            if container.kind == .paragraph {
                if let level = MDBlockScan.setextLevel(bytes, nextNonspace, lineEnd),
                   convertToSetextHeading(container, level: level) {
                    return .leaf
                }
                if openTable(after: container) { return .leaf }
            }
            if MDBlockScan.isThematicBreak(bytes, nextNonspace, lineEnd) {
                closeUnmatchedBlocks()
                _ = addChild(.thematicBreak)
                offset = lineEnd
                return .leaf
            }
            if c == MDByte.leftBracket && canNest,
               let footnote = MDBlockScan.footnoteDefinition(bytes, nextNonspace, lineEnd) {
                closeUnmatchedBlocks()
                let definition = addChild(.footnoteDefinition)
                let key = MDLinkScan.normalizeLabel(bytes, footnote.label.lowerBound, footnote.label.upperBound)
                definition.footnoteLabel = key
                if footnotes[key] == nil { footnotes[key] = definition }
                advanceNextNonspace()
                advanceOffset(footnote.after - offset, columns: false)
                return .container
            }
        }
        if (!indented || container.kind == .list) && canNest, let data = parseListMarker(container) {
            closeUnmatchedBlocks()
            if tip.kind != .list || !tip.list.matches(data) {
                let list = addChild(.list)
                list.list = data
            }
            let item = addChild(.item)
            item.list = data
            return .container
        }
        if indented && tip.kind != .paragraph && !blank {
            advanceOffset(4, columns: true)
            closeUnmatchedBlocks()
            _ = addChild(.codeBlock)
            return .leaf
        }
        return .none
    }

    /// List marker at `nextNonspace` (CommonMark rules for the content column). Advances past the marker on success.
    private mutating func parseListMarker(_ container: MDBlock) -> MDListInfo? {
        guard indent < 4 else { return nil }
        var data = MDListInfo()
        data.markerOffset = indent
        let start = nextNonspace
        let c = peek(start)
        var markerLength = 0
        if c == MDByte.asterisk || c == MDByte.plus || c == MDByte.minus {
            data.bulletChar = c
            markerLength = 1
        } else if MDChar.isDigit(c) {
            var i = start
            var value = 0
            while i < lineEnd && MDChar.isDigit(bytes[i]) && i - start < 10 {
                value = value * 10 + Int(bytes[i] - 0x30)
                i += 1
            }
            let digits = i - start
            guard digits <= 9, i < lineEnd, bytes[i] == MDByte.dot || bytes[i] == MDByte.rightParen else { return nil }
            if container.kind == .paragraph && value != 1 { return nil }
            data.ordered = true
            data.start = value
            data.delimiter = bytes[i]
            markerLength = digits + 1
        } else {
            return nil
        }
        let afterMarker = start + markerLength
        guard afterMarker >= lineEnd || MDChar.isSpaceOrTab(bytes[afterMarker]) else { return nil }
        if container.kind == .paragraph {
            var j = afterMarker
            while j < lineEnd && MDChar.isSpaceOrTab(bytes[j]) { j += 1 }
            if j >= lineEnd { return nil } // an empty item cannot interrupt a paragraph
        }

        advanceNextNonspace()
        advanceOffset(markerLength, columns: true)
        let spacesStartColumn = column
        let spacesStartOffset = offset
        repeat {
            advanceOffset(1, columns: true)
        } while column - spacesStartColumn < 5 && MDChar.isSpaceOrTab(peek(offset))
        let blankItem = offset >= lineEnd
        let spacesAfterMarker = column - spacesStartColumn
        if spacesAfterMarker >= 5 || spacesAfterMarker < 1 || blankItem {
            data.padding = markerLength + 1
            column = spacesStartColumn
            offset = spacesStartOffset
            if MDChar.isSpaceOrTab(peek(offset)) { advanceOffset(1, columns: true) }
        } else {
            data.padding = markerLength + spacesAfterMarker
        }
        return data
    }

    /// Turns the open paragraph into a setext heading. Fails when the paragraph only held link definitions.
    private mutating func convertToSetextHeading(_ paragraph: MDBlock, level: Int) -> Bool {
        closeUnmatchedBlocks()
        let (content, startLine) = materialize(paragraph)
        paragraph.lines = []
        guard !content.isEmpty else { return false }
        paragraph.kind = .heading
        paragraph.level = level
        paragraph.content = content
        paragraph.startLine = startLine
        offset = lineEnd
        return true
    }

    /// GFM table: the paragraph's last line is the header row and the current line is the delimiter row.
    private mutating func openTable(after paragraph: MDBlock) -> Bool {
        guard let header = paragraph.lines.last,
              let alignments = MDBlockScan.tableDelimiterRow(bytes, nextNonspace, lineEnd) else { return false }
        let headerCells = MDBlockScan.tableCells(bytes, header.start, header.end)
        guard headerCells.count == alignments.count,
              MDBlockScan.containsPipe(bytes, nextNonspace, lineEnd) || MDBlockScan.containsPipe(bytes, header.start, header.end)
        else { return false }
        closeUnmatchedBlocks()
        paragraph.lines.removeLast()
        if paragraph.lines.isEmpty {
            stack.removeLast()
            if tip.children.last === paragraph { tip.children.removeLast() }
        } else {
            finalizeTip(endLine: header.line - 1)
        }
        let table = addChild(.table)
        table.startLine = header.line
        table.alignments = alignments
        table.lines = [header]
        offset = lineEnd
        return true
    }

    // MARK: Line state helpers

    private mutating func findNextNonspace() {
        if spaceRunStart >= 0 && !spaceRunHasTab && offset >= spaceRunStart && offset <= spaceRunEnd {
            nextNonspace = spaceRunEnd
            nextNonspaceColumn = column + (spaceRunEnd - offset)
        } else {
            var i = offset
            var cols = column
            var sawTab = false
            while i < lineEnd {
                let c = bytes[i]
                if c == MDByte.space {
                    i += 1
                    cols += 1
                } else if c == MDByte.tab {
                    i += 1
                    cols += 4 - (cols % 4)
                    sawTab = true
                } else {
                    break
                }
            }
            nextNonspace = i
            nextNonspaceColumn = cols
            spaceRunStart = offset
            spaceRunEnd = i
            spaceRunHasTab = sawTab
        }
        blank = nextNonspace >= lineEnd
        indent = nextNonspaceColumn - column
    }

    private mutating func advanceOffset(_ count: Int, columns: Bool) {
        var count = count
        while count > 0 && offset < lineEnd {
            if bytes[offset] == MDByte.tab {
                let charsToTab = 4 - (column % 4)
                if columns {
                    partiallyConsumedTab = charsToTab > count
                    let charsToAdvance = min(charsToTab, count)
                    column += charsToAdvance
                    offset += partiallyConsumedTab ? 0 : 1
                    count -= charsToAdvance
                } else {
                    partiallyConsumedTab = false
                    column += charsToTab
                    offset += 1
                    count -= 1
                }
            } else {
                partiallyConsumedTab = false
                offset += 1
                column += 1
                count -= 1
            }
        }
    }

    private mutating func advanceNextNonspace() {
        offset = nextNonspace
        column = nextNonspaceColumn
        partiallyConsumedTab = false
    }

    private mutating func addLine(to block: MDBlock) {
        var pad = 0
        if partiallyConsumedTab {
            offset += 1
            pad = 4 - (column % 4)
            partiallyConsumedTab = false
        }
        block.lines.append(MDLineSlice(start: min(offset, lineEnd), end: lineEnd, pad: pad, line: lineIndex))
    }

    // MARK: Tree maintenance

    private mutating func addChild(_ kind: MDBlock.Kind) -> MDBlock {
        while stack.count > 1 && !tip.canContain(kind) {
            finalizeTip(endLine: lineIndex - 1)
        }
        let block = MDBlock(kind: kind, startLine: lineIndex)
        tip.children.append(block)
        stack.append(block)
        return block
    }

    private mutating func closeUnmatchedBlocks() {
        guard !allClosed else { return }
        while stack.count - 1 > lastMatchedIndex {
            finalizeTip(endLine: lineIndex - 1)
        }
        allClosed = true
    }

    private mutating func finalizeTip(endLine: Int) {
        guard stack.count > 1 else { return }
        let block = stack.removeLast()
        block.endLine = max(endLine, block.startLine)
        switch block.kind {
        case .paragraph:
            let (content, startLine) = materialize(block)
            block.lines = []
            if content.isEmpty {
                // Only link reference definitions: the paragraph produces no output.
                if tip.children.last === block { tip.children.removeLast() }
            } else {
                block.content = content
                block.startLine = startLine
            }
        case .item:
            block.endLine = max(block.children.last?.endLine ?? block.startLine, block.startLine)
        case .list:
            finalizeList(block)
        default:
            break
        }
    }

    /// Joins the paragraph lines, extracts leading link reference definitions and trims the rest.
    private mutating func materialize(_ paragraph: MDBlock) -> (content: [UInt8], startLine: Int) {
        var buffer: [UInt8] = []
        var total = 0
        for slice in paragraph.lines { total += slice.end - slice.start + slice.pad + 1 }
        buffer.reserveCapacity(total)
        for (k, slice) in paragraph.lines.enumerated() {
            if k > 0 { buffer.append(MDByte.newline) }
            buffer.mdAppend(slice, from: bytes)
        }
        var startLine = paragraph.lines.first?.line ?? paragraph.startLine
        var pos = 0
        while pos < buffer.count, buffer[pos] == MDByte.leftBracket,
              let definition = MDLinkScan.referenceDefinition(buffer, pos, buffer.count) {
            if references[definition.label] == nil {
                references[definition.label] = definition.reference
            }
            for k in pos..<definition.next where buffer[k] == MDByte.newline {
                startLine += 1
            }
            pos = definition.next
        }
        var lo = pos
        var hi = buffer.count
        while lo < hi && MDChar.isWhitespace(buffer[lo]) {
            if buffer[lo] == MDByte.newline { startLine += 1 }
            lo += 1
        }
        while hi > lo && MDChar.isWhitespace(buffer[hi - 1]) { hi -= 1 }
        if lo == 0 && hi == buffer.count { return (buffer, startLine) }
        return (Array(buffer[lo..<hi]), startLine)
    }

    /// A list is loose if any item, or any block inside an item, is followed by a blank line before its next sibling.
    private func finalizeList(_ list: MDBlock) {
        var tight = true
        let items = list.children
        check: for (index, item) in items.enumerated() {
            if index + 1 < items.count && item.endLine + 1 != items[index + 1].startLine {
                tight = false
                break
            }
            let blocks = item.children
            for (k, block) in blocks.enumerated() where k + 1 < blocks.count && block.endLine + 1 != blocks[k + 1].startLine {
                tight = false
                break check
            }
        }
        list.list.tight = tight
        list.endLine = max(items.last?.endLine ?? list.startLine, list.startLine)
    }
}
