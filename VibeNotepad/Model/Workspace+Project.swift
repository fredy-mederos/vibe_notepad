import AppKit
import SwiftUI

/// Opening a folder as the project.
extension Workspace {
    /// Makes `url` the project (one at a time) and shows it in the sidebar.
    func openProject(_ url: URL, expandedFolders: [String] = [], revealSidebar: Bool = true) {
        let root = url.canonicalFileURL
        guard root.isFolder else {
            toast("“\(root.lastPathComponent)” isn’t a folder", symbol: "questionmark.folder", tint: .orange)
            return
        }
        if project?.root.path != root.path {
            let project = Project(root: root, expandedFolders: expandedFolders)
            project.onGitChange = { Workspace.shared.gitStateDidChange() }
            withAnimation(.snappy(duration: 0.3)) { self.project = project }
            recentProjects = [root.path] + recentProjects.filter { $0 != root.path }.prefix(9)
            NSDocumentController.shared.noteNewRecentDocumentURL(root)
        }
        if revealSidebar, !settings.showsSidebar {
            withAnimation(.snappy) { settings.showsSidebar = true }
        }
        scheduleSessionSave()
    }

    func closeProject() {
        guard project != nil else { return }
        withAnimation(.snappy(duration: 0.3)) { project = nil }
        scheduleSessionSave()
    }

    func showOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Open Folder"
        panel.message = "Choose a folder to open as a project"
        if let directory = project?.root ?? selectedDocument?.fileURL?.deletingLastPathComponent() { panel.directoryURL = directory }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in Workspace.shared.openProject(url) }
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
