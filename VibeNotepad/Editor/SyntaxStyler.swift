import AppKit
import VibeCore

/// Paints syntax tokens into the text storage. Only lines that changed or became visible are
/// painted, so huge files stay responsive.
final class SyntaxStyler {
    let engine: SyntaxEngine
    private unowned let textStorage: NSTextStorage

    private(set) var baseAttributes: [NSAttributedString.Key: Any] = [:]
    private var tokenAttributes: [TokenKind: [NSAttributedString.Key: Any]] = [:]

    init(language: LanguageID, textStorage: NSTextStorage) {
        self.engine = SyntaxEngine(language: language)
        self.textStorage = textStorage
    }

    /// Rebuilds the attribute tables for a theme/font combination.
    func configure(theme: Theme, font: NSFont, paragraphStyle: NSParagraphStyle) {
        let manager = NSFontManager.shared
        let bold = Self.variant(of: font, bold: true, italic: false, manager: manager)
        let italic = Self.variant(of: font, bold: false, italic: true, manager: manager)
        let boldItalic = Self.variant(of: font, bold: true, italic: true, manager: manager)

        baseAttributes = [
            .font: font,
            .foregroundColor: theme.foreground.nsColor,
            .paragraphStyle: paragraphStyle,
        ]
        var table: [TokenKind: [NSAttributedString.Key: Any]] = [:]
        for kind in TokenKind.allCases {
            guard let style = theme.style(for: kind) else { continue }
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: style.color.nsColor]
            switch (style.bold, style.italic) {
            case (true, true): attributes[.font] = boldItalic
            case (true, false): attributes[.font] = bold
            case (false, true): attributes[.font] = italic
            case (false, false): break
            }
            if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            table[kind] = attributes
        }
        tokenAttributes = table
    }

    private static func variant(of font: NSFont, bold: Bool, italic: Bool, manager: NSFontManager) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        if let converted = NSFont(descriptor: descriptor, size: font.pointSize), converted.fontDescriptor.symbolicTraits.contains(traits) {
            return converted
        }
        var result = font
        if bold { result = manager.convert(result, toHaveTrait: .boldFontMask) }
        if italic { result = manager.convert(result, toHaveTrait: .italicFontMask) }
        return result
    }

    /// Resets every character to the base style and marks all lines for repainting.
    func resetAttributes() {
        let length = textStorage.length
        textStorage.beginEditing()
        if length > 0 { textStorage.setAttributes(baseAttributes, range: NSRange(location: 0, length: length)) }
        textStorage.endEditing()
        engine.invalidateStyling()
    }

    /// Paints `lines` from the engine's current tokens.
    func style(lines: Range<Int>) {
        let lo = max(0, lines.lowerBound), hi = min(engine.lineCount, lines.upperBound)
        guard lo < hi else { return }
        let range = engine.characterRange(lines: lo..<hi)
        let text = textStorage.mutableString
        textStorage.beginEditing()
        if range.length > 0 { textStorage.setAttributes(baseAttributes, range: range) }
        engine.enumerateTokens(lines: lo..<hi, text: text) { tokenRange, kind in
            if let attributes = tokenAttributes[kind] { textStorage.addAttributes(attributes, range: tokenRange) }
        }
        textStorage.endEditing()
        engine.markStyled(lo..<hi)
    }

    /// Paints the lines in `lines` that still need it.
    func styleUnstyled(in lines: Range<Int>) {
        for run in engine.unstyledRuns(in: lines) { style(lines: run) }
    }
}
