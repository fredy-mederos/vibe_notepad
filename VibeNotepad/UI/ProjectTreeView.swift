import AppKit
import SwiftUI
import VibeCore

extension Project {
    /// The sidebar row id (and selection value) of the project's own row.
    var sidebarItem: SidebarItem { .root(root.path) }

    /// A color of its own, so open projects are easy to tell apart (stable across launches).
    var tint: Color {
        let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .green, .indigo, .cyan, .red, .mint]
        // FNV-1a: String's own hash changes from launch to launch.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in root.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// A project in the sidebar: its own row (a colored folder, the name, where it is and its git
/// branch), which folds the tree below it.
struct ProjectTree: View {
    @Environment(Workspace.self) private var workspace
    let project: Project

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { !project.isCollapsed },
            set: { workspace.setCollapsed(project, !$0) }
        )) {
            if project.exists {
                ProjectTreeRows(project: project, folder: project.root.path)
            } else {
                Label("This folder was moved or deleted", systemImage: "questionmark.folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        } label: {
            ProjectRootRow(project: project)
        }
    }
}

/// A row in a project's tree, identified by the project and the path.
private struct TreeRow: Identifiable {
    let root: String
    let node: ProjectNode
    var id: SidebarItem { .node(root: root, path: node.id) }
}

/// One folder's entries in a project's tree; subfolders expand in place.
struct ProjectTreeRows: View {
    @Environment(Workspace.self) private var workspace
    let project: Project
    let folder: String

    var body: some View {
        let root = project.root.path
        ForEach(project.children(of: folder).map { TreeRow(root: root, node: $0) }) { row in
            let node = row.node
            if node.isDirectory {
                DisclosureGroup(isExpanded: Binding(
                    get: { project.isExpanded(node.id) },
                    set: { workspace.setFolder(node.id, expanded: $0, in: project) }
                )) {
                    ProjectTreeRows(project: project, folder: node.id)
                } label: {
                    ProjectFolderRow(project: project, node: node)
                }
            } else {
                ProjectFileRow(project: project, node: node)
                    .tag(row.id)
            }
        }
    }
}

/// A project's own row: a colored folder, its name and where it is, and its git branch (or, on
/// hover, a button that closes it). Clicking it folds or unfolds the project.
struct ProjectRootRow: View {
    @Environment(Workspace.self) private var workspace
    let project: Project
    @State private var isHovering = false

    var body: some View {
        // The list lines the disclosure chevron up with the row's first line, so the folder sits on that
        // line, next to the name, and where it is goes underneath.
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: project.exists ? "folder.fill" : "questionmark.folder.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(project.exists ? project.tint.gradient : Color.gray.gradient)
                    .shadow(color: project.tint.opacity(project.exists ? 0.3 : 0), radius: 1.5, y: 0.5)
                    .frame(width: 22)
                Text(project.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                ZStack(alignment: .trailing) {
                    if isHovering {
                        Button {
                            workspace.closeProject(project)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Close Folder")
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    } else if let branch = project.branch {
                        BranchBadge(branch: branch)
                            .transition(.opacity)
                    }
                }
                .frame(height: 18)
            }
            Text(project.root.abbreviatedParentPath)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.leading, 30)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.18)) { isHovering = hovering }
        }
        .help(project.root.abbreviatedPath)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(project.name)")
        .contextMenu { ProjectRootMenu(project: project) }
    }
}

/// The git branch next to a project's name.
private struct BranchBadge: View {
    let branch: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 8.5, weight: .semibold))
            Text(branch)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(.primary.opacity(0.07)))
        .frame(maxWidth: 96, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
        .help("Branch \(branch)")
    }
}

/// Actions for a project's own row (right-click).
struct ProjectRootMenu: View {
    @Environment(Workspace.self) private var workspace
    let project: Project

    var body: some View {
        Button("Reveal in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([project.root])
        }
        Button("Copy Path", systemImage: "doc.on.clipboard") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.root.path, forType: .string)
            workspace.toast("Copied path", symbol: "doc.on.clipboard.fill")
        }
        Divider()
        Button("Open Enclosing Folder…", systemImage: "folder.badge.plus") { workspace.showOpenFolderPanel(replacing: project) }
        Button("Collapse Folders Inside", systemImage: "chevron.up.chevron.down") {
            withAnimation(.snappy) { project.collapseAll() }
            workspace.scheduleSessionSave()
        }
        .disabled(project.expandedFolders.isEmpty)
        if workspace.projects.count > 1 {
            Button("Collapse Other Folders", systemImage: "rectangle.compress.vertical") {
                for other in workspace.projects where other !== project { workspace.setCollapsed(other, true) }
                workspace.setCollapsed(project, false)
            }
        }
        Divider()
        Button("Close Folder", systemImage: "xmark.circle") { workspace.closeProject(project) }
        if workspace.projects.count > 1 {
            Button("Close Other Folders") { workspace.closeOtherProjects(project) }
        }
    }
}

/// A folder in a project's tree. Clicking it expands or collapses it (the sidebar's selection
/// handles the click: the list selects the row before a tap gesture here would see it).
struct ProjectFolderRow: View {
    @Environment(Workspace.self) private var workspace
    let project: Project
    let node: ProjectNode

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.accentColor.opacity(0.85))
                .frame(width: 16)
            Text(node.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .help(node.url.abbreviatedPath)
        .contextMenu {
            Button("Add as Separate Folder", systemImage: "folder.badge.plus") { workspace.openProject(node.url) }
            Divider()
            ProjectItemMenu(project: project, url: node.url)
        }
    }
}

/// A file in a project's tree.
struct ProjectFileRow: View {
    @Environment(Workspace.self) private var workspace
    let project: Project
    let node: ProjectNode

    var body: some View {
        let document = workspace.documents.first { $0.path == node.id }
        HStack(spacing: 7) {
            FileIcon(language: document?.language ?? LanguageRegistry.detect(path: node.id), size: 16)
            Text(node.name)
                .font(.system(size: 12.5, weight: document != nil ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            if document?.isDirty == true {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .help(node.url.abbreviatedPath)
        .contextMenu {
            Button("Open", systemImage: "doc.text") { workspace.open(url: node.url) }
            OpenInPaneButtons(url: node.url)
            let pinned = workspace.recents.item(for: node.id)?.pinned == true
            Button(pinned ? "Unpin" : "Pin to Top", systemImage: pinned ? "pin.slash" : "pin") {
                withAnimation(.snappy) {
                    if pinned { workspace.recents.togglePin(node.id) } else { workspace.recents.pin(node.url) }
                }
            }
            Divider()
            EnclosingFolderButton(item: node.url)
            ProjectItemMenu(project: project, url: node.url)
        }
    }
}

/// A project file matching the sidebar filter (shown flat, with its project and folder).
struct ProjectMatchRow: View {
    @Environment(Workspace.self) private var workspace
    let project: Project
    let file: ProjectFile
    let positions: [Int]

    var body: some View {
        let document = workspace.documents.first { $0.path == file.url.path }
        HStack(spacing: 9) {
            FileIcon(language: document?.language ?? LanguageRegistry.detect(path: file.relativePath), size: 22)
            VStack(alignment: .leading, spacing: 1) {
                HighlightedText(text: file.name, positions: positions, font: .system(size: 12.5, weight: document != nil ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.folder.isEmpty ? project.name : "\(project.name)/\(file.folder)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .help(file.url.abbreviatedPath)
        .contextMenu {
            Button("Open", systemImage: "doc.text") { workspace.open(url: file.url) }
            OpenInPaneButtons(url: file.url)
            Divider()
            EnclosingFolderButton(item: file.url)
            ProjectItemMenu(project: project, url: file.url)
        }
    }
}

/// The Folders section's header: open another folder, fold them all, close them all.
struct FoldersSectionHeader: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 8) {
            Text("Folders")
            Spacer()
            Button {
                workspace.showOpenFolderPanel()
            } label: {
                Label("Open Folder…", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .help("Open Folder… (⇧⌘O)")
            Button {
                workspace.collapseAllProjects()
            } label: {
                Label("Collapse All Folders", systemImage: "chevron.up.chevron.down")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .help("Collapse All Folders")
            .disabled(workspace.projects.allSatisfy(\.isCollapsed))
            Menu {
                Button("Open Folder…", systemImage: "folder.badge.plus") { workspace.showOpenFolderPanel() }
                Button("Collapse All Folders", systemImage: "chevron.up.chevron.down") { workspace.collapseAllProjects() }
                    .disabled(workspace.projects.allSatisfy(\.isCollapsed))
                Divider()
                Button(workspace.projects.count > 1 ? "Close All Folders" : "Close Folder", systemImage: "xmark.circle") {
                    workspace.closeAllProjects()
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

/// "Open to the Right" / "Open Below": a file in a new pane next to the focused one.
struct OpenInPaneButtons: View {
    @Environment(Workspace.self) private var workspace
    let url: URL

    var body: some View {
        Button("Open to the Right", systemImage: "rectangle.split.2x1") { workspace.openInNewPane(url, axis: .horizontal) }
            .disabled(workspace.paneCount >= Workspace.maxPanes)
        Button("Open Below", systemImage: "rectangle.split.1x2") { workspace.openInNewPane(url, axis: .vertical) }
            .disabled(workspace.paneCount >= Workspace.maxPanes)
    }
}

/// "Open Enclosing Folder…": the Open Folder panel, starting in the folder that holds `item`, to open
/// it (or a folder above it) as a project and see what's next to `item`.
struct EnclosingFolderButton: View {
    @Environment(Workspace.self) private var workspace
    let item: URL

    var body: some View {
        Button("Open Enclosing Folder…", systemImage: "folder.badge.plus") { workspace.showOpenFolderPanel(revealing: item) }
    }
}

/// Reveal / copy actions shared by project files and folders.
private struct ProjectItemMenu: View {
    @Environment(Workspace.self) private var workspace
    let project: Project
    let url: URL

    var body: some View {
        Button("Reveal in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        Button("Copy Path", systemImage: "doc.on.clipboard") { copy(url.path, toast: "Copied path") }
        if let relative = project.relativePath(of: url.path) {
            Button("Copy Relative Path", systemImage: "doc.on.clipboard") { copy(relative, toast: "Copied relative path") }
        }
    }

    private func copy(_ text: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        workspace.toast(toast, symbol: "doc.on.clipboard.fill")
    }
}
