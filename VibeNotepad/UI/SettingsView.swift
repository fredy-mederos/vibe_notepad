import AppKit
import SwiftUI
import VibeCore

/// Preferences window (⌘,).
struct SettingsView: View {
    /// The tab shown last, so Settings reopens where you left it.
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Editor", systemImage: "character.cursor.ibeam", value: "editor") { EditorSettings() }
            Tab("Themes", systemImage: "paintpalette", value: "themes") { ThemeSettings() }
            Tab("Markdown", systemImage: "text.document", value: "markdown") { MarkdownSettings() }
        }
        .frame(width: 640)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppSettings.Appearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            .pickerStyle(.segmented)

            Section("Session") {
                Toggle("Reopen files from the last session", isOn: $settings.restoreSession)
                Toggle("Keep unsaved changes when quitting (hot exit)", isOn: $settings.hotExit)
                    .disabled(!settings.restoreSession)
                Text("Like Sublime Text: quit any time, your unsaved buffers come back next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Reload files changed by other apps", isOn: $settings.reloadChangedFiles)
            }

            Section("Command line") {
                CommandLineToolRow()
            }

            AboutSection()
            UpdatesSection()
        }
        .formStyle(.grouped)
        .frame(minHeight: 630)
    }
}

/// Installs the `vibeNotePad` shell command.
struct CommandLineToolRow: View {
    @State private var status = CommandLineTool.status()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("vibeNotePad command")
                        .font(.body.weight(.medium))
                    Text(status.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(status.isInstalled ? "Reinstall" : "Install") {
                    status = CommandLineTool.install()
                }
            }
            Text("Open files from Terminal or let an agent open them: `vibeNotePad README.md:42` or the link `vibeNotePad://open?path=/abs/file&line=42`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EditorSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Font") {
                Picker("Family", selection: $settings.fontName) {
                    Text("SF Mono (System)").tag("")
                    Divider()
                    ForEach(AppSettings.monospacedFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $settings.fontSize, in: 9...28, step: 0.5)
                        Text(String(format: "%.1f pt", settings.fontSize))
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                LabeledContent("Line height") {
                    HStack {
                        Slider(value: $settings.lineHeight, in: 1.0...2.2, step: 0.05)
                        Text(String(format: "%.2f×", settings.lineHeight))
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
            Section("Indentation") {
                Picker("Tab width", selection: $settings.tabWidth) {
                    ForEach([2, 3, 4, 8], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Insert spaces when pressing Tab", isOn: $settings.insertSpaces)
                Toggle("Detect indentation from file contents", isOn: $settings.detectIndentation)
            }
            Section("Display") {
                Toggle("Wrap long lines", isOn: $settings.wrapLines)
                Toggle("Show line numbers", isOn: $settings.showLineNumbers)
                Toggle("Highlight current line", isOn: $settings.highlightCurrentLine)
                Toggle("Show invisible characters", isOn: $settings.showInvisibles)
                Toggle("Show git changes next to line numbers", isOn: $settings.showGitChanges)
                Toggle("Show minimap", isOn: $settings.showMinimap)
            }
            Section("Typing") {
                Toggle("Auto-close brackets and quotes", isOn: $settings.autoCloseBrackets)
                Toggle("Check spelling in Markdown and text files", isOn: $settings.spellCheckProse)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 520)
    }
}

private struct ThemeSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ThemeGrid(title: "Dark", themes: Themes.dark, selectedID: settings.darkThemeID)
                ThemeGrid(title: "Light", themes: Themes.light, selectedID: settings.lightThemeID)
                Text("The app follows macOS appearance by default; pick one theme for light mode and one for dark mode. Change appearance in General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
        .frame(minHeight: 520)
    }
}

private struct ThemeGrid: View {
    @Environment(AppSettings.self) private var settings
    let title: String
    let themes: [Theme]
    let selectedID: String
    @Namespace private var namespace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                ForEach(themes) { theme in
                    ThemeCard(theme: theme, isSelected: theme.id == selectedID, namespace: namespace)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                settings.select(theme: theme)
                            }
                        }
                }
            }
        }
    }
}

private struct ThemeCard: View {
    let theme: Theme
    let isSelected: Bool
    let namespace: Namespace.ID
    @State private var isHovering = false

    private static let snippet = """
    // Vibe ✨
    let api = "https://vibe.dev"
    func greet(_ name: String) -> Int {
        return name.count * 42
    }
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ThemedSnippet.attributed(Self.snippet, language: .swift, theme: theme, size: 9.5))
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(theme.background.color)
            HStack {
                Text(theme.name)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.background.secondary)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .matchedGeometryEffect(id: "theme-selection", in: namespace)
            }
        }
        .scaleEffect(isHovering ? 1.025 : 1)
        .shadow(color: .black.opacity(isHovering ? 0.18 : 0.06), radius: isHovering ? 10 : 3, y: isHovering ? 5 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
    }
}

private struct MarkdownSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Open Markdown files in", selection: $settings.markdownMode) {
                ForEach(MarkdownMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            Section("Preview") {
                Picker("Font", selection: $settings.previewFont) {
                    ForEach(AppSettings.PreviewFont.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $settings.previewFontSize, in: 11...26, step: 1)
                        Text("\(Int(settings.previewFontSize)) px")
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                Toggle("Scroll the preview along with the editor", isOn: $settings.syncScroll)
            }
            Text("Tip: click a task checkbox in the preview to tick it in the file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(minHeight: 340)
    }
}
