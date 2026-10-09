import AppKit
import VibeCore

/// TextKit 1 layout manager with a fixed, vertically centered line height and optional
/// invisible-character drawing.
nonisolated final class EditorLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var lineHeight: CGFloat = 19
    var showsInvisibles = false
    var invisiblesColor: NSColor = .tertiaryLabelColor

    override init() {
        super.init()
        delegate = self
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
        lineFragmentRect.pointee.size.height = lineHeight
        lineFragmentUsedRect.pointee.size.height = lineHeight
        baselineOffset.pointee = self.baselineOffset
        return true
    }

    // MARK: Folding

    /// Outermost folded ranges, sorted. Their first character (a line feed) becomes the `⋯` pill;
    /// everything else inside takes no space and doesn't break lines.
    var hiddenRanges: [NSRange] = []
    var foldPillFill: NSColor = .quaternaryLabelColor
    var foldPillText: NSColor = .secondaryLabelColor

    var foldPillWidth: CGFloat { ceil(font.pointSize * 2.3) }

    /// The folded range containing `index` (including its first character).
    func hiddenRange(at index: Int) -> NSRange? {
        var lo = 0, hi = hiddenRanges.count - 1
        var found: NSRange?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if hiddenRanges[mid].location <= index {
                found = hiddenRanges[mid]
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard let found, index < NSMaxRange(found) else { return nil }
        return found
    }

    private func hasHiddenText(between first: Int, and last: Int) -> Bool {
        guard !hiddenRanges.isEmpty else { return false }
        if hiddenRange(at: first) != nil { return true }
        // Any range starting inside [first, last]?
        var lo = 0, hi = hiddenRanges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let location = hiddenRanges[mid].location
            if location < first { lo = mid + 1 } else if location > last { hi = mid - 1 } else { return true }
        }
        return false
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        let count = glyphRange.length
        guard count > 0, hasHiddenText(between: charIndexes[0], and: charIndexes[count - 1]) else { return 0 }
        var properties = [NSLayoutManager.GlyphProperty](repeating: [], count: count)
        for i in 0..<count {
            var property = props[i]
            let index = charIndexes[i]
            if let range = hiddenRange(at: index) {
                if index == range.location {
                    property = .controlCharacter
                } else if !property.contains(.controlCharacter) {
                    property = .null
                }
            }
            properties[i] = property
        }
        properties.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                layoutManager.setGlyphs(glyphs, properties: base, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
            }
        }
        return count
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let range = hiddenRange(at: charIndex) else { return action }
        return charIndex == range.location ? .whitespace : .zeroAdvancement
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint,
                       characterIndex charIndex: Int) -> NSRect {
        NSRect(x: glyphPosition.x, y: 0, width: foldPillWidth, height: proposedRect.height)
    }

    /// The pill's rect in text-container coordinates.
    func foldPillRect(for range: NSRange) -> NSRect? {
        guard let container = textContainers.first, range.location < (textStorage?.length ?? 0) else { return nil }
        let glyph = glyphIndexForCharacter(at: range.location)
        let box = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard box.width > 1 else { return nil }
        let height = min(box.height - 2, ceil(font.ascender - font.descender) + 3)
        return NSRect(x: box.minX + 2, y: box.midY - height / 2, width: foldPillWidth - 4, height: height)
    }

    private func drawFoldPills(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard !hiddenRanges.isEmpty else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(9, font.pointSize - 2), weight: .bold),
            .foregroundColor: foldPillText,
        ]
        guard var index = FoldState.lastIndex(in: hiddenRanges, atOrBefore: characters.location) else {
            return drawPills(from: 0, characters: characters, origin: origin, attributes: attributes)
        }
        if hiddenRanges[index].location < characters.location { index += 1 }
        drawPills(from: index, characters: characters, origin: origin, attributes: attributes)
    }

    private func drawPills(from start: Int, characters: NSRange, origin: NSPoint, attributes: [NSAttributedString.Key: Any]) {
        var index = start
        while index < hiddenRanges.count, hiddenRanges[index].location < NSMaxRange(characters) {
            if var pill = foldPillRect(for: hiddenRanges[index]) {
                pill = pill.offsetBy(dx: origin.x, dy: origin.y)
                let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2.4, yRadius: pill.height / 2.4)
                foldPillFill.setFill()
                path.fill()
                let label = "⋯" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2), withAttributes: attributes)
            }
            index += 1
        }
    }

    // MARK: Invisibles

    private static let space = "·"
    private static let tab = "→"
    private static let newline = "¬"
    private static let fullWidthSpace = "□"

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if showsInvisibles, let storage = textStorage {
            drawInvisibles(forGlyphRange: glyphsToShow, at: origin, string: storage.mutableString)
        }
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
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
            if let symbol, hiddenRange(at: index) == nil {
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
