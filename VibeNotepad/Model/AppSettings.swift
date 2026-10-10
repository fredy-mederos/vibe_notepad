import AppKit
import Observation
import SwiftUI
import VibeCore

/// How a Markdown document is shown.
nonisolated enum MarkdownMode: String, CaseIterable, Codable, Sendable {
    case editor
    case split
    case preview

    var title: String {
        switch self {
        case .editor: "Editor"
        case .split: "Split"
        case .preview: "Preview"
        }
    }

    var symbol: String {
        switch self {
        case .editor: "chevron.left.forwardslash.chevron.right"
        case .split: "rectangle.split.2x1"
        case .preview: "eye"
        }
    }
}

/// User preferences, persisted in `UserDefaults`.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum PreviewFont: String, CaseIterable, Identifiable {
        case system, serif, rounded, mono
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "San Francisco"
            case .serif: "New York (Serif)"
            case .rounded: "SF Rounded"
            case .mono: "SF Mono"
            }
        }
        var css: String {
            switch self {
            case .system: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
            case .serif: "ui-serif, 'New York', Georgia, serif"
            case .rounded: "ui-rounded, 'SF Pro Rounded', -apple-system, sans-serif"
            case .mono: "ui-monospace, 'SF Mono', Menlo, monospace"
            }
        }
    }

    private let defaults = UserDefaults.standard

    // MARK: Appearance
    var appearance: Appearance { didSet { save(appearance.rawValue, "appearance"); applyAppearance() } }
    var lightThemeID: String { didSet { save(lightThemeID, "lightThemeID") } }
    var darkThemeID: String { didSet { save(darkThemeID, "darkThemeID") } }

    // MARK: Editor
    /// Font family name; empty means the system monospaced font (SF Mono).
    var fontName: String { didSet { save(fontName, "fontName") } }
    var fontSize: Double { didSet { save(fontSize, "fontSize") } }
    var lineHeight: Double { didSet { save(lineHeight, "lineHeight") } }
    var tabWidth: Int { didSet { save(tabWidth, "tabWidth") } }
    var insertSpaces: Bool { didSet { save(insertSpaces, "insertSpaces") } }
    var detectIndentation: Bool { didSet { save(detectIndentation, "detectIndentation") } }
    var wrapLines: Bool { didSet { save(wrapLines, "wrapLines") } }
    var showLineNumbers: Bool { didSet { save(showLineNumbers, "showLineNumbers") } }
    var highlightCurrentLine: Bool { didSet { save(highlightCurrentLine, "highlightCurrentLine") } }
    var showInvisibles: Bool { didSet { save(showInvisibles, "showInvisibles") } }
    /// Marks lines that differ from the version staged in git, next to the line numbers.
    var showGitChanges: Bool { didSet { save(showGitChanges, "showGitChanges") } }
    var autoCloseBrackets: Bool { didSet { save(autoCloseBrackets, "autoCloseBrackets") } }
    var spellCheckProse: Bool { didSet { save(spellCheckProse, "spellCheckProse") } }

    // MARK: Markdown
    var markdownMode: MarkdownMode { didSet { save(markdownMode.rawValue, "markdownMode") } }
    var previewFont: PreviewFont { didSet { save(previewFont.rawValue, "previewFont") } }
    var previewFontSize: Double { didSet { save(previewFontSize, "previewFontSize") } }
    var syncScroll: Bool { didSet { save(syncScroll, "syncScroll") } }

    // MARK: Session
    var restoreSession: Bool { didSet { save(restoreSession, "restoreSession") } }
    var hotExit: Bool { didSet { save(hotExit, "hotExit") } }
    var reloadChangedFiles: Bool { didSet { save(reloadChangedFiles, "reloadChangedFiles") } }

    // MARK: Window
    /// Whether the sidebar is open. The status bar follows it, so collapsing the sidebar
    /// leaves just the tabs and the text.
    var showsSidebar: Bool { didSet { save(showsSidebar, "showsSidebar") } }

    /// Whether the app currently renders dark (system setting or forced appearance).
    private(set) var effectiveIsDark: Bool = false
    private var appearanceObservation: NSKeyValueObservation?

    private init() {
        let d = UserDefaults.standard
        func value<T>(_ key: String, _ fallback: T) -> T { d.object(forKey: key) as? T ?? fallback }
        appearance = Appearance(rawValue: value("appearance", "system")) ?? .system
        lightThemeID = value("lightThemeID", Themes.vibeDay.id)
        darkThemeID = value("darkThemeID", Themes.vibeNight.id)
        fontName = value("fontName", "")
        fontSize = value("fontSize", 13.5)
        lineHeight = value("lineHeight", 1.45)
        tabWidth = value("tabWidth", 4)
        insertSpaces = value("insertSpaces", true)
        detectIndentation = value("detectIndentation", true)
        wrapLines = value("wrapLines", true)
        showLineNumbers = value("showLineNumbers", true)
        highlightCurrentLine = value("highlightCurrentLine", true)
        showInvisibles = value("showInvisibles", false)
        showGitChanges = value("showGitChanges", true)
        autoCloseBrackets = value("autoCloseBrackets", true)
        spellCheckProse = value("spellCheckProse", false)
        markdownMode = MarkdownMode(rawValue: value("markdownMode", "split")) ?? .split
        previewFont = PreviewFont(rawValue: value("previewFont", "system")) ?? .system
        previewFontSize = value("previewFontSize", 15.0)
        syncScroll = value("syncScroll", true)
        restoreSession = value("restoreSession", true)
        hotExit = value("hotExit", true)
        reloadChangedFiles = value("reloadChangedFiles", true)
        showsSidebar = value("showsSidebar", true)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: Themes

    var lightTheme: Theme { Themes.theme(id: lightThemeID) ?? Themes.vibeDay }
    var darkTheme: Theme { Themes.theme(id: darkThemeID) ?? Themes.vibeNight }

    /// A theme being previewed from the theme palette (not persisted).
    var previewThemeID: String?

    /// The theme for the current effective appearance (or the one being previewed).
    var theme: Theme {
        if let previewThemeID, let preview = Themes.theme(id: previewThemeID) { return preview }
        return effectiveIsDark ? darkTheme : lightTheme
    }

    /// Picks `theme` for the appearance it belongs to and switches to that appearance when it differs.
    func select(theme: Theme) {
        if theme.isDark { darkThemeID = theme.id } else { lightThemeID = theme.id }
        if theme.isDark != effectiveIsDark {
            appearance = theme.isDark ? .dark : .light
        }
    }

    /// Starts tracking the system appearance; call once at launch.
    func startObservingAppearance() {
        applyAppearance()
        effectiveIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            Task { @MainActor in
                let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                if AppSettings.shared.effectiveIsDark != dark { AppSettings.shared.effectiveIsDark = dark }
            }
        }
    }

    private func applyAppearance() {
        guard NSApp != nil else { return }
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Fonts

    var editorFont: NSFont {
        let size = CGFloat(fontSize)
        if !fontName.isEmpty, let font = NSFont(name: fontName, size: size) { return font }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Installed fixed-pitch font families for the font picker.
    static let monospacedFamilies: [String] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let members = manager.availableMembers(ofFontFamily: family), let first = members.first,
                  let name = first[0] as? String, let font = NSFont(name: name, size: 12) else { return false }
            return font.isFixedPitch || family.localizedCaseInsensitiveContains("mono") || family.localizedCaseInsensitiveContains("code")
        }.sorted()
    }()

    func zoom(by delta: Double) {
        fontSize = min(48, max(8, fontSize + delta))
        previewFontSize = min(40, max(10, previewFontSize + delta))
    }

    func resetZoom() {
        fontSize = 13.5
        previewFontSize = 15
    }
}
