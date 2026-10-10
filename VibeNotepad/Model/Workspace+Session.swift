import AppKit
import Foundation
import VibeCore

/// What is persisted per tab between launches.
nonisolated struct SessionDocument: Codable, Sendable {
    var path: String?
    var untitledNumber: Int
    /// File name in the Buffers folder holding unsaved content (hot exit).
    var buffer: String?
    var dirty: Bool
    var selection: Int
    var language: LanguageID
    var languageIsManual: Bool
    var markdownMode: MarkdownMode
    var encoding: UInt
    var hasBOM: Bool
    var lineEnding: LineEnding
    var wrapLines: Bool?
    var modificationDate: Date?
    /// Opened as a binary file (decoded byte for byte).
    var binary: Bool?
}

nonisolated extension SessionDocument {
    /// Values this version doesn't know (a language added later, say) fall back to defaults
    /// instead of dropping the tab and its unsaved text.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        buffer = try c.decodeIfPresent(String.self, forKey: .buffer)
        untitledNumber = (try? c.decode(Int.self, forKey: .untitledNumber)) ?? 1
        dirty = (try? c.decode(Bool.self, forKey: .dirty)) ?? (buffer != nil)
        selection = (try? c.decode(Int.self, forKey: .selection)) ?? 0
        language = (try? c.decode(LanguageID.self, forKey: .language)) ?? .plainText
        languageIsManual = (try? c.decode(Bool.self, forKey: .languageIsManual)) ?? false
        markdownMode = (try? c.decode(MarkdownMode.self, forKey: .markdownMode)) ?? .split
        encoding = (try? c.decode(UInt.self, forKey: .encoding)) ?? String.Encoding.utf8.rawValue
        hasBOM = (try? c.decode(Bool.self, forKey: .hasBOM)) ?? false
        lineEnding = (try? c.decode(LineEnding.self, forKey: .lineEnding)) ?? .lf
        wrapLines = (try? c.decodeIfPresent(Bool.self, forKey: .wrapLines)) ?? nil
        modificationDate = (try? c.decodeIfPresent(Date.self, forKey: .modificationDate)) ?? nil
        binary = (try? c.decodeIfPresent(Bool.self, forKey: .binary)) ?? nil
    }
}

/// A folder open as a project, with what's expanded in its tree.
nonisolated struct SessionProject: Codable, Sendable {
    var path: String
    var expandedFolders: [String]
    var collapsed: Bool?
}

/// How the editor area was split, and which document (an index into the session's documents)
/// each pane showed.
nonisolated struct SessionPanes: Codable, Sendable {
    var layout: PaneLayout
    var documents: [String: Int]
    var focused: UUID
}

nonisolated struct SessionState: Codable, Sendable {
    var documents: [SessionDocument]
    var selectedIndex: Int?
    /// The folders open as projects, in sidebar order.
    var projects: [SessionProject]
    var panes: SessionPanes?
    /// Entries that couldn't be read at all (their buffers must not be cleaned up).
    var unreadableDocuments = 0

    enum CodingKeys: String, CodingKey {
        case documents, selectedIndex, projects, panes
        // Sessions from before several folders could be open.
        case projectPath, expandedFolders
    }

    init(documents: [SessionDocument], selectedIndex: Int?, projects: [SessionProject] = [], panes: SessionPanes? = nil) {
        self.documents = documents
        self.selectedIndex = selectedIndex
        self.projects = projects
        self.panes = panes
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(documents, forKey: .documents)
        try c.encodeIfPresent(selectedIndex, forKey: .selectedIndex)
        try c.encode(projects, forKey: .projects)
        try c.encodeIfPresent(panes, forKey: .panes)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try c.decode([Lossy<SessionDocument>].self, forKey: .documents)
        let selected = (try? c.decodeIfPresent(Int.self, forKey: .selectedIndex)) ?? nil
        if let projects = (try? c.decodeIfPresent([Lossy<SessionProject>].self, forKey: .projects)) ?? nil {
            self.projects = projects.compactMap(\.value)
        } else if let path = (try? c.decodeIfPresent(String.self, forKey: .projectPath)) ?? nil {
            let expanded = (try? c.decodeIfPresent([String].self, forKey: .expandedFolders)) ?? nil
            projects = [SessionProject(path: path, expandedFolders: expanded ?? [])]
        } else {
            projects = []
        }
        panes = (try? c.decodeIfPresent(SessionPanes.self, forKey: .panes)) ?? nil
        documents = []
        for (index, entry) in entries.enumerated() {
            guard let document = entry.value else {
                unreadableDocuments += 1
                continue
            }
            if index == selected { selectedIndex = documents.count }
            documents.append(document)
        }
    }
}

/// Decodes an array element without failing the whole array.
nonisolated struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension Workspace {
    private var sessionURL: URL { AppPaths.supportDirectory.appendingPathComponent("session.json") }

    func scheduleSessionSave() {
        guard !isRestoringSession else { return }
        sessionSaveTaskStorage?.cancel()
        sessionSaveTaskStorage = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            Workspace.shared.saveSession()
        }
    }

    /// Writes the open tabs (and, with hot exit, unsaved content) to disk.
    func saveSession() {
        let fm = FileManager.default
        guard settings.restoreSession else {
            try? fm.removeItem(at: sessionURL)
            return
        }
        var entries: [SessionDocument] = []
        var selectedIndex: Int?
        var keptBuffers = Set<String>()
        var entryIndex: [UUID: Int] = [:]
        for document in documents {
            var bufferName: String?
            let hasUnsavedContent = document.isDirty || (document.isUntitled && document.characterCount > 0)
            if settings.hotExit, hasUnsavedContent {
                let name = "\(document.id.uuidString).txt"
                do {
                    try document.text.write(to: AppPaths.buffersDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
                    bufferName = name
                    keptBuffers.insert(name)
                } catch {
                    NSLog("Vibe Notepad: couldn't write buffer: \(error)")
                }
            }
            if document.isUntitled, bufferName == nil { continue }
            if document.id == selectedID { selectedIndex = entries.count }
            entryIndex[document.id] = entries.count
            entries.append(SessionDocument(
                path: document.path,
                untitledNumber: document.untitledNumber,
                buffer: bufferName,
                dirty: document.isDirty,
                selection: document.selectionLocation,
                language: document.language,
                languageIsManual: document.languageIsManual,
                markdownMode: document.markdownMode,
                encoding: document.encoding.rawValue,
                hasBOM: document.hasBOM,
                lineEnding: document.lineEnding,
                wrapLines: document.wrapLines,
                modificationDate: document.fileModificationDate,
                binary: document.isBinary ? true : nil
            ))
        }
        var panes: SessionPanes?
        if isSplit {
            var shown: [String: Int] = [:]
            for (pane, document) in paneDocuments { if let index = entryIndex[document] { shown[pane.uuidString] = index } }
            panes = SessionPanes(layout: paneLayout, documents: shown, focused: focusedPaneID)
        }
        let state = SessionState(documents: entries, selectedIndex: selectedIndex, projects: projects.map {
            SessionProject(path: $0.root.path, expandedFolders: $0.expandedFolders.sorted(), collapsed: $0.isCollapsed ? true : nil)
        }, panes: panes)
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: sessionURL, options: .atomic)
        } catch {
            NSLog("Vibe Notepad: couldn't save session: \(error)")
        }
        // Drop buffers that no longer belong to a tab.
        if let files = try? fm.contentsOfDirectory(atPath: AppPaths.buffersDirectory.path) {
            for file in files where !keptBuffers.contains(file) {
                try? fm.removeItem(at: AppPaths.buffersDirectory.appendingPathComponent(file))
            }
        }
    }

    /// Moves hot-exit buffers that no readable session entry refers to into "Recovered", so a
    /// damaged session never costs unsaved text.
    private func recoverUnclaimedBuffers(claimed: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: AppPaths.buffersDirectory.path) else { return }
        let unclaimed = files.filter { !claimed.contains($0) && !$0.hasPrefix(".") }
        guard !unclaimed.isEmpty else { return }
        let folder = AppPaths.supportDirectory.appendingPathComponent("Recovered", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        for file in unclaimed {
            try? fm.moveItem(at: AppPaths.buffersDirectory.appendingPathComponent(file),
                             to: folder.appendingPathComponent("\(stamp)-\(file)"))
        }
        NSLog("Vibe Notepad: moved %d unsaved buffer(s) from an unreadable session to %@", unclaimed.count, folder.path)
        toast("Unsaved text from the last session was kept in Recovered", symbol: "lifepreserver", tint: .orange)
    }

    /// Splits the editor area as it was. Panes whose file is gone show another document, or close.
    private func restorePanes(_ panes: SessionPanes, documents restored: [EditorDocument?]) {
        let layout = panes.layout
        guard layout.paneCount > 1, layout.paneCount <= Self.maxPanes, Set(layout.paneIDs).count == layout.paneCount else { return }
        paneLayout = layout
        paneDocuments = [:]
        for (key, index) in panes.documents {
            guard let pane = UUID(uuidString: key), layout.contains(pane), index >= 0, index < restored.count,
                  let document = restored[index], self.pane(showing: document.id) == nil else { continue }
            paneDocuments[pane] = document.id
        }
        focusedPaneID = layout.contains(panes.focused) ? panes.focused : layout.firstPane
        for pane in layout.paneIDs where paneDocuments[pane] == nil {
            if let document = hiddenDocument() {
                paneDocuments[pane] = document.id
            } else if let smaller = paneLayout.removing(pane) {
                paneLayout = smaller
                if focusedPaneID == pane { focusedPaneID = paneLayout.firstPane }
            }
        }
        // What the panes show counts as recently shown (the focused one most).
        documentHistory = paneLayout.paneIDs.compactMap { paneDocuments[$0] }
        selectedID = paneDocuments[focusedPaneID]
    }

    func restoreSession() {
        guard let data = try? Data(contentsOf: sessionURL) else { return }
        guard let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
            // Keep the unreadable session around instead of overwriting it, and its unsaved text.
            let backup = AppPaths.supportDirectory.appendingPathComponent("session-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: sessionURL, to: backup)
            NSLog("Vibe Notepad: couldn't read the saved session; kept it as \(backup.lastPathComponent)")
            recoverUnclaimedBuffers(claimed: [])
            return
        }
        if state.unreadableDocuments > 0 {
            recoverUnclaimedBuffers(claimed: Set(state.documents.compactMap(\.buffer)))
        }
        isRestoringSession = true
        defer { isRestoringSession = false }

        var restored: [EditorDocument?] = []
        for entry in state.documents {
            let buffer = entry.buffer.flatMap {
                try? String(contentsOf: AppPaths.buffersDirectory.appendingPathComponent($0), encoding: .utf8)
            }
            var document: EditorDocument?
            if let path = entry.path {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path),
                   let loaded = try? FileIO.load(url, encoding: String.Encoding(rawValue: entry.encoding), preserveLineEndings: entry.binary == true) {
                    let text = (entry.dirty ? buffer : nil) ?? loaded.decoded.text
                    let doc = EditorDocument(fileURL: url, text: text, language: entry.language)
                    doc.encoding = loaded.decoded.encoding
                    doc.hasBOM = loaded.decoded.hasBOM
                    doc.lineEnding = loaded.decoded.lineEnding
                    doc.fileModificationDate = loaded.modificationDate
                    doc.isBinary = entry.binary == true
                    if entry.dirty, buffer != nil {
                        doc.isDirty = true
                        doc.pendingDirty = true
                        // The file changed elsewhere while we kept local edits.
                        if let saved = entry.modificationDate, let current = loaded.modificationDate, abs(saved.timeIntervalSince(current)) > 0.001 {
                            doc.externalChange = .modified
                        }
                    }
                    document = doc
                } else if let buffer {
                    // The file is gone but we still hold unsaved content for it.
                    let doc = EditorDocument(fileURL: url, text: buffer, language: entry.language)
                    doc.isDirty = true
                    doc.pendingDirty = true
                    doc.externalChange = .deleted
                    document = doc
                }
            } else if let buffer {
                let doc = EditorDocument(fileURL: nil, text: buffer, language: entry.language, untitledNumber: entry.untitledNumber)
                doc.isDirty = true
                doc.pendingDirty = true
                document = doc
            }
            if let document {
                document.languageIsManual = entry.languageIsManual
                document.markdownMode = entry.markdownMode
                document.wrapLines = entry.wrapLines
                document.pendingSelection = entry.selection
                if entry.path == nil || entry.dirty {
                    document.encoding = String.Encoding(rawValue: entry.encoding)
                    document.hasBOM = entry.hasBOM
                    document.lineEnding = entry.lineEnding
                }
            }
            restored.append(document)
        }
        documents = restored.compactMap { $0 }
        if let index = state.selectedIndex, index < restored.count, let selected = restored[index] {
            selectedID = selected.id
        } else {
            selectedID = documents.last?.id
        }
        if let panes = state.panes { restorePanes(panes, documents: restored) }
        for project in state.projects where URL(fileURLWithPath: project.path).isFolder {
            openProject(URL(fileURLWithPath: project.path), expandedFolders: project.expandedFolders,
                        collapsed: project.collapsed == true, revealSidebar: false)
        }
    }
}
