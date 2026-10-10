import AppKit
import SwiftUI
import VibeCore

/// Pinned files, the project's file tree, then recent files, always one click away.
struct SidebarView: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage("sidebarProjectExpanded") private var projectExpanded = true
    @AppStorage("sidebarPinnedExpanded") private var pinnedExpanded = true
    @AppStorage("sidebarRecentExpanded") private var recentExpanded = true

    var body: some View {
        @Bindable var workspace = workspace
        let recents = workspace.recents
        let filter = workspace.sidebarFilter.trimmingCharacters(in: .whitespaces)
        let pinned = filtered(recents.pinned, filter)
        let recent = filtered(recents.recent, filter)

        List(selection: selection) {
            if !pinned.isEmpty {
                Section(isExpanded: expansion($pinnedExpanded, filtering: !filter.isEmpty)) {
                    ForEach(pinned) { item in
                        RecentFileRow(item: item, highlight: filter)
                            .tag(item.path)
                    }
                    .onMove { source, destination in
                        guard filter.isEmpty else { return }
                        withAnimation(.snappy) { recents.movePinned(from: source, to: destination) }
                    }
                } header: {
                    Text("Pinned")
                }
            }
            if let project = workspace.project {
                Section(isExpanded: expansion($projectExpanded, filtering: !filter.isEmpty)) {
                    if !filter.isEmpty {
                        let matches = projectMatches(project, filter)
                        if matches.isEmpty {
                            EmptySidebarHint(isFiltering: true)
                                .selectionDisabled()
                        } else {
                            ForEach(matches, id: \.file.relativePath) { match in
                                ProjectMatchRow(project: project, file: match.file, positions: match.positions)
                                    .tag(match.file.url.path)
                            }
                        }
                    } else if !project.exists {
                        Label("This folder was moved or deleted", systemImage: "questionmark.folder")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    } else {
                        ProjectTreeRows(project: project, folder: project.root.path)
                    }
                } header: {
                    ProjectSectionHeader(project: project)
                }
            }
            Section(isExpanded: expansion($recentExpanded, filtering: !filter.isEmpty)) {
                if recent.isEmpty {
                    EmptySidebarHint(isFiltering: !filter.isEmpty)
                        .selectionDisabled()
                } else {
                    ForEach(recent) { item in
                        RecentFileRow(item: item, highlight: filter)
                            .tag(item.path)
                    }
                }
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                    if !recents.recent.isEmpty {
                        Menu {
                            Button("Clear Recent Files", role: .destructive) {
                                withAnimation(.snappy) { recents.clearRecent() }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .animation(.snappy(duration: 0.32), value: recents.items)
        .searchable(text: $workspace.sidebarFilter, placement: .sidebar, prompt: "Filter files")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter()
        }
    }

    /// Selecting a row opens (or focuses) that file; selecting a project folder expands or collapses it.
    private var selection: Binding<String?> {
        Binding(
            get: { workspace.selectedDocument?.path },
            set: { path in
                guard let path else { return }
                if let project = workspace.project, project.isFolder(path) {
                    withAnimation(.snappy(duration: 0.2)) {
                        workspace.setFolder(path, expanded: !project.isExpanded(path))
                    }
                    return
                }
                if workspace.recents.isMissing(path) {
                    workspace.toast("“\((path as NSString).lastPathComponent)” no longer exists", symbol: "exclamationmark.triangle.fill", tint: .orange)
                    return
                }
                workspace.open(url: URL(fileURLWithPath: path))
            }
        )
    }

    /// Sections can be collapsed, but always show their matches while filtering.
    private func expansion(_ expanded: Binding<Bool>, filtering: Bool) -> Binding<Bool> {
        filtering ? .constant(true) : expanded
    }

    /// Project files matching the filter, best first.
    private func projectMatches(_ project: Project, _ filter: String) -> [(file: ProjectFile, positions: [Int])] {
        var scored: [(file: ProjectFile, score: Int, positions: [Int])] = []
        for file in project.files {
            if let match = FuzzyMatcher.match(filter, in: file.name) {
                scored.append((file, match.score + 40, match.positions))
            } else if let match = FuzzyMatcher.match(filter, in: file.relativePath) {
                scored.append((file, match.score, []))
            }
        }
        return scored.sorted { $0.score > $1.score }.prefix(50).map { ($0.file, $0.positions) }
    }

    private func filtered(_ items: [RecentFile], _ filter: String) -> [RecentFile] {
        guard !filter.isEmpty else { return items }
        return items
            .compactMap { item -> (RecentFile, Int)? in
                if let match = FuzzyMatcher.match(filter, in: item.name) { return (item, match.score + 40) }
                if let match = FuzzyMatcher.match(filter, in: item.path) { return (item, match.score) }
                return nil
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

/// One file in the sidebar.
struct RecentFileRow: View {
    @Environment(Workspace.self) private var workspace
    let item: RecentFile
    var highlight: String = ""
    @State private var isHovering = false

    var body: some View {
        let missing = workspace.recents.isMissing(item.path)
        let language = item.language ?? LanguageRegistry.detect(path: item.path)
        let openDocument = workspace.documents.first { $0.path == item.path }

        HStack(spacing: 9) {
            FileIcon(language: language, size: 22)
                .opacity(missing ? 0.35 : 1)
                .saturation(missing ? 0 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    name
                        .font(.system(size: 12.5, weight: openDocument != nil ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .strikethrough(missing)
                    if openDocument?.isDirty == true {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(item.url.abbreviatedParentPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 2)
            ZStack(alignment: .trailing) {
                if isHovering {
                    Button {
                        withAnimation(.snappy) { workspace.recents.togglePin(item.path) }
                    } label: {
                        Image(systemName: item.pinned ? "pin.slash.fill" : "pin.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(item.pinned ? Color.secondary : Color.accentColor)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.pinned ? "Unpin" : "Pin to the top")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else if missing {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .help("This file no longer exists")
                } else {
                    Text(item.pinned ? "" : RelativeTime.short(item.lastOpened))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
            }
            .frame(minWidth: 22, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.18)) { isHovering = hovering }
        }
        .help(item.path)
        .contextMenu {
            Button("Open", systemImage: "doc.text") { workspace.open(url: item.url) }
                .disabled(missing)
            Button(item.pinned ? "Unpin" : "Pin to Top", systemImage: item.pinned ? "pin.slash" : "pin") {
                withAnimation(.snappy) { workspace.recents.togglePin(item.path) }
            }
            Divider()
            Button("Reveal in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            .disabled(missing)
            Button("Copy Path", systemImage: "doc.on.clipboard") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
                workspace.toast("Copied path", symbol: "doc.on.clipboard.fill")
            }
            Divider()
            Button("Remove from List", systemImage: "minus.circle", role: .destructive) {
                withAnimation(.snappy) { workspace.recents.remove(item.path) }
            }
        }
    }

    @ViewBuilder
    private var name: some View {
        if !highlight.isEmpty, let match = FuzzyMatcher.match(highlight, in: item.name) {
            HighlightedText(text: item.name, positions: match.positions, font: .system(size: 12.5))
        } else {
            Text(item.name)
        }
    }
}

private struct EmptySidebarHint: View {
    let isFiltering: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: isFiltering ? "line.3.horizontal.decrease.circle" : "clock.arrow.circlepath")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
            Text(isFiltering ? "No matching files" : "Files you open show up here")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }
}

private struct SidebarFooter: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 8) {
            Button {
                workspace.showOpenPanel()
            } label: {
                Label("Open…", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.glass)
            Button {
                workspace.showPalette(.files)
            } label: {
                Label("Quick Open", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.glass)
            .help("Quick Open (⌘P)")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
