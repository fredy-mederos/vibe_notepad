import AppKit
import SwiftUI
import VibeCore

/// One folder's entries in the sidebar's project tree; subfolders expand in place.
struct ProjectTreeRows: View {
    @Environment(Workspace.self) private var workspace
    let project: Project
    let folder: String

    var body: some View {
        ForEach(project.children(of: folder)) { node in
            if node.isDirectory {
                DisclosureGroup(isExpanded: Binding(
                    get: { project.isExpanded(node.id) },
                    set: { workspace.setFolder(node.id, expanded: $0) }
                )) {
                    ProjectTreeRows(project: project, folder: node.id)
                } label: {
                    ProjectFolderRow(project: project, node: node)
                }
            } else {
                ProjectFileRow(project: project, node: node)
                    .tag(node.id)
            }
        }
    }
}

/// A folder in the project tree. Clicking it expands or collapses it (the sidebar's selection
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
            Button("Open as Project", systemImage: "folder.badge.plus") { workspace.openProject(node.url) }
            Divider()
            ProjectItemMenu(project: project, url: node.url)
        }
    }
}

/// A file in the project tree.
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

/// A project file matching the sidebar filter (shown flat, with its folder).
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
            Divider()
            EnclosingFolderButton(item: file.url)
            ProjectItemMenu(project: project, url: file.url)
        }
    }
}

/// The project section's header: its name and folder actions.
struct ProjectSectionHeader: View {
    @Environment(Workspace.self) private var workspace
    let project: Project

    var body: some View {
        HStack {
            Text(project.name)
                .help(project.root.abbreviatedPath)
            Spacer()
            Button {
                collapseAll()
            } label: {
                Label("Collapse All Folders", systemImage: "chevron.up.chevron.down")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .help("Collapse All Folders")
            .disabled(project.expandedFolders.isEmpty)
            Menu {
                Button("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.root])
                }
                Button("Copy Path", systemImage: "doc.on.clipboard") { copy(project.root.path) }
                Button("Collapse All Folders", systemImage: "chevron.up.chevron.down") { collapseAll() }
                    .disabled(project.expandedFolders.isEmpty)
                Divider()
                EnclosingFolderButton(item: project.root)
                Button("Close Folder", systemImage: "xmark.circle") { workspace.closeProject() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func collapseAll() {
        withAnimation(.snappy) { project.collapseAll() }
        workspace.scheduleSessionSave()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        workspace.toast("Copied path", symbol: "doc.on.clipboard.fill")
    }
}

/// "Open Enclosing Folder…": the Open Folder panel, starting in the folder that holds `item`, to open
/// it (or a folder above it) as the project and see what's next to `item`.
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
