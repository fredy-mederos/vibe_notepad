import AppKit
import Observation

/// A file or folder shown in the project tree.
nonisolated struct ProjectNode: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// A file Quick Open can reach, with its path inside the project.
nonisolated struct ProjectFile: Sendable {
    let url: URL
    /// "Sources/App/main.swift"
    let relativePath: String
    let name: String

    /// The folder part of `relativePath` ("Sources/App"), empty at the top level.
    var folder: String { (relativePath as NSString).deletingLastPathComponent }
}

/// A folder opened as a project: the sidebar's file tree and every file Quick Open can reach.
/// Both follow changes on disk.
@Observable
final class Project {
    let root: URL
    var name: String { root.lastPathComponent }

    /// Files for Quick Open: `git ls-files` in a repository, otherwise a folder scan.
    private(set) var files: [ProjectFile] = []
    /// Folders expanded in the sidebar tree.
    private(set) var expandedFolders: Set<String> = []
    /// Folder listings for the tree, read when a folder is first expanded.
    private(set) var listings: [String: [ProjectNode]] = [:]

    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var reindexTask: Task<Void, Never>?
    /// The root as FSEvents reports it (symlinks resolved, `/private/tmp/…`).
    @ObservationIgnored private let resolvedRoot: String
    /// Home, `/` and the like: listed in the tree, but too big to crawl for Quick Open.
    @ObservationIgnored private let isBroad: Bool

    init(root: URL, expandedFolders: [String] = []) {
        self.root = root
        resolvedRoot = root.path.withCString { path in
            guard let resolved = realpath(path, nil) else { return root.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        isBroad = FolderScanner.isTooBroad(root)
        loadListing(root.path)
        for folder in expandedFolders where contains(folder) && loadListing(folder) {
            self.expandedFolders.insert(folder)
        }
        watcher = DirectoryWatcher(url: root) { [weak self] changes in self?.filesDidChange(changes) }
        reindex()
    }

    /// False once the folder was moved or deleted.
    var exists: Bool { listings[root.path] != nil }

    func children(of folder: String) -> [ProjectNode] { listings[folder] ?? [] }

    func isExpanded(_ folder: String) -> Bool { expandedFolders.contains(folder) }

    func setExpanded(_ folder: String, _ expanded: Bool) {
        if expanded {
            guard listings[folder] != nil || loadListing(folder) else { return }
            expandedFolders.insert(folder)
        } else {
            expandedFolders.remove(folder)
        }
    }

    func collapseAll() {
        expandedFolders.removeAll()
    }

    /// "Sources/App/main.swift" for a path inside the project, nil otherwise.
    func relativePath(of path: String) -> String? {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    func contains(_ path: String) -> Bool { relativePath(of: path) != nil }

    // MARK: Listings

    /// Names never shown in the tree.
    nonisolated static let hiddenNames: Set<String> = [".git", ".svn", ".hg", ".DS_Store"]

    /// Reads `folder`'s entries; false (forgetting the folder) when it can't be read.
    @discardableResult
    private func loadListing(_ folder: String) -> Bool {
        guard let nodes = Self.list(folder) else {
            forget(folder)
            return false
        }
        if listings[folder] != nodes { listings[folder] = nodes }
        return true
    }

    /// Drops a folder that disappeared, and everything inside it.
    private func forget(_ folder: String) {
        let prefix = folder + "/"
        for path in listings.keys where path == folder || path.hasPrefix(prefix) { listings[path] = nil }
        let kept = expandedFolders.filter { $0 != folder && !$0.hasPrefix(prefix) }
        if kept.count != expandedFolders.count { expandedFolders = kept }
    }

    /// A folder's entries, folders first, in Finder order.
    nonisolated static func list(_ folder: String) -> [ProjectNode]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder) else { return nil }
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        var nodes: [ProjectNode] = []
        nodes.reserveCapacity(names.count)
        for name in names where !hiddenNames.contains(name) {
            let path = base + name
            var isDirectory: ObjCBool = false
            // Follows symlinks, so a linked folder expands like any other.
            let isFolder = fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            nodes.append(ProjectNode(url: URL(fileURLWithPath: path, isDirectory: isFolder), isDirectory: isFolder))
        }
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Changes on disk

    private func filesDidChange(_ changes: [DirectoryWatcher.Change]) {
        var affectsIndex = false
        for change in changes {
            guard let path = localPath(change.path) else { continue }
            let parts = (relativePath(of: path) ?? "").split(separator: "/").map(String.init)
            if parts.contains(where: Self.hiddenNames.contains) { continue }
            if change.includesSubfolders {
                let prefix = path + "/"
                for folder in listings.keys where folder == path || folder.hasPrefix(prefix) { loadListing(folder) }
            } else if listings[path] != nil {
                loadListing(path)
            }
            if !parts.contains(where: FolderScanner.skippedFolders.contains) { affectsIndex = true }
        }
        if affectsIndex, !isBroad { scheduleReindex() }
    }

    /// Maps an FSEvents path into the project's own spelling of its paths.
    private func localPath(_ path: String) -> String? {
        if path == resolvedRoot { return root.path }
        if path.hasPrefix(resolvedRoot + "/") { return root.path + path.dropFirst(resolvedRoot.count) }
        return contains(path) || path == root.path ? path : nil
    }

    // MARK: Quick Open index

    func reindex() {
        indexTask?.cancel()
        let root = root
        let includeUntracked = !isBroad
        indexTask = Task.detached(priority: .utility) { [weak self] in
            let files = ProjectIndexer.files(in: root, includeUntracked: includeUntracked)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.files = files }
        }
    }

    private func scheduleReindex() {
        reindexTask?.cancel()
        reindexTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.reindex()
        }
    }
}

/// Lists the files Quick Open offers for a project.
nonisolated enum ProjectIndexer {
    static let limit = 100_000

    static func files(in root: URL, includeUntracked: Bool = true) -> [ProjectFile] {
        let rootPath = root.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let relativePaths: [String]
        if let listed = Git.listFiles(in: root, includeUntracked: includeUntracked) {
            relativePaths = listed
        } else {
            relativePaths = FolderScanner.files(in: root, maxDepth: 24, limit: limit).compactMap { url in
                url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : nil
            }
        }
        let fm = FileManager.default
        var result: [ProjectFile] = []
        result.reserveCapacity(min(relativePaths.count, limit))
        for relative in relativePaths {
            let name = (relative as NSString).lastPathComponent
            guard !FolderScanner.isUnlikelyText(name) else { continue }
            let path = prefix + relative
            var isDirectory: ObjCBool = false
            // git keeps listing deleted files until the deletion is staged, and submodules as entries.
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            result.append(ProjectFile(url: URL(fileURLWithPath: path), relativePath: relative, name: name))
            if result.count >= limit { break }
        }
        return result
    }
}

/// Enumerates files under a folder for Quick Open (skipping VCS and build folders).
nonisolated enum FolderScanner {
    /// Folders that hold dependencies or build output rather than files people edit.
    static let skippedFolders: Set<String> = [".git", ".svn", ".hg", "node_modules", "Pods", "DerivedData", ".build", "build", "dist", ".gradle", ".idea", ".next", "vendor", "__pycache__", ".venv", "venv", "Carthage", ".swiftpm", "target"]
    static let binaryExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "ico", "icns", "pdf", "zip", "gz", "tar", "dmg", "app", "a", "o", "so", "dylib", "class", "jar", "mp3", "mp4", "mov", "wav", "ttf", "otf", "woff", "woff2", "sqlite", "db", "bin", "exe", "car"]

    /// Images, archives, binaries and Finder metadata: not worth offering in Quick Open.
    static func isUnlikelyText(_ name: String) -> Bool {
        name == ".DS_Store" || binaryExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Folders too broad to crawl: scanning them is slow, and walking into Desktop, Documents,
    /// Photos or Mail from the home folder would trigger macOS privacy prompts.
    static func isTooBroad(_ directory: URL) -> Bool {
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        if ["/", home, "/Users", "/Volumes", "/System", "/Library", "/Applications", "/private", "/usr", "/opt", "/bin", "/sbin"].contains(path) {
            return true
        }
        return path.hasPrefix(home + "/Library/") || path == home + "/Library" || path.hasPrefix("/System/") || path.hasPrefix("/Library/")
    }

    static func files(in directory: URL, maxDepth: Int, limit: Int) -> [URL] {
        guard !isTooBroad(directory) else { return [] }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        let baseDepth = directory.pathComponents.count
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let name = url.lastPathComponent
            if values?.isDirectory == true {
                if skippedFolders.contains(name) || (name.hasPrefix(".") && name != ".github") || url.pathComponents.count - baseDepth >= maxDepth {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, !isUnlikelyText(name) else { continue }
            result.append(url.canonicalFileURL)
            if result.count >= limit { break }
        }
        return result
    }
}
