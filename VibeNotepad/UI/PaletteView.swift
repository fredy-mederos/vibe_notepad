import AppKit
import SwiftUI
import VibeCore

/// One row in the palette.
struct PaletteItem: Identifiable {
    enum Icon {
        case language(LanguageID)
        case symbol(String)
        case theme(Theme)
    }

    let id: String
    var title: String
    var subtitle: String?
    var icon: Icon
    var matches: [Int] = []
    var trailing: String?
    var badge: String?
    var isCurrent = false
    var action: () -> Void
    /// Called when the row becomes selected (live preview).
    var preview: (() -> Void)?
}

/// Dimmed backdrop + palette, shown above everything.
struct PaletteOverlay: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ZStack(alignment: .top) {
            if let mode = workspace.palette {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { workspace.hidePalette() }
                    .transition(.opacity)
                PaletteView(mode: mode)
                    .id(mode)
                    .padding(.top, 64)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95, anchor: .top).combined(with: .opacity).combined(with: .offset(y: -8)),
                        removal: .scale(scale: 0.97, anchor: .top).combined(with: .opacity)))
            }
        }
    }
}

struct PaletteView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    let mode: PaletteMode

    @State private var query = ""
    @State private var selection = 0
    @State private var folderFiles: [URL] = []
    @State private var symbols: [DocumentSymbol] = []
    @State private var originalSelection: NSRange?
    @State private var originalScroll: NSPoint?
    @State private var committed = false
    @State private var keyMonitor: Any?
    @FocusState private var isFocused: Bool
    @Namespace private var namespace

    var body: some View {
        let rows = items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: modeSymbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.bounce, value: mode)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($isFocused)
                    .onSubmit { run(rows) }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if !rows.isEmpty {
                Divider().opacity(0.5)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                                PaletteRow(item: item, isSelected: index == selection, namespace: namespace)
                                    .onTapGesture {
                                        selection = index
                                        run(rows)
                                    }
                                    .onHover { hovering in
                                        if hovering, selection != index {
                                            selection = index
                                        }
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(420, CGFloat(rows.count) * (rows.contains { $0.subtitle != nil } ? 48 : 36) + 12))
                    .scrollIndicators(.automatic)
                    .onChange(of: selection) { _, value in
                        guard value < rows.count else { return }
                        withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(rows[value].id) }
                        rows[value].preview?()
                    }
                }
            } else if let hint = emptyHint {
                Divider().opacity(0.5)
                Text(hint)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }

            Divider().opacity(0.5)
            HStack(spacing: 14) {
                Label("navigate", systemImage: "arrow.up.arrow.down")
                Label("open", systemImage: "return")
                Label("dismiss", systemImage: "escape")
                Spacer()
                Text(footerHint)
            }
            .labelStyle(PaletteHintLabelStyle())
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .frame(width: 660)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .onAppear {
            query = workspace.paletteSeed
            prepare()
            installKeyMonitor()
            DispatchQueue.main.async { isFocused = true }
        }
        .onDisappear {
            removeKeyMonitor()
            if !committed { cancelPreview() }
        }
        .onChange(of: query) {
            selection = 0
            if query.hasPrefix(">"), mode != .commands { switchMode(.commands, seed: String(query.dropFirst())) }
            if query.hasPrefix(":"), mode == .files { switchMode(.goToLine, seed: String(query.dropFirst())) }
            if query.hasPrefix("@"), mode == .files { switchMode(.symbols, seed: String(query.dropFirst())) }
        }
    }

    // MARK: Mode details

    private var placeholder: String {
        switch mode {
        case .files: "Open a file — type a name, “name:42” to jump to a line"
        case .commands: "Run a command…"
        case .goToLine: "Line number (and :column)"
        case .symbols: "Go to symbol…"
        case .language: "Syntax highlighting for this file…"
        case .theme: "Choose a theme…"
        }
    }

    private var modeSymbol: String {
        switch mode {
        case .files: "magnifyingglass"
        case .commands: "command"
        case .goToLine: "arrow.right.to.line"
        case .symbols: "list.bullet.indent"
        case .language: "chevron.left.forwardslash.chevron.right"
        case .theme: "paintpalette"
        }
    }

    private var footerHint: String {
        switch mode {
        case .files: "> commands  ·  : line  ·  @ symbol"
        case .commands: "\(workspace.commands.count) commands"
        case .goToLine: "\(workspace.selectedDocument?.cursor.lineCount ?? 0) lines"
        case .symbols: "\(symbols.count) symbols"
        case .language: "\(LanguageRegistry.all.count) languages"
        case .theme: "Live preview"
        }
    }

    private var emptyHint: String? {
        switch mode {
        case .goToLine:
            return "Type a line number between 1 and \(workspace.selectedDocument?.cursor.lineCount ?? 1)"
        case .symbols where symbols.isEmpty:
            return "No symbols found in this file"
        default:
            return query.isEmpty ? nil : "No matches"
        }
    }

    // MARK: Items

    private var items: [PaletteItem] {
        switch mode {
        case .files: fileItems
        case .commands: commandItems
        case .goToLine: lineItems
        case .symbols: symbolItems
        case .language: languageItems
        case .theme: themeItems
        }
    }

    private var fileItems: [PaletteItem] {
        let (needle, line, column) = parseFileQuery(query)
        var seen = Set<String>()
        var candidates: [(url: URL?, document: EditorDocument?, badge: String?, date: Date?)] = []
        for document in workspace.documents {
            let key = document.path ?? document.id.uuidString
            guard seen.insert(key).inserted else { continue }
            candidates.append((document.fileURL, document, document.id == workspace.selectedID ? "current" : "open", nil))
        }
        for item in workspace.recents.all where !workspace.recents.isMissing(item.path) {
            guard seen.insert(item.path).inserted else { continue }
            candidates.append((item.url, nil, item.pinned ? "pinned" : nil, item.lastOpened))
        }
        for url in folderFiles {
            guard seen.insert(url.path).inserted else { continue }
            candidates.append((url, nil, nil, nil))
        }

        var scored: [(PaletteItem, Int)] = []
        for (index, candidate) in candidates.enumerated() {
            let name = candidate.document?.displayName ?? candidate.url?.lastPathComponent ?? ""
            let parent = candidate.url?.abbreviatedParentPath ?? "Unsaved"
            var matches: [Int] = []
            var score = 1000 - index
            if !needle.isEmpty {
                if let match = FuzzyMatcher.match(needle, in: name) {
                    matches = match.positions
                    score = match.score + 40
                } else if let url = candidate.url, let match = FuzzyMatcher.match(needle, in: Self.shortPath(url)) {
                    score = match.score
                } else {
                    continue
                }
                if candidate.document != nil { score += 8 }
            }
            let language = candidate.document?.language ?? LanguageRegistry.detect(path: candidate.url?.path ?? name)
            let document = candidate.document
            let url = candidate.url
            let item = PaletteItem(
                id: url?.path ?? document?.id.uuidString ?? name,
                title: name,
                subtitle: parent,
                icon: .language(language),
                matches: matches,
                trailing: candidate.date.map { RelativeTime.short($0) },
                badge: candidate.badge
            ) {
                let target: EditorDocument?
                if let document {
                    workspace.select(document)
                    target = document
                } else if let url {
                    target = workspace.open(url: url)
                } else {
                    target = nil
                }
                if let line, let target { target.navigate(toLine: line, column: column) }
            }
            scored.append((item, score))
        }
        if needle.isEmpty { return scored.prefix(80).map(\.0) }
        return scored.sorted { $0.1 > $1.1 }.prefix(80).map(\.0)
    }

    /// "folder/file.ext" — enough context for path queries without matching every long absolute path.
    private static func shortPath(_ url: URL) -> String {
        url.pathComponents.suffix(2).joined(separator: "/")
    }

    private func parseFileQuery(_ text: String) -> (String, Int?, Int?) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 3, let line = Int(parts[parts.count - 2]), let column = Int(parts[parts.count - 1]) {
            return (parts.dropLast(2).joined(separator: ":"), line, column)
        }
        if parts.count >= 2, let line = Int(parts[parts.count - 1]) {
            return (parts.dropLast().joined(separator: ":"), line, nil)
        }
        return (text, nil, nil)
    }

    private var commandItems: [PaletteItem] {
        let commands = workspace.commands
        let needle = query.trimmingCharacters(in: .whitespaces)
        var scored: [(PaletteItem, Int)] = []
        for (index, command) in commands.enumerated() {
            var matches: [Int] = []
            var score = 1000 - index
            if !needle.isEmpty {
                if let match = FuzzyMatcher.match(needle, in: command.title) {
                    matches = match.positions
                    score = match.score + 20
                } else if let match = FuzzyMatcher.match(needle, in: "\(command.category) \(command.title)") {
                    score = match.score
                } else {
                    continue
                }
            }
            scored.append((PaletteItem(id: command.id, title: command.title, subtitle: command.category, icon: .symbol(command.symbol),
                                       matches: matches, trailing: command.shortcut, action: command.action), score))
        }
        return needle.isEmpty ? scored.map(\.0) : scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private var lineItems: [PaletteItem] {
        guard let document = workspace.selectedDocument else { return [] }
        let parts = query.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let first = parts.first, let line = first else { return [] }
        let column = parts.count > 1 ? parts[1] : nil
        let total = document.cursor.lineCount
        let clamped = min(max(1, line), max(1, total))
        let title = column.map { "Go to line \(clamped), column \($0)" } ?? "Go to line \(clamped)"
        return [PaletteItem(id: "line", title: title, subtitle: "of \(total)", icon: .symbol("arrow.right.to.line")) {
            document.navigate(toLine: clamped, column: column)
        }]
    }

    private var symbolItems: [PaletteItem] {
        guard let document = workspace.selectedDocument else { return [] }
        let needle = query.trimmingCharacters(in: .whitespaces)
        var scored: [(PaletteItem, Int)] = []
        for symbol in symbols {
            var matches: [Int] = []
            var score = -symbol.line
            if !needle.isEmpty {
                guard let match = FuzzyMatcher.match(needle, in: symbol.name) else { continue }
                matches = match.positions
                score = match.score
            }
            let icon: String = switch symbol.kind {
            case .function: "function"
            case .type: "cube"
            case .heading: "number"
            case .section: "square.split.1x2"
            case .key: "key"
            case .variable: "x.squareroot"
            case .target: "target"
            }
            let indent = symbol.kind == .heading ? String(repeating: "   ", count: max(0, symbol.level - 1)) : ""
            let line = symbol.line
            scored.append((PaletteItem(
                id: "\(symbol.line)-\(symbol.name)",
                title: indent + symbol.name,
                subtitle: nil,
                icon: .symbol(icon),
                matches: matches.map { $0 + indent.count },
                trailing: "\(symbol.line + 1)",
                action: { document.navigate(toLine: line + 1, column: nil) },
                preview: { previewLine(line, in: document) }
            ), score))
        }
        return needle.isEmpty ? scored.map(\.0) : scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private var languageItems: [PaletteItem] {
        guard let document = workspace.selectedDocument else { return [] }
        let needle = query.trimmingCharacters(in: .whitespaces)
        let all = LanguageRegistry.all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var scored: [(PaletteItem, Int)] = []
        for info in all {
            var matches: [Int] = []
            var score = info.id == document.language ? 10_000 : 0
            if !needle.isEmpty {
                if let match = FuzzyMatcher.match(needle, in: info.name) {
                    matches = match.positions
                    score = match.score + 10
                } else if info.aliases.contains(needle.lowercased()) || info.extensions.contains(needle.lowercased()) {
                    score = 50
                } else {
                    continue
                }
            }
            let extensions = info.extensions.prefix(4).map { ".\($0)" }.joined(separator: " ")
            scored.append((PaletteItem(id: info.id.rawValue, title: info.name, subtitle: extensions.isEmpty ? nil : extensions,
                                       icon: .language(info.id), matches: matches, isCurrent: info.id == document.language) {
                document.language = info.id
                document.languageIsManual = true
                if let path = document.path {
                    workspace.recents.update(path) { $0.language = info.id }
                }
            }, score))
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private var themeItems: [PaletteItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let current = settings.theme.id
        var result: [PaletteItem] = []
        for theme in Themes.all {
            var matches: [Int] = []
            if !needle.isEmpty {
                guard let match = FuzzyMatcher.match(needle, in: theme.name) else { continue }
                matches = match.positions
            }
            result.append(PaletteItem(id: theme.id, title: theme.name, subtitle: theme.isDark ? "Dark" : "Light", icon: .theme(theme),
                                      matches: matches, isCurrent: theme.id == current,
                                      action: { settings.previewThemeID = nil; settings.select(theme: theme) },
                                      preview: { withAnimation(.easeInOut(duration: 0.2)) { settings.previewThemeID = theme.id } }))
        }
        return result
    }

    // MARK: Actions

    private func run(_ rows: [PaletteItem]) {
        guard selection < rows.count else { return }
        let item = rows[selection]
        committed = true
        workspace.hidePalette(refocus: mode != .commands)
        DispatchQueue.main.async { item.action() }
    }

    private func switchMode(_ newMode: PaletteMode, seed: String) {
        workspace.showPalette(newMode, seed: seed)
    }

    private func prepare() {
        guard let document = workspace.selectedDocument else {
            if mode == .files { loadFolderFiles(around: workspace.recents.recent.first?.url.deletingLastPathComponent()) }
            return
        }
        if let editor = document.loadedEditor {
            originalSelection = editor.textView.selectedRange()
            originalScroll = editor.scrollView.contentView.bounds.origin
        }
        switch mode {
        case .symbols:
            symbols = SymbolExtractor.symbols(in: document.text, language: document.language)
            if let editor = document.loadedEditor {
                let caretLine = editor.engine.lineIndex(containing: editor.textView.selectedRange().location)
                if query.isEmpty, let nearest = symbols.lastIndex(where: { $0.line <= caretLine }) { selection = nearest }
            }
        case .files:
            loadFolderFiles(around: document.fileURL?.deletingLastPathComponent())
        case .theme:
            if let index = Themes.all.firstIndex(where: { $0.id == settings.theme.id }) { selection = index }
        default:
            break
        }
    }

    private func previewLine(_ line: Int, in document: EditorDocument) {
        guard let editor = document.loadedEditor else { return }
        let start = editor.engine.lineStart(line)
        editor.scrollToCenter(NSRange(location: start, length: 0))
    }

    private func cancelPreview() {
        if settings.previewThemeID != nil {
            withAnimation(.easeInOut(duration: 0.2)) { settings.previewThemeID = nil }
        }
        if mode == .symbols, let editor = workspace.selectedDocument?.loadedEditor, let origin = originalScroll {
            editor.scrollView.contentView.scroll(to: origin)
            editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
            if let originalSelection { editor.textView.setSelectedRange(originalSelection) }
        }
    }

    /// Lists files near the current one so Quick Open can reach siblings that were never opened.
    private func loadFolderFiles(around directory: URL?) {
        guard let directory else { return }
        Task.detached(priority: .userInitiated) {
            let files = FolderScanner.files(in: directory, maxDepth: 3, limit: 4000)
            await MainActor.run { folderFiles = files }
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 126: // up
                if selection > 0 { selection -= 1 }
                return nil
            case 125: // down
                if selection < items.count - 1 { selection += 1 }
                return nil
            case 53: // escape
                workspace.hidePalette()
                return nil
            default:
                if event.modifierFlags.contains(.control), let chars = event.charactersIgnoringModifiers {
                    if chars == "n", selection < items.count - 1 { selection += 1; return nil }
                    if chars == "p", selection > 0 { selection -= 1; return nil }
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 11) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                HighlightedText(text: item.title, positions: item.matches, font: .system(size: 13, weight: .medium),
                                highlight: isSelected ? .primary : .accentColor)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            if item.isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.tint)
            }
            if let badge = item.badge {
                Text(badge)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.primary.opacity(0.08)))
            }
            if let trailing = item.trailing {
                KeyHint(keys: trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .matchedGeometryEffect(id: "palette-selection", in: namespace)
            }
        }
        .contentShape(Rectangle())
        .animation(.snappy(duration: 0.16), value: isSelected)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.icon {
        case .language(let language):
            FileIcon(language: language, size: 24)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.07)))
        case .theme(let theme):
            ThemeSwatch(theme: theme)
                .frame(width: 24, height: 24)
        }
    }
}

/// Tiny theme preview: background with three syntax colors.
struct ThemeSwatch: View {
    let theme: Theme

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(theme.background.color)
            .overlay {
                HStack(spacing: 2) {
                    ForEach([TokenKind.keyword, .string, .function], id: \.self) { kind in
                        Capsule().fill((theme.style(for: kind)?.color ?? theme.foreground).color).frame(width: 3.5, height: 12)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
    }
}

private struct PaletteHintLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9.5, weight: .semibold))
            configuration.title
        }
    }
}

/// Enumerates files under a folder for Quick Open (skipping VCS and build folders).
enum FolderScanner {
    /// Folders too broad to crawl: scanning them is slow, and walking into Desktop, Documents,
    /// Photos or Mail from the home folder would trigger macOS privacy prompts.
    nonisolated static func isTooBroad(_ directory: URL) -> Bool {
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        if ["/", home, "/Users", "/Volumes", "/System", "/Library", "/Applications", "/private", "/usr", "/opt", "/bin", "/sbin"].contains(path) {
            return true
        }
        return path.hasPrefix(home + "/Library/") || path == home + "/Library" || path.hasPrefix("/System/") || path.hasPrefix("/Library/")
    }

    nonisolated static func files(in directory: URL, maxDepth: Int, limit: Int) -> [URL] {
        guard !isTooBroad(directory) else { return [] }
        let skipped: Set<String> = [".git", ".svn", ".hg", "node_modules", "Pods", "DerivedData", ".build", "build", "dist", ".gradle", ".idea", ".next", "vendor", "__pycache__", ".venv", "venv", "Carthage", ".swiftpm", "target"]
        let binaryExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "ico", "icns", "pdf", "zip", "gz", "tar", "dmg", "app", "a", "o", "so", "dylib", "class", "jar", "mp3", "mp4", "mov", "wav", "ttf", "otf", "woff", "woff2", "sqlite", "db", "bin", "exe", "car"]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        let baseDepth = directory.pathComponents.count
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let name = url.lastPathComponent
            if values?.isDirectory == true {
                if skipped.contains(name) || (name.hasPrefix(".") && name != ".github") || url.pathComponents.count - baseDepth >= maxDepth {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, !binaryExtensions.contains(url.pathExtension.lowercased()), name != ".DS_Store" else { continue }
            result.append(url.canonicalFileURL)
            if result.count >= limit { break }
        }
        return result
    }
}
