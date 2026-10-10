import AppKit
import Foundation
import Observation
import VibeCore

/// A file the user opened, remembered across launches with its last editing state.
nonisolated struct RecentFile: Codable, Hashable, Identifiable, Sendable {
    var path: String
    var lastOpened: Date
    var pinned: Bool = false
    /// Caret location when the file was last closed.
    var selection: Int?
    /// Language picked manually from the status bar (overrides detection).
    var language: LanguageID?
    var markdownMode: MarkdownMode?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

nonisolated extension RecentFile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        lastOpened = (try? c.decode(Date.self, forKey: .lastOpened)) ?? .distantPast
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
        selection = (try? c.decodeIfPresent(Int.self, forKey: .selection)) ?? nil
        language = (try? c.decodeIfPresent(LanguageID.self, forKey: .language)) ?? nil
        markdownMode = (try? c.decodeIfPresent(MarkdownMode.self, forKey: .markdownMode)) ?? nil
    }
}

/// Recent and pinned files, persisted as JSON in Application Support.
@Observable
final class RecentFilesStore {
    private(set) var items: [RecentFile] = []
    /// Paths found missing on disk the last time we looked.
    private(set) var missing: Set<String> = []

    private let maxRecent = 80
    private let fileURL: URL

    init(directory: URL = AppPaths.supportDirectory) {
        fileURL = directory.appendingPathComponent("recents.json")
        load()
        refreshMissing()
    }

    var pinned: [RecentFile] { items.filter(\.pinned) }

    var recent: [RecentFile] {
        items.filter { !$0.pinned }.sorted { $0.lastOpened > $1.lastOpened }
    }

    /// Pinned first (in pin order), then recent by date.
    var all: [RecentFile] { pinned + recent }

    func item(for path: String) -> RecentFile? { items.first { $0.path == path } }

    func noteOpened(_ url: URL) {
        let path = url.canonicalPath
        if let index = items.firstIndex(where: { $0.path == path }) {
            items[index].lastOpened = .now
        } else {
            items.append(RecentFile(path: path, lastOpened: .now))
        }
        missing.remove(path)
        trim()
        save()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func update(_ path: String, _ change: (inout RecentFile) -> Void) {
        guard let index = items.firstIndex(where: { $0.path == path }) else { return }
        change(&items[index])
        save()
    }

    func togglePin(_ path: String) {
        guard let index = items.firstIndex(where: { $0.path == path }) else { return }
        let item = items.remove(at: index)
        var updated = item
        updated.pinned.toggle()
        // Newly pinned items go to the end of the pinned list.
        items.append(updated)
        save()
    }

    func pin(_ url: URL) {
        let path = url.canonicalPath
        if item(for: path) == nil { items.append(RecentFile(path: path, lastOpened: .now)) }
        if item(for: path)?.pinned == false { togglePin(path) }
    }

    func movePinned(from source: IndexSet, to destination: Int) {
        var pinnedItems = pinned
        pinnedItems.move(fromOffsets: source, toOffset: destination)
        items = pinnedItems + items.filter { !$0.pinned }
        save()
    }

    func remove(_ path: String) {
        items.removeAll { $0.path == path }
        save()
    }

    func clearRecent() {
        items.removeAll { !$0.pinned }
        save()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    func refreshMissing() {
        let fm = FileManager.default
        missing = Set(items.map(\.path).filter { !fm.fileExists(atPath: $0) })
    }

    func isMissing(_ path: String) -> Bool { missing.contains(path) }

    private func trim() {
        let unpinned = items.filter { !$0.pinned }.sorted { $0.lastOpened > $1.lastOpened }
        guard unpinned.count > maxRecent else { return }
        let drop = Set(unpinned.dropFirst(maxRecent).map(\.path))
        items.removeAll { drop.contains($0.path) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = (try? JSONDecoder().decode([Lossy<RecentFile>].self, from: data))?.compactMap(\.value) else { return }
        // Normalize and de-duplicate paths saved by older versions.
        var seen = Set<String>()
        items = decoded.compactMap { item in
            var item = item
            item.path = URL(fileURLWithPath: item.path).canonicalPath
            return seen.insert(item.path).inserted ? item : nil
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Vibe Notepad: failed to save recents: \(error)")
        }
    }
}

/// Well-known locations.
nonisolated enum AppPaths {
    static let supportDirectory: URL = {
        // VIBE_SUPPORT_DIR lets development runs use a throwaway folder.
        if let custom = ProcessInfo.processInfo.environment["VIBE_SUPPORT_DIR"], !custom.isEmpty {
            let directory = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("Vibe Notepad", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static let buffersDirectory: URL = {
        let directory = supportDirectory.appendingPathComponent("Buffers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static let previewDirectory: URL = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VibeNotepadPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
}
