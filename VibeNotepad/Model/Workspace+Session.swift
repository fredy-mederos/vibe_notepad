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
}

nonisolated struct SessionState: Codable, Sendable {
    var documents: [SessionDocument]
    var selectedIndex: Int?
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
        var keptBuffers = Set<String>()
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
                modificationDate: document.fileModificationDate
            ))
        }
        let selectedIndex = documents.firstIndex { $0.id == selectedID }
        let state = SessionState(documents: entries, selectedIndex: selectedIndex)
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

    func restoreSession() {
        guard let data = try? Data(contentsOf: sessionURL),
              let state = try? JSONDecoder().decode(SessionState.self, from: data) else { return }
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
                if FileManager.default.fileExists(atPath: path), let loaded = try? FileIO.load(url, encoding: String.Encoding(rawValue: entry.encoding)) {
                    let text = (entry.dirty ? buffer : nil) ?? loaded.decoded.text
                    let doc = EditorDocument(fileURL: url, text: text, language: entry.language)
                    doc.encoding = loaded.decoded.encoding
                    doc.hasBOM = loaded.decoded.hasBOM
                    doc.lineEnding = loaded.decoded.lineEnding
                    doc.fileModificationDate = loaded.modificationDate
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
    }
}
