import AppKit
import SwiftUI

/// What a sidebar row stands for. It's the sidebar's selection and the id its rows scroll to.
enum SidebarItem: Hashable {
    /// A pinned or recent file.
    case file(String)
    /// A project folder's own row.
    case root(String)
    /// A file or folder in a project's tree (the same path can show in two projects when one
    /// folder is inside another).
    case node(root: String, path: String)
}

/// Folders opened as projects: each one is a file tree in the sidebar, and Quick Open searches
/// all of them.
extension Workspace {
    /// Opens `url` as a project, after the ones already open, and shows it in the sidebar. When it's
    /// open already it's expanded instead, along with `expandedFolders`.
    func openProject(_ url: URL, expandedFolders: [String] = [], collapsed: Bool = false, revealSidebar: Bool = true) {
        let root = url.canonicalFileURL
        guard root.isFolder else {
            toast("“\(root.lastPathComponent)” isn’t a folder", symbol: "questionmark.folder", tint: .orange)
            return
        }
        if let project = project(root: root.path) {
            withAnimation(.snappy(duration: 0.2)) {
                project.isCollapsed = false
                for folder in expandedFolders where project.contains(folder) { project.setExpanded(folder, true) }
            }
        } else {
            let project = makeProject(root, expandedFolders: expandedFolders)
            project.isCollapsed = collapsed
            withAnimation(.snappy(duration: 0.3)) { projects.append(project) }
            noteRecentProject(root)
        }
        if revealSidebar, !settings.showsSidebar {
            withAnimation(SidebarAnimation.animation) { settings.showsSidebar = true }
        }
        scheduleSessionSave()
    }

    /// Opens `folder` as a project with its tree expanded down to `item` (when it's a file or folder
    /// inside it), and scrolls the sidebar there, so `item` shows among its neighbors.
    func openProject(_ folder: URL, revealing item: URL) {
        openProject(folder, expandedFolders: Self.folders(from: folder.canonicalFileURL.path, to: item))
        reveal(item, in: folder)
    }

    /// Puts `url` in `project`'s place (going up a level from it). Folders expanded in `project` stay
    /// expanded when they're inside the new one, and the tree shows `project`'s folder.
    func replaceProject(_ project: Project, with url: URL) {
        let root = url.canonicalFileURL
        guard root.isFolder, root.path != project.root.path, let index = projects.firstIndex(where: { $0 === project }) else { return }
        let expanded = project.expandedFolders.sorted() + Self.folders(from: root.path, to: project.root)
        if let existing = self.project(root: root.path) {
            withAnimation(.snappy(duration: 0.2)) {
                existing.isCollapsed = false
                for folder in expanded where existing.contains(folder) { existing.setExpanded(folder, true) }
            }
            closeProject(project)
        } else {
            let replacement = makeProject(root, expandedFolders: expanded)
            withAnimation(.snappy(duration: 0.3)) { projects[index] = replacement }
            noteRecentProject(root)
            scheduleSessionSave()
        }
        reveal(project.root, in: root)
    }

    func closeProject(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0 === project }) else { return }
        withAnimation(.snappy(duration: 0.3)) { _ = projects.remove(at: index) }
        scheduleSessionSave()
    }

    func closeOtherProjects(_ keep: Project) {
        withAnimation(.snappy(duration: 0.3)) { projects.removeAll { $0 !== keep } }
        scheduleSessionSave()
    }

    func closeAllProjects() {
        guard !projects.isEmpty else { return }
        withAnimation(.snappy(duration: 0.3)) { projects.removeAll() }
        scheduleSessionSave()
    }

    /// The innermost open project holding `path`.
    func project(containing path: String) -> Project? {
        projects.filter { $0.contains(path) }.max { $0.root.path.count < $1.root.path.count }
    }

    func project(root path: String) -> Project? {
        projects.first { $0.root.path == path }
    }

    /// Folds every project down to its own row (what's expanded inside each one is kept).
    func collapseAllProjects() {
        withAnimation(.snappy(duration: 0.25)) {
            for project in projects { project.isCollapsed = true }
        }
        scheduleSessionSave()
    }

    func setCollapsed(_ project: Project, _ collapsed: Bool) {
        withAnimation(.snappy(duration: 0.2)) { project.isCollapsed = collapsed }
        scheduleSessionSave()
    }

    /// Asks for folders to open as projects. "Open Enclosing Folder…" passes the file it was chosen
    /// for: the panel starts in the folder holding it, where Open Folder with nothing selected picks
    /// that folder and the menu at the top reaches the ones above it, and the tree then opens expanded
    /// down to the file. From a project's own menu (`replacing`), the folder chosen takes its place.
    func showOpenFolderPanel(revealing item: URL? = nil, replacing replaced: Project? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = item == nil && replaced == nil
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Open Folder"
        panel.message = "Choose folders to open as projects"
        if let start = item ?? replaced?.root {
            // The nearest folder that still exists (a recent file's folder may be gone).
            var directory = start.canonicalFileURL.deletingLastPathComponent()
            while !directory.isFolder, directory.path != "/" { directory.deleteLastPathComponent() }
            panel.directoryURL = directory
            panel.message = "Choose a folder to open as a project. With nothing selected, “\(directory.lastPathComponent)” opens."
        } else if let directory = selectedDocument?.fileURL?.deletingLastPathComponent() ?? projects.last?.root {
            panel.directoryURL = directory
        }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                let workspace = Workspace.shared
                if let replaced, let url = urls.first {
                    workspace.replaceProject(replaced, with: url)
                } else if let item, let url = urls.first {
                    workspace.openProject(url, revealing: item)
                } else {
                    for url in urls { workspace.openProject(url) }
                }
            }
        }
        if let window = mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    /// Expands or collapses a folder in a project's tree (remembered with the session).
    func setFolder(_ path: String, expanded: Bool, in project: Project) {
        project.setExpanded(path, expanded)
        scheduleSessionSave()
    }

    func clearRecentProjects() {
        recentProjects = []
    }

    // MARK: Helpers

    private func makeProject(_ root: URL, expandedFolders: [String]) -> Project {
        let project = Project(root: root, expandedFolders: expandedFolders)
        project.onGitChange = { Workspace.shared.gitStateDidChange() }
        return project
    }

    private func noteRecentProject(_ root: URL) {
        guard !isRestoringSession else { return }
        recentProjects = [root.path] + recentProjects.filter { $0 != root.path }.prefix(9)
        NSDocumentController.shared.noteNewRecentDocumentURL(root)
    }

    /// The folders between `root` and `item` (a file's folder, or a folder itself), for expanding the
    /// tree down to `item`.
    private static func folders(from root: String, to item: URL) -> [String] {
        let target = item.canonicalPath
        var folders: [String] = []
        var path = item.isFolder ? target : (target as NSString).deletingLastPathComponent
        while path.hasPrefix(root + "/") {
            folders.append(path)
            path = (path as NSString).deletingLastPathComponent
        }
        return folders
    }

    /// Scrolls the sidebar to `item`'s row in the project at `folder`, once it's on screen.
    private func reveal(_ item: URL, in folder: URL) {
        let root = folder.canonicalFileURL.path
        let target = item.canonicalPath
        guard project(root: root) != nil, target.hasPrefix(root + "/") else { return }
        // The tree shows only while the sidebar isn't filtered.
        sidebarFilter = ""
        sidebarRevealRequest = .node(root: root, path: target)
    }
}
