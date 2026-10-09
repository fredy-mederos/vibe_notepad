import AppKit

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
