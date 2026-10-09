import Foundation

/// A platform-neutral sRGB color.
public struct RGBA: Hashable, Sendable, Codable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
    public init(_ hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        if s.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
    }

    public func withAlpha(_ alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }

    /// Linear interpolation towards `other` (`amount` 0…1). Alpha is interpolated too.
    public func mixed(with other: RGBA, _ amount: Double) -> RGBA {
        RGBA(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount, a: a + (other.a - a) * amount)
    }

    /// This color composited over an opaque `background`.
    public func flattened(over background: RGBA) -> RGBA {
        RGBA(r: r * a + background.r * (1 - a), g: g * a + background.g * (1 - a), b: b * a + background.b * (1 - a), a: 1)
    }

    /// Relative luminance (WCAG).
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    public var hex: String {
        let components = [r, g, b].map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
        return a < 1 ? "#\(components)\(String(format: "%02X", Int((a * 255).rounded())))" : "#\(components)"
    }

    /// `rgba(r, g, b, a)` for CSS.
    public var css: String {
        "rgba(\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((b * 255).rounded())), \(String(format: "%.3f", a)))"
    }
}

/// How a token kind is drawn.
public struct TokenStyle: Hashable, Sendable {
    public var color: RGBA
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool

    public init(_ color: RGBA, bold: Bool = false, italic: Bool = false, underline: Bool = false, strikethrough: Bool = false) {
        self.color = color
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
    }
}

/// An editor color scheme.
public struct Theme: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isDark: Bool
    public let background: RGBA
    public let foreground: RGBA
    public let selection: RGBA
    public let cursor: RGBA
    public let lineHighlight: RGBA
    public let gutterForeground: RGBA
    public let gutterActiveForeground: RGBA
    public let accent: RGBA
    public let findMatch: RGBA
    public let findCurrent: RGBA
    public let invisibles: RGBA
    public let styles: [TokenKind: TokenStyle]

    public func style(for kind: TokenKind) -> TokenStyle? { styles[kind] }

    /// A slightly offset background for chrome around the editor (tab bar, status bar).
    public var chromeBackground: RGBA {
        isDark ? background.mixed(with: RGBA(r: 0, g: 0, b: 0), 0.18) : background.mixed(with: RGBA(r: 0, g: 0, b: 0), 0.035)
    }

    /// Secondary text (status bar, inactive tabs).
    public var mutedForeground: RGBA { foreground.mixed(with: background, 0.42) }

    /// CSS custom properties used by the Markdown preview.
    public var cssVariables: String {
        let codeBackground = isDark ? foreground.withAlpha(0.07) : foreground.withAlpha(0.055)
        let border = isDark ? foreground.withAlpha(0.14) : foreground.withAlpha(0.13)
        var vars: [String] = [
            "--bg: \(background.css)",
            "--fg: \(foreground.css)",
            "--muted: \(mutedForeground.css)",
            "--accent: \(accent.css)",
            "--border: \(border.css)",
            "--code-bg: \(codeBackground.css)",
            "--selection: \(selection.css)",
            "--link: \((style(for: .link)?.color ?? accent).css)",
            "--heading: \(foreground.css)",
            "--quote: \(mutedForeground.css)",
            "--mark: \(findMatch.css)",
        ]
        for kind in TokenKind.allCases {
            if let style = style(for: kind) { vars.append("--\(kind.cssClass): \(style.color.css)") }
        }
        return vars.joined(separator: "; ")
    }

    /// CSS rules mapping highlight classes to the variables above.
    public var tokenCSS: String {
        var rules: [String] = []
        for kind in TokenKind.allCases {
            guard let style = style(for: kind) else { continue }
            var declarations = ["color: var(--\(kind.cssClass))"]
            if style.bold { declarations.append("font-weight: 600") }
            if style.italic { declarations.append("font-style: italic") }
            if style.underline { declarations.append("text-decoration: underline") }
            if style.strikethrough { declarations.append("text-decoration: line-through") }
            rules.append(".\(kind.cssClass) { \(declarations.joined(separator: "; ")) }")
        }
        return rules.joined(separator: "\n")
    }
}

// MARK: - Palette builder

/// The handful of colors a theme author picks; `Theme(palette:)` derives every token style.
struct Palette {
    var background: String
    var foreground: String
    var selection: String
    var cursor: String
    var lineHighlight: String
    var gutter: String
    var gutterActive: String
    var accent: String

    var comment: String
    var keyword: String
    var type: String
    var function: String
    var string: String
    var number: String
    var constant: String
    var variable: String
    var property: String
    var `operator`: String
    var punctuation: String
    var tag: String
    var attribute: String
    var meta: String
    var escape: String
    var regex: String
    var heading: String
    var link: String
    var code: String
    var quote: String
    var strong: String
    var markup: String
    var inserted: String
    var deleted: String
    var changed: String
    var invalid: String

    var italicComments = false
    var italicTypes = false
    var findMatch: String? = nil
}

extension Theme {
    init(id: String, name: String, dark: Bool, _ p: Palette) {
        let c = RGBA.init(_:)
        self.id = id
        self.name = name
        self.isDark = dark
        background = c(p.background)
        foreground = c(p.foreground)
        selection = c(p.selection)
        cursor = c(p.cursor)
        lineHighlight = c(p.lineHighlight)
        gutterForeground = c(p.gutter)
        gutterActiveForeground = c(p.gutterActive)
        accent = c(p.accent)
        findMatch = p.findMatch.map(c) ?? (dark ? RGBA("#FFD54A").withAlpha(0.28) : RGBA("#FFC800").withAlpha(0.38))
        findCurrent = dark ? RGBA("#FF9F1A").withAlpha(0.62) : RGBA("#FF8A00").withAlpha(0.55)
        invisibles = c(p.foreground).withAlpha(dark ? 0.22 : 0.25)

        var s: [TokenKind: TokenStyle] = [:]
        s[.comment] = TokenStyle(c(p.comment), italic: p.italicComments)
        s[.keyword] = TokenStyle(c(p.keyword))
        s[.type] = TokenStyle(c(p.type), italic: p.italicTypes)
        s[.function] = TokenStyle(c(p.function))
        s[.string] = TokenStyle(c(p.string))
        s[.number] = TokenStyle(c(p.number))
        s[.constant] = TokenStyle(c(p.constant))
        s[.variable] = TokenStyle(c(p.variable))
        s[.property] = TokenStyle(c(p.property))
        s[.operator] = TokenStyle(c(p.operator))
        s[.punctuation] = TokenStyle(c(p.punctuation))
        s[.tag] = TokenStyle(c(p.tag))
        s[.attribute] = TokenStyle(c(p.attribute))
        s[.meta] = TokenStyle(c(p.meta))
        s[.escape] = TokenStyle(c(p.escape))
        s[.regex] = TokenStyle(c(p.regex))
        s[.section] = TokenStyle(c(p.type), bold: true)
        s[.heading] = TokenStyle(c(p.heading), bold: true)
        s[.emphasis] = TokenStyle(c(p.foreground), italic: true)
        s[.strong] = TokenStyle(c(p.strong), bold: true)
        s[.strikethrough] = TokenStyle(c(p.comment), strikethrough: true)
        s[.link] = TokenStyle(c(p.link))
        s[.url] = TokenStyle(c(p.comment), underline: true)
        s[.code] = TokenStyle(c(p.code))
        s[.quote] = TokenStyle(c(p.quote), italic: true)
        s[.listMarker] = TokenStyle(c(p.keyword))
        s[.markup] = TokenStyle(c(p.markup))
        s[.inserted] = TokenStyle(c(p.inserted))
        s[.deleted] = TokenStyle(c(p.deleted))
        s[.changed] = TokenStyle(c(p.changed))
        s[.invalid] = TokenStyle(c(p.invalid), underline: true)
        let rainbow = [p.keyword, p.string, p.number, p.function, p.type, p.property]
        for (kind, color) in zip(TokenKind.rainbow, rainbow) { s[kind] = TokenStyle(c(color)) }
        s[.logError] = TokenStyle(c(p.deleted), bold: true)
        s[.logWarning] = TokenStyle(c(p.changed), bold: true)
        s[.logInfo] = TokenStyle(c(p.function))
        s[.logDebug] = TokenStyle(c(p.comment))
        styles = s
    }
}
