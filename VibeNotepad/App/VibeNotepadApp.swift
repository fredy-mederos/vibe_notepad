import SwiftUI
import VibeCore

@main
struct VibeNotepadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var workspace = Workspace.shared
    @State private var settings = AppSettings.shared

    var body: some Scene {
        Window("Vibe Notepad", id: "main") {
            MainView()
                .environment(workspace)
                .environment(settings)
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(workspace: workspace, settings: settings)
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(workspace)
        }
    }
}

/// Menu bar commands. Shortcuts follow Sublime Text where macOS conventions allow.
struct AppCommands: Commands {
    let workspace: Workspace
    let settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    private var editor: EditorController? { workspace.activeEditor }
    private var document: EditorDocument? { workspace.selectedDocument }
    private var updater: AppUpdater { .shared }

    var body: some Commands {
        // The menus exist even when the window doesn't (it was closed before the last quit), so files
        // and links that arrive at launch can still bring the window up.
        let _ = AppDelegate.shared?.openMainWindow = { [openWindow] in openWindow(id: "main") }
        CommandGroup(after: .appInfo) {
            Button(updater.isChecking ? "Checking for Updates…" : "Check for Updates…") { updater.checkFromMenu() }
                .disabled(updater.isChecking)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Tab") { workspace.newDocument() }
                .keyboardShortcut("t")
            Button("New File") { workspace.newDocument() }
                .keyboardShortcut("n")
            Button("Open…") { workspace.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Open Folder…") { workspace.showOpenFolderPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Open Enclosing Folder…") { if let url = document?.fileURL { workspace.showOpenFolderPanel(revealing: url) } }
                .disabled(document?.fileURL == nil)
            Menu("Open Recent") {
                ForEach(workspace.recents.all.prefix(20)) { item in
                    Button(item.name) { workspace.open(url: item.url) }
                        .disabled(workspace.recents.isMissing(item.path))
                }
                if !workspace.recentProjects.isEmpty {
                    Section("Folders") {
                        ForEach(workspace.recentProjects, id: \.self) { path in
                            let url = URL(fileURLWithPath: path)
                            Button(url.lastPathComponent) { workspace.openProject(url) }
                                .disabled(!url.isFolder)
                        }
                    }
                }
                Divider()
                Button("Clear Recent Files") { workspace.recents.clearRecent() }
                if !workspace.recentProjects.isEmpty {
                    Button("Clear Recent Folders") { workspace.clearRecentProjects() }
                }
            }
            Divider()
            Button("Quick Open…") { workspace.showPalette(.files) }
                .keyboardShortcut("p")
            Button("Reopen Closed Tab") { workspace.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { workspace.closeSelected() }
                .keyboardShortcut("w")
            if workspace.projects.count > 1 {
                Menu("Close Folder") {
                    ForEach(workspace.projects, id: \.sidebarItem) { project in
                        Button(project.name) { workspace.closeProject(project) }
                    }
                    Divider()
                    Button("Close All Folders") { workspace.closeAllProjects() }
                }
            } else {
                Button("Close Folder") { workspace.closeAllProjects() }
                    .disabled(workspace.projects.isEmpty)
            }
            Divider()
            Button("Save") { workspace.saveSelected() }
                .keyboardShortcut("s")
                .disabled(document == nil)
            Button("Save As…") {
                if let document { Task { await workspace.saveAs(document) } }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(document == nil)
            Button("Save All") { workspace.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Revert to Saved") { if let document { workspace.revert(document) } }
                .disabled(document?.fileURL == nil)
            Divider()
            Button("Reveal in Finder") { workspace.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(document?.fileURL == nil)
            Button("Copy File Path") { workspace.copyPath() }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                .disabled(document?.fileURL == nil)
            Button("Pin / Unpin in Sidebar") { workspace.togglePin() }
                .disabled(document?.fileURL == nil)
        }

        // No printing: frees ⌘P for Quick Open.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") { workspace.showFindBar() }
                    .keyboardShortcut("f")
                Button("Find and Replace…") { workspace.showFindBar(replace: true) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Find Next") { workspace.findNext(forward: true) }
                    .keyboardShortcut("g")
                Button("Find Previous") { workspace.findNext(forward: false) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") { workspace.useSelectionForFind() }
                    .keyboardShortcut("e")
            }
            .disabled(document == nil)
            Menu("Line") {
                Button("Indent") { editor?.indent() }
                    .keyboardShortcut("]")
                Button("Outdent") { editor?.outdent() }
                    .keyboardShortcut("[")
                Divider()
                Button("Move Line Up") { editor?.moveLines(up: true) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                Button("Move Line Down") { editor?.moveLines(up: false) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                Button("Duplicate Line") { editor?.duplicate() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Delete Line") { editor?.deleteLines() }
                    .keyboardShortcut("k", modifiers: [.control, .shift])
                Button("Join Lines") { editor?.joinLines() }
                    .keyboardShortcut("j")
                Button("Select Line") { editor?.selectLine() }
                    .keyboardShortcut("l")
                Divider()
                Button("Sort Lines") { editor?.sortLines() }
                Button("Trim Trailing Whitespace") { _ = editor?.trimTrailingWhitespace() }
            }
            .disabled(document == nil)
            Button("Toggle Comment") { editor?.toggleComment() }
                .keyboardShortcut("/")
                .disabled(document == nil)
            Menu("Code Folding") {
                Button("Fold") { editor?.foldAtCaret() }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                Button("Unfold") { editor?.unfoldAtCaret() }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                Divider()
                Button("Fold All") { editor?.foldAll() }
                    .keyboardShortcut("[", modifiers: [.command, .option, .shift])
                Button("Unfold All") { editor?.unfoldAll() }
                    .keyboardShortcut("]", modifiers: [.command, .option, .shift])
                Divider()
                ForEach(1..<4) { level in
                    Button("Fold Level \(level)") { editor?.foldAll(level: level) }
                }
            }
            .disabled(editor?.supportsFolding != true)
            Menu("Convert Case") {
                Button("UPPERCASE") { editor?.transformSelection("Uppercase") { $0.uppercased() } }
                    .keyboardShortcut("u", modifiers: [.command, .control])
                Button("lowercase") { editor?.transformSelection("Lowercase") { $0.lowercased() } }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                Button("Title Case") { editor?.transformSelection("Title Case") { $0.capitalized } }
                Button("camelCase") { editor?.transformSelection("camelCase") { TextCase.camel($0) } }
                Button("snake_case") { editor?.transformSelection("snake_case") { TextCase.snake($0) } }
                Button("kebab-case") { editor?.transformSelection("kebab-case") { TextCase.kebab($0) } }
            }
            .disabled(document == nil)
            Menu("JSON") {
                Button("Format JSON") { if let editor { workspace.runJSON(editor, minify: false) } }
                    .keyboardShortcut("j", modifiers: [.command, .option])
                Button("Minify JSON") { if let editor { workspace.runJSON(editor, minify: true) } }
            }
            .disabled(document == nil)
        }

        CommandGroup(before: .sidebar) {
            Button("Command Palette…") { workspace.showPalette(.commands) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Menu("Markdown") {
                Button("Editor Only") { workspace.setMarkdownMode(.editor) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Editor & Preview") { workspace.setMarkdownMode(.split) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Preview Only") { workspace.setMarkdownMode(.preview) }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Divider()
                Button("Toggle Preview") { workspace.cycleMarkdownPreview() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            .disabled(document?.isMarkdown != true)
            Button("Toggle Sidebar Files") {
                NotificationCenter.default.post(name: .toggleSidebarRequest, object: nil)
            }
            .keyboardShortcut("b")
            Divider()
            Button("Split Right") { workspace.splitPane(.horizontal) }
                .keyboardShortcut("\\")
                .disabled(workspace.paneCount >= Workspace.maxPanes)
            Button("Split Down") { workspace.splitPane(.vertical) }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                .disabled(workspace.paneCount >= Workspace.maxPanes)
            Button("Close Pane") { workspace.closePane() }
                .keyboardShortcut("w", modifiers: [.command, .control])
                .disabled(!workspace.isSplit)
            Menu("Editor Layout") {
                ForEach(PaneLayout.Preset.allCases, id: \.self) { preset in
                    Button(preset.title) { workspace.applyLayout(preset) }
                }
            }
            Menu("Focus Pane") {
                Button("Left") { workspace.focusPane(toward: .left) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Right") { workspace.focusPane(toward: .right) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Above") { workspace.focusPane(toward: .up) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Below") { workspace.focusPane(toward: .down) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button("Next Pane") { workspace.focusNextPane() }
                    .keyboardShortcut("`", modifiers: [.command, .option])
                Button("Previous Pane") { workspace.focusNextPane(forward: false) }
                    .keyboardShortcut("`", modifiers: [.command, .option, .shift])
            }
            .disabled(!workspace.isSplit)
            Divider()
            Toggle("Word Wrap", isOn: Binding(
                get: { document?.wrapLines ?? settings.wrapLines },
                set: { document?.wrapLines = $0 }
            ))
            .disabled(document == nil)
            Toggle("Line Numbers", isOn: Binding(get: { settings.showLineNumbers }, set: { settings.showLineNumbers = $0 }))
            Toggle("Invisible Characters", isOn: Binding(get: { settings.showInvisibles }, set: { settings.showInvisibles = $0 }))
            Toggle("Minimap", isOn: Binding(get: { settings.showMinimap }, set: { settings.showMinimap = $0 }))
            Divider()
            Button("Zoom In") { settings.zoom(by: 1) }
                .keyboardShortcut("=")
            Button("Zoom Out") { settings.zoom(by: -1) }
                .keyboardShortcut("-")
            Button("Actual Size") { settings.resetZoom() }
                .keyboardShortcut("0")
            Divider()
            Menu("Theme") {
                Section("Dark") {
                    ForEach(Themes.dark) { theme in
                        Button(theme.name) { settings.select(theme: theme) }
                    }
                }
                Section("Light") {
                    ForEach(Themes.light) { theme in
                        Button(theme.name) { settings.select(theme: theme) }
                    }
                }
            }
            Divider()
        }

        CommandMenu("Go") {
            Button("Go to Line…") { workspace.showPalette(.goToLine) }
                .keyboardShortcut("g", modifiers: .control)
                .disabled(document == nil)
            Button("Go to Symbol…") { workspace.showPalette(.symbols) }
                .keyboardShortcut("r")
                .disabled(document == nil)
            Button("Go to File…") { workspace.showPalette(.files) }
            Divider()
            Button("Next Tab") { workspace.selectNextTab(true) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { workspace.selectNextTab(false) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab ") { workspace.selectNextTab(true) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab ") { workspace.selectNextTab(false) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            ForEach(1..<10) { index in
                Button("Tab \(index)") { workspace.selectTab(at: index - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")))
            }
        }
    }
}
