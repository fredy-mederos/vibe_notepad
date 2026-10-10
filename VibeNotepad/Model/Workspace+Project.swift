import AppKit
import SwiftUI

/// Opening a folder as the project.
extension Workspace {
    /// Makes `url` the project (one at a time) and shows it in the sidebar. When it already is the
    /// project, `expandedFolders` are expanded in its tree.
    func openProject(_ url: URL, expandedFolders: [String] = [], revealSidebar: Bool = true) {
        let root = url.canonicalFileURL
        guard root.isFolder else {
            toast("“\(root.lastPathComponent)” isn’t a folder", symbol: "questionmark.folder", tint: .orange)
            return
        }
        if let project, project.root.path == root.path {
            withAnimation(.snappy(duration: 0.2)) {
                for folder in expandedFolders where project.contains(folder) { project.setExpanded(folder, true) }
            }
        } else {
            let project = Project(root: root, expandedFolders: expandedFolders)
            project.onGitChange = { Workspace.shared.gitStateDidChange() }
            withAnimation(.snappy(duration: 0.3)) { self.project = project }
            recentProjects = [root.path] + recentProjects.filter { $0 != root.path }.prefix(9)
            NSDocumentController.shared.noteNewRecentDocumentURL(root)
        }
        if revealSidebar, !settings.showsSidebar {
            withAnimation(SidebarAnimation.animation) { settings.showsSidebar = true }
        }
        scheduleSessionSave()
    }

    /// Opens `folder` as the project with its tree expanded down to `item` (when it's a file or folder
    /// inside it), and scrolls the sidebar there, so `item` shows among its neighbors. Folders expanded
    /// in the previous project stay expanded when they're inside the new one (going up a level).
    func openProject(_ folder: URL, revealing item: URL) {
        let root = folder.canonicalFileURL.path
        let target = item.canonicalPath
        var folders: [String] = project?.expandedFolders.sorted() ?? []
        var path = item.isFolder ? target : (target as NSString).deletingLastPathComponent
        while path.hasPrefix(root + "/") {
            folders.append(path)
            path = (path as NSString).deletingLastPathComponent
        }
        openProject(folder, expandedFolders: folders)
        guard project?.root.path == root, target.hasPrefix(root + "/") else { return }
        // The tree shows only while the sidebar isn't filtered and the project section is expanded.
        sidebarFilter = ""
        UserDefaults.standard.set(true, forKey: "sidebarProjectExpanded")
        sidebarRevealRequest = target
    }

    func closeProject() {
        guard project != nil else { return }
        withAnimation(.snappy(duration: 0.3)) { project = nil }
        scheduleSessionSave()
    }

    /// Asks for a folder to open as the project. "Open Enclosing Folder…" passes the file (or the
    /// project's folder) it was chosen for: the panel starts in the folder holding it, where Open Folder
    /// with nothing selected picks that folder and the menu at the top reaches the ones above it.
    /// The tree then opens expanded down to `item`.
    func showOpenFolderPanel(revealing item: URL? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Open Folder"
        panel.message = "Choose a folder to open as a project"
        if let item {
            // The nearest folder that still exists (a recent file's folder may be gone).
            var directory = item.canonicalFileURL.deletingLastPathComponent()
            while !directory.isFolder, directory.path != "/" { directory.deleteLastPathComponent() }
            panel.directoryURL = directory
            panel.message = "Choose a folder to open as a project. With nothing selected, “\(directory.lastPathComponent)” opens."
        } else if let directory = project?.root ?? selectedDocument?.fileURL?.deletingLastPathComponent() {
            panel.directoryURL = directory
        }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if let item { Workspace.shared.openProject(url, revealing: item) } else { Workspace.shared.openProject(url) }
            }
        }
        if let window = mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    /// Expands or collapses a folder in the project tree (remembered with the session).
    func setFolder(_ path: String, expanded: Bool) {
        project?.setExpanded(path, expanded)
        scheduleSessionSave()
    }

    func clearRecentProjects() {
        recentProjects = []
    }
}
