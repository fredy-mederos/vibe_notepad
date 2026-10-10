import AppKit
import VibeCore

/// A folded region as laid out by `EditorLayoutManager`.
nonisolated struct FoldSpan: Sendable, Equatable {
    /// Offset of the line feed ending the fold's first line; the `⋯` pill is drawn after it.
    var lineEnd: Int
    /// The hidden lines: everything after `lineEnd` through the closing line's line feed.
    var hidden: NSRange
    /// The fold's own range (as stored in `FoldState`).
    var fold: NSRange
    /// Text drawn after the pill, e.g. `},` for a folded JSON object.
    var preview: String
    /// Where `preview` starts in the text (it's drawn in that character's color).
    var previewIndex: Int
    /// The hidden text runs to the end of a document without a final line feed, so the very
    /// end of the document is hidden too.
    var hidesToEnd: Bool

    /// The span's whole extent: the first line's line feed plus the hidden lines.
    var extent: NSRange { NSRange(location: lineEnd, length: NSMaxRange(hidden) - lineEnd) }
}

extension Array where Element == FoldSpan {
    /// The spans moved by an edit that doesn't touch any of them (nil when one must be rebuilt).
    func shifted(editedRange: NSRange, changeInLength delta: Int) -> [FoldSpan]? {
        let editStart = editedRange.location
        let oldEditEnd = NSMaxRange(editedRange) - delta
        var result = self
        for i in result.indices {
            let span = result[i]
            if NSMaxRange(span.hidden) <= editStart, !span.hidesToEnd { continue }
            guard span.lineEnd >= oldEditEnd else { return nil }
            result[i].lineEnd += delta
            result[i].hidden.location += delta
            result[i].fold.location += delta
            result[i].previewIndex += delta
        }
        return result
    }
}

/// TextKit 1 layout manager with a fixed, vertically centered line height, optional
/// invisible-character drawing and code folding.
///
/// Folded lines keep their glyphs but are laid out by `FoldingTypesetter` as a single
/// zero-height line fragment and skipped when drawing, so collapsing a 500,000-line JSON
/// object costs about as much as collapsing a small one.
nonisolated final class EditorLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var lineHeight: CGFloat = 19
    var showsInvisibles = false
    var invisiblesColor: NSColor = .tertiaryLabelColor

    override init() {
        super.init()
        delegate = self
        typesetter = FoldingTypesetter()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Baseline position that centers the font's glyphs inside `lineHeight`.
    var baselineOffset: CGFloat {
        let glyphHeight = font.ascender - font.descender
        return floor((lineHeight - glyphHeight) / 2 + font.ascender)
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        // A folded line typeset on its own (when the fast path can't be used) takes no space.
        if !foldSpans.isEmpty, hiddenSpan(at: characterIndexForGlyph(at: glyphRange.location)) != nil {
            lineFragmentRect.pointee.size.height = 0
            lineFragmentUsedRect.pointee.size = .zero
            baselineOffset.pointee = 0
            return true
        }
        lineFragmentRect.pointee.size.height = lineHeight
        lineFragmentUsedRect.pointee.size.height = lineHeight
        baselineOffset.pointee = self.baselineOffset
        return true
    }

    // MARK: Folding

    /// Folded regions, sorted and non-overlapping.
    var foldSpans: [FoldSpan] = []
    var foldPillFill: NSColor = .quaternaryLabelColor
    var foldPillText: NSColor = .secondaryLabelColor

    var foldPillWidth: CGFloat { ceil(font.pointSize * 2.1) }

    private static let hiddenRunLength = 512

    /// Index of the first span whose hidden text ends after `location`.
    private func firstSpanIndex(endingAfter location: Int) -> Int {
        var lo = 0, hi = foldSpans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(foldSpans[mid].hidden) <= location { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The fold hiding the character at `index`.
    func hiddenSpan(at index: Int) -> FoldSpan? {
        let i = firstSpanIndex(endingAfter: index)
        guard i < foldSpans.count, foldSpans[i].hidden.location <= index else { return nil }
        return foldSpans[i]
    }

    /// The fold hiding the caret position `index`. The end of a document whose last lines are
    /// folded is hidden too.
    func spanHidingCaret(at index: Int) -> FoldSpan? {
        if let span = hiddenSpan(at: index) { return span }
        if let last = foldSpans.last, last.hidesToEnd, index == NSMaxRange(last.hidden) { return last }
        return nil
    }

    /// The fold whose first line ends at `lineEnd`.
    func span(endingLineAt lineEnd: Int) -> FoldSpan? {
        var lo = 0, hi = foldSpans.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let value = foldSpans[mid].lineEnd
            if value == lineEnd { return foldSpans[mid] }
            if value < lineEnd { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// The first fold whose first line ends at or after `location`.
    func nextSpan(from location: Int) -> FoldSpan? {
        var lo = 0, hi = foldSpans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if foldSpans[mid].lineEnd < location { lo = mid + 1 } else { hi = mid }
        }
        return lo < foldSpans.count ? foldSpans[lo] : nil
    }

    /// Lays out the hidden text of `span` from `character` (up to `limit`) as one zero-height line
    /// fragment right below the line above. Returns the next character to lay out, or nil when that
    /// line isn't laid out yet (the typesetter then typesets a line normally and tries again).
    func layOutHiddenText(of span: FoldSpan, from character: Int, limit: Int) -> Int? {
        guard let container = textContainers.first, let storage = textStorage else { return nil }
        let length = storage.length
        let stop = min(NSMaxRange(span.hidden), limit, length)
        let glyph = glyphIndexForCharacter(at: character)
        guard glyph > 0, stop > character else { return nil }
        let above = lineFragmentRect(forGlyphAt: glyph - 1, effectiveRange: nil, withoutAdditionalLayout: true)
        guard above != .zero else { return nil }
        let end = stop >= length ? numberOfGlyphs : glyphIndexForCharacter(at: stop)
        guard end > glyph else { return nil }
        let range = NSRange(location: glyph, length: end - glyph)
        let y = above.maxY
        setTextContainer(container, forGlyphRange: range)
        setLineFragmentRect(NSRect(x: 0, y: y, width: above.width, height: 0), forGlyphRange: range,
                            usedRect: NSRect(x: 0, y: y, width: 0, height: 0))
        // Restart nominal spacing every so often: finding where a glyph sits sums the advances
        // from the start of its run, which would crawl through millions of hidden glyphs.
        var runStart = glyph
        while runStart < end {
            setLocation(.zero, forStartOfGlyphRange: NSRange(location: runStart, length: min(Self.hiddenRunLength, end - runStart)))
            runStart += Self.hiddenRunLength
        }
        // A document ending with a line feed has an empty last line, shown below the fold.
        if stop >= length, storage.mutableString.character(at: length - 1) == 0x0A {
            setExtraLineFragmentRect(NSRect(x: 0, y: y, width: above.width, height: lineHeight),
                                     usedRect: NSRect(x: 0, y: y, width: 1, height: lineHeight), textContainer: container)
        }
        return stop
    }

    /// Calls `body` with the parts of `glyphs` that aren't folded away.
    private func forEachVisibleGlyphRange(in glyphs: NSRange, _ body: (NSRange) -> Void) {
        guard !foldSpans.isEmpty, glyphs.length > 0 else {
            body(glyphs)
            return
        }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let end = NSMaxRange(characters)
        var cursor = characters.location
        var index = firstSpanIndex(endingAfter: cursor)
        while cursor < end {
            guard index < foldSpans.count, foldSpans[index].hidden.location < end else {
                body(glyphRange(forCharacterRange: NSRange(location: cursor, length: end - cursor), actualCharacterRange: nil))
                return
            }
            let hidden = foldSpans[index].hidden
            if hidden.location > cursor {
                body(glyphRange(forCharacterRange: NSRange(location: cursor, length: hidden.location - cursor), actualCharacterRange: nil))
            }
            cursor = max(cursor, NSMaxRange(hidden))
            index += 1
        }
    }

    /// Rect (text-container coordinates) of the pill and the closing preview drawn after a fold's first line.
    func foldPillRect(for span: FoldSpan) -> (pill: NSRect, preview: NSPoint)? {
        guard let storage = textStorage, span.lineEnd < storage.length else { return nil }
        let glyph = glyphIndexForCharacter(at: span.lineEnd)
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
        guard fragment.height > 0 else { return nil }
        let x = fragment.minX + location(forGlyphAt: glyph).x + 5
        let height = min(fragment.height - 2, ceil(font.ascender - font.descender) + 3)
        let pill = NSRect(x: x, y: fragment.midY - height / 2, width: foldPillWidth, height: height)
        let preview = NSPoint(x: pill.maxX + 3, y: fragment.minY + baselineOffset - font.ascender)
        return (pill, preview)
    }

    /// Clickable area (pill and preview text) in text-container coordinates.
    func foldHitRect(for span: FoldSpan) -> NSRect? {
        guard let geometry = foldPillRect(for: span) else { return nil }
        let previewWidth = span.preview.isEmpty ? 0 : (span.preview as NSString).size(withAttributes: [.font: font]).width + 3
        return NSRect(x: geometry.pill.minX, y: geometry.pill.minY, width: geometry.pill.width + previewWidth, height: geometry.pill.height)
    }

    private func drawFoldPills(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard !foldSpans.isEmpty, let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(9, font.pointSize - 2), weight: .bold),
            .foregroundColor: foldPillText,
        ]
        var lo = 0, hi = foldSpans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if foldSpans[mid].lineEnd < characters.location { lo = mid + 1 } else { hi = mid }
        }
        var index = lo
        while index < foldSpans.count, foldSpans[index].lineEnd < NSMaxRange(characters) {
            let span = foldSpans[index]
            index += 1
            guard let geometry = foldPillRect(for: span) else { continue }
            let pill = geometry.pill.offsetBy(dx: origin.x, dy: origin.y)
            let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2.4, yRadius: pill.height / 2.4)
            foldPillFill.setFill()
            path.fill()
            let label = "⋯" as NSString
            let size = label.size(withAttributes: labelAttributes)
            label.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2), withAttributes: labelAttributes)
            if !span.preview.isEmpty, span.previewIndex < storage.length {
                let color = storage.attribute(.foregroundColor, at: span.previewIndex, effectiveRange: nil) as? NSColor ?? foldPillText
                (span.preview as NSString).draw(at: NSPoint(x: geometry.preview.x + origin.x, y: geometry.preview.y + origin.y),
                                                withAttributes: [.font: font, .foregroundColor: color])
            }
        }
    }

    // MARK: Invisibles

    private static let space = "·"
    private static let tab = "→"
    private static let newline = "¬"
    private static let fullWidthSpace = "□"

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        forEachVisibleGlyphRange(in: glyphsToShow) { range in
            super.drawBackground(forGlyphRange: range, at: origin)
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        forEachVisibleGlyphRange(in: glyphsToShow) { range in
            if showsInvisibles, let storage = textStorage {
                drawInvisibles(forGlyphRange: range, at: origin, string: storage.mutableString)
            }
            super.drawGlyphs(forGlyphRange: range, at: origin)
        }
        drawFoldPills(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawInvisibles(forGlyphRange glyphRange: NSRange, at origin: NSPoint, string: NSString) {
        let characterRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: invisiblesColor]
        let ascender = font.ascender
        var index = characterRange.location
        let end = NSMaxRange(characterRange)
        while index < end {
            let symbol: String?
            switch string.character(at: index) {
            case 0x20: symbol = Self.space
            case 0x09: symbol = Self.tab
            case 0x0A: symbol = Self.newline
            case 0x3000: symbol = Self.fullWidthSpace
            default: symbol = nil
            }
            if let symbol {
                let glyph = glyphIndexForCharacter(at: index)
                let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
                let location = self.location(forGlyphAt: glyph)
                let point = NSPoint(x: origin.x + fragment.minX + location.x, y: origin.y + fragment.minY + location.y - ascender)
                (symbol as NSString).draw(at: point, withAttributes: attributes)
            }
            index += 1
        }
    }
}

/// Typesets visible text as usual and each fold's hidden lines as one zero-height line
/// fragment, so TextKit never typesets text the user can't see.
nonisolated final class FoldingTypesetter: NSATSTypesetter {
    override func layoutCharacters(in characterRange: NSRange, for layoutManager: NSLayoutManager,
                                   maximumNumberOfLineFragments maxNumLines: Int) -> NSRange {
        guard let layout = layoutManager as? EditorLayoutManager, !layout.foldSpans.isEmpty, let storage = layout.textStorage else {
            return super.layoutCharacters(in: characterRange, for: layoutManager, maximumNumberOfLineFragments: maxNumLines)
        }
        let text = storage.mutableString
        let end = min(NSMaxRange(characterRange), text.length)
        var character = characterRange.location
        // NSUIntegerMax ("no limit") arrives as a negative Int.
        var remaining = maxNumLines > 0 ? maxNumLines : Int.max
        while remaining > 0, character < end {
            var chunkEnd = end
            var lines = remaining
            if let span = layout.hiddenSpan(at: character) {
                if let next = layout.layOutHiddenText(of: span, from: character, limit: end) {
                    character = next
                    remaining -= 1
                    continue
                }
                lines = 1 // the line above isn't laid out yet: typeset this one (at zero height) and retry
            } else if let span = layout.nextSpan(from: character), span.lineEnd < end {
                chunkEnd = span.lineEnd + 1 // stop after the fold's first line
            }
            let processed = super.layoutCharacters(in: NSRange(location: character, length: chunkEnd - character),
                                                   for: layoutManager, maximumNumberOfLineFragments: lines)
            let next = NSMaxRange(processed)
            guard next > character else { break }
            // Stopped early: the line budget is spent.
            if next < chunkEnd, lines == remaining { character = next; break }
            remaining -= lines == 1 ? 1 : Self.lineCount(in: text, range: NSRange(location: character, length: next - character))
            character = next
        }
        return NSRange(location: characterRange.location, length: max(0, character - characterRange.location))
    }

    /// Lines in `range` (its line feeds, plus one for an unterminated last line).
    private static func lineCount(in text: NSString, range: NSRange) -> Int {
        var count = 0
        var position = range.location
        let end = NSMaxRange(range)
        var buffer = [unichar](repeating: 0, count: 2048)
        var last: unichar = 0
        while position < end {
            let chunk = min(buffer.count, end - position)
            text.getCharacters(&buffer, range: NSRange(location: position, length: chunk))
            for k in 0..<chunk where buffer[k] == 0x0A { count += 1 }
            last = buffer[chunk - 1]
            position += chunk
        }
        return max(1, count + (last == 0x0A ? 0 : 1))
    }
}
