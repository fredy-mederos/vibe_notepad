import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VibeCore

/// What the floating palette is showing.
enum PaletteMode: Equatable {
    case files
    case commands
    case goToLine
    case symbols
    case language
    case theme
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var symbol: String
    var tint: Color = .accentColor
}

/// App-wide state: open documents (tabs), recents, find and palette UI state.
@Observable
final class Workspace {
    static let shared = Workspace()

    var documents: [EditorDocument] = []
    /// The selected tab: it shows in the focused pane (see Workspace+Panes).
    var selectedID: UUID? {
        didSet {
            guard oldValue != selectedID else { return }
            showSelectionInPanes()
            selectionDidChange(from: oldValue)
        }
    }
    /// How the editor area is split into panes.
    var paneLayout: PaneLayout
    /// The document each pane shows (none for an empty pane). A document shows in one pane at most.
    var paneDocuments: [UUID: UUID] = [:]
    /// The pane that follows the tab selection and has the keyboard focus.
    var focusedPaneID: UUID
    /// Where a tab being dragged over the panes would land.
    var paneDropTarget: PaneDropTarget?
    /// SwiftUI can report a dragged tab over a pane once more after the drop (see `PaneDropDelegate`).
    @ObservationIgnored var lastTabDrop: Date?
    let recents = RecentFilesStore()
    let settings = AppSettings.shared
    /// Folders opened as projects (file trees in the sidebar, Quick Open over all their files).
    var projects: [Project] = []
    /// Folders recently opened as projects, most recent first.
    var recentProjects: [String] = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [] {
        didSet { UserDefaults.standard.set(recentProjects, forKey: "recentProjects") }
    }

    // UI state
    var palette: PaletteMode?
    var paletteSeed = ""
    var findBarVisible = false
    var replaceVisible = false
    var findQuery = ""
    var replaceQuery = ""
    var findOptions = FindOptions()
    var findMatchCount = 0
    var findCurrentIndex: Int?
    var findError: String?
    /// Bumped to ask the find field to take focus.
    var findFocusRequest = 0
    var toasts: [Toast] = []
    /// With the sidebar collapsed, the tabs show only while the pointer is in the title bar.
    var tabsRevealed = false
    var sidebarFilter = ""
    /// A row the sidebar should scroll to (a file shown by opening its enclosing folder).
    var sidebarRevealRequest: SidebarItem?

    @ObservationIgnored private var closedFiles: [(url: URL, selection: Int)] = []
    /// Where each pane is in the window (top-left origin), kept by the pane views for clicks.
    @ObservationIgnored var paneFrames: [UUID: CGRect] = [:]
    /// Documents most recently shown first: a new pane shows the latest one that isn't on screen.
    @ObservationIgnored var documentHistory: [UUID] = []
    @ObservationIgnored var paneClickMonitor: Any?
    @ObservationIgnored var sessionSaveTaskStorage: Task<Void, Never>?
    @ObservationIgnored private var externalCheckTimer: Timer?
    @ObservationIgnored var isRestoringSession = false
    @ObservationIgnored weak var windowReference: NSWindow?
    @ObservationIgnored var tabRevealMonitor: Any?
    @ObservationIgnored var tabHideTask: Task<Void, Never>?
    /// Provided by the main window (SwiftUI's `openSettings`).
    @ObservationIgnored var openSettingsAction: (() -> Void)?

    func openSettings() {
        NSApp.activate()
        openSettingsAction?()
    }

    private init() {
        let pane = UUID()
        paneLayout = .pane(pane)
        focusedPaneID = pane
    }

    var selectedDocument: EditorDocument? {
        guard let selectedID else { return nil }
        return documents.first { $0.id == selectedID }
    }

    var activeEditor: EditorController? { selectedDocument?.loadedEditor }

    /// The status bar shows only while the sidebar is open: collapsing the sidebar leaves just
    /// the text (tabs, toolbar buttons and the minimap go too).
    var showsStatusBar: Bool { selectedDocument != nil && settings.showsSidebar }

    // MARK: Lifecycle

    func start() {
        settings.startObservingAppearance()
        observeSettings()
        observeSidebar()
        if settings.restoreSession { restoreSession() }
        externalCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            Task { @MainActor in
                let workspace = Workspace.shared
                if NSApp.isActive {
                    workspace.checkExternalChanges()
                } else if let window = workspace.mainWindow, window.occlusionState.contains(.visible) {
                    // In the background, keep the visible tab current (a log on a second screen).
                    workspace.checkExternalChanges(onlySelected: true)
                }
            }
        }
    }

    /// Re-applies editor settings whenever a relevant preference changes.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.theme
            _ = settings.fontName
            _ = settings.fontSize
            _ = settings.lineHeight
            _ = settings.wrapLines
            _ = settings.showLineNumbers
            _ = settings.highlightCurrentLine
            _ = settings.showInvisibles
            _ = settings.showGitChanges
            _ = settings.showMinimap
            _ = settings.autoCloseBrackets
            _ = settings.spellCheckProse
            _ = settings.previewFont
            _ = settings.previewFontSize
        } onChange: {
            Task { @MainActor in
                Workspace.shared.applySettingsToEditors()
                Workspace.shared.observeSettings()
            }
        }
    }

    /// Collapsing the sidebar also hides the editors' minimaps (see `EditorController.sidebarWillToggle`).
    private func observeSidebar() {
        withObservationTracking {
            _ = settings.showsSidebar
        } onChange: {
            Task { @MainActor in
                let workspace = Workspace.shared
                let showing = workspace.settings.showsSidebar
                for document in workspace.documents { document.loadedEditor?.sidebarWillToggle(showing: showing) }
                workspace.hideTabs(animated: false)
                workspace.observeSidebar()
            }
        }
    }

    func applySettingsToEditors() {
        let theme = settings.theme
        for document in documents {
            document.loadedEditor?.applySettings(settings, theme: theme)
            document.loadedPreview?.applyTheme()
            document.loadedImageViewer?.applyTheme()
        }
    }

    // MARK: Selection

    func select(_ document: EditorDocument) {
        withAnimation(.snappy(duration: 0.25)) { selectedID = document.id }
    }

    private func selectionDidChange(from oldID: UUID?) {
        if let oldID, let old = documents.first(where: { $0.id == oldID }) {
            old.loadedEditor?.endFind()
            rememberState(of: old)
        }
        if findBarVisible { performFind(reveal: false) }
        checkExternalChanges()
        selectedDocument?.loadedEditor?.refreshGitBase(ifOlderThan: 5)
        scheduleSessionSave()
    }

    func selectNextTab(_ forward: Bool) {
        guard !documents.isEmpty else { return }
        let index = documents.firstIndex { $0.id == selectedID } ?? 0
        let next = (index + (forward ? 1 : -1) + documents.count) % documents.count
        select(documents[next])
    }

    func selectTab(at index: Int) {
        guard !documents.isEmpty else { return }
        // ⌘9 always means the last tab, like browsers.
        select(index >= 8 ? documents[documents.count - 1] : documents[min(index, documents.count - 1)])
    }

    func moveDocument(_ id: UUID, before target: UUID?) {
        guard let from = documents.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy) {
            let document = documents.remove(at: from)
            if let target, let to = documents.firstIndex(where: { $0.id == target }) {
                documents.insert(document, at: to)
            } else {
                documents.append(document)
            }
        }
        scheduleSessionSave()
    }

    // MARK: Creating & opening

    @discardableResult
    func newDocument(text: String = "", language: LanguageID = .plainText) -> EditorDocument {
        let used = Set(documents.filter(\.isUntitled).map(\.untitledNumber))
        let number = (1...).first { !used.contains($0) } ?? 1
        let text = TextFileCodec.normalizeLineEndings(text)
        let document = EditorDocument(fileURL: nil, text: text, language: language, untitledNumber: number)
        // Text handed over by a link or script exists nowhere else: closing should offer to save it.
        if !text.isEmpty { document.markChangedWithoutUndo() }
        insert(document)
        return document
    }

    private func insert(_ document: EditorDocument) {
        withAnimation(.snappy(duration: 0.3)) {
            if let selected = selectedDocument, let index = documents.firstIndex(where: { $0.id == selected.id }) {
                documents.insert(document, at: index + 1)
            } else {
                documents.append(document)
            }
            selectedID = document.id
        }
        scheduleSessionSave()
    }

    /// Opens files as tabs and folders as projects.
    func open(urls: [URL]) {
        var last: EditorDocument?
        for url in urls {
            if url.isFolder {
                openProject(url)
                continue
            }
            if let document = open(url: url, select: false) { last = document }
        }
        if let last { select(last) }
        NSApp.activate()
    }

    /// Opens `url` (or selects its tab if already open). Pictures open in the image viewer.
    @discardableResult
    func open(url rawURL: URL, select shouldSelect: Bool = true, encoding: String.Encoding? = nil) -> EditorDocument? {
        let url = rawURL.canonicalFileURL
        // The same file reached through a symlink (or the symlink itself) shares one tab.
        let resolved = url.resolvingSymlinksInPath().canonicalPath
        if let existing = documents.first(where: { $0.path == url.path })
            ?? documents.first(where: { $0.fileURL.map { $0.resolvingSymlinksInPath().canonicalPath == resolved } ?? false }) {
            if shouldSelect { select(existing) }
            return existing
        }
        let document: EditorDocument
        if ImageFile.isImage(url), !url.isFolder, FileManager.default.fileExists(atPath: url.path) {
            document = imageDocument(url)
        } else {
            guard let text = textDocument(url, encoding: encoding) else { return nil }
            document = text
        }

        // Replace an empty untitled tab, like TextEdit does (after the file has taken its place, so its
        // pane shows the file).
        let replaced = selectedDocument.flatMap { $0.isPristineUntitled && (documents.count == 1 || shouldSelect) ? $0 : nil }
        if shouldSelect {
            insert(document)
        } else {
            withAnimation(.snappy(duration: 0.3)) { documents.append(document) }
        }
        if let replaced { remove(replaced, remember: false) }
        recents.noteOpened(url)
        scheduleSessionSave()
        return document
    }

    /// Reads the file at `url` into a new text tab (or an image tab, for a picture without a picture's
    /// name). Errors are reported; nil means nothing opens.
    private func textDocument(_ url: URL, encoding: String.Encoding?) -> EditorDocument? {
        let loaded: FileIO.Loaded
        var isBinary = false
        do {
            loaded = try FileIO.load(url, encoding: encoding)
        } catch TextFileCodec.CodecError.binary {
            if encoding == nil, ImageFile.decodes(url) { return imageDocument(url) }
            guard confirmOpenBinary(url) else { return nil }
            guard let latin = try? FileIO.load(url, encoding: .isoLatin1, preserveLineEndings: true) else { return nil }
            loaded = latin
            isBinary = true
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                recents.refreshMissing()
                toast("“\(url.lastPathComponent)” no longer exists", symbol: "exclamationmark.triangle.fill", tint: .orange)
            } else {
                presentError(error, title: "Couldn’t open “\(url.lastPathComponent)”")
            }
            return nil
        }

        let remembered = recents.item(for: url.path)
        let language = remembered?.language ?? LanguageRegistry.detect(path: url.path, content: String(loaded.decoded.text.prefix(4096)))
        let document = EditorDocument(fileURL: url, text: loaded.decoded.text, language: language)
        document.languageIsManual = remembered?.language != nil
        document.encoding = loaded.decoded.encoding
        document.hasBOM = loaded.decoded.hasBOM
        document.lineEnding = loaded.decoded.lineEnding
        document.fileModificationDate = loaded.modificationDate
        document.isBinary = isBinary
        if let mode = remembered?.markdownMode { document.markdownMode = mode }
        document.pendingSelection = remembered?.selection
        return document
    }

    private func confirmOpenBinary(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” looks like a binary file"
        alert.informativeText = "It can be opened as Latin-1 text, but it will probably look like gibberish. Saving keeps the bytes unchanged."
        alert.addButton(withTitle: "Open Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Open any text file or image, or a folder as a project"
        if let directory = selectedDocument?.fileURL?.deletingLastPathComponent() { panel.directoryURL = directory }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            Task { @MainActor in Workspace.shared.open(urls: panel.urls) }
        }
        if let window = mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    func reopenClosedTab() {
        while let entry = closedFiles.popLast() {
            if let document = open(url: entry.url) {
                document.loadedEditor?.reveal(range: NSRange(location: entry.selection, length: 0), indicator: false)
                return
            }
        }
        NSSound.beep()
    }

    // MARK: Closing

    func close(_ document: EditorDocument) {
        Task { await closeAsync(document) }
    }

    func closeSelected() {
        // ⌘W in Settings (or any other window) closes that window, not a tab behind it.
        if let key = NSApp.keyWindow, let main = mainWindow, key !== main {
            key.performClose(nil)
            return
        }
        if let document = selectedDocument {
            close(document)
        } else {
            mainWindow?.performClose(nil)
        }
    }

    @discardableResult
    func closeAsync(_ document: EditorDocument) async -> Bool {
        if document.isDirty {
            select(document)
            switch await confirmSave(document) {
            case .alertFirstButtonReturn:
                guard await save(document) else { return false }
            case .alertSecondButtonReturn:
                break
            default:
                return false
            }
        }
        remove(document, remember: true)
        return true
    }

    func closeOthers(_ keep: EditorDocument) {
        Task {
            for document in documents where document.id != keep.id {
                guard await closeAsync(document) else { return }
            }
        }
    }

    func closeToTheRight(of document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        let targets = Array(documents.suffix(from: index + 1))
        Task {
            for target in targets {
                guard await closeAsync(target) else { return }
            }
        }
    }

    private func remove(_ document: EditorDocument, remember: Bool) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        rememberState(of: document)
        if remember, let url = document.fileURL {
            closedFiles.append((url, document.selectionLocation))
            if closedFiles.count > 30 { closedFiles.removeFirst() }
        }
        if findBarVisible, selectedID == document.id, documents.count == 1 { findBarVisible = false }
        withAnimation(.snappy(duration: 0.28)) {
            documents.remove(at: index)
            documentHistory.removeAll { $0 == document.id }
            if let pane = pane(showing: document.id) { paneLostDocument(pane, near: index) }
        }
        document.tearDown()
        scheduleSessionSave()
    }

    private func confirmSave(_ document: EditorDocument) async -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(document.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: document.isUntitled ? "Save…" : "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        if let window = mainWindow {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }

    /// Persists caret position and view mode so reopening the file feels continuous.
    private func rememberState(of document: EditorDocument) {
        guard let path = document.path else { return }
        let selection = document.selectionLocation
        recents.update(path) { item in
            item.selection = selection
            item.markdownMode = document.isMarkdown ? document.markdownMode : nil
            item.language = document.languageIsManual ? document.language : nil
        }
    }

    // MARK: Saving

    @discardableResult
    func save(_ document: EditorDocument) async -> Bool {
        // Pictures are read-only: there's never anything to save.
        guard !document.isImage else { return true }
        guard let url = document.fileURL else { return await saveAs(document) }
        // Another app changed the file since we read it: don't silently overwrite its changes.
        if let known = document.fileModificationDate, let current = FileIO.modificationDate(of: url),
           abs(current.timeIntervalSince(known)) > 0.0005, !confirmOverwrite(document) {
            return false
        }
        return write(document, to: url)
    }

    private func confirmOverwrite(_ document: EditorDocument) -> Bool {
        let alert = NSAlert()
        alert.messageText = "“\(document.displayName)” was changed by another app"
        alert.informativeText = "Saving replaces those changes with the text in this tab."
        alert.addButton(withTitle: "Save Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    @discardableResult
    func saveAs(_ document: EditorDocument) async -> Bool {
        guard !document.isImage else { return false }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.fileURL?.lastPathComponent ?? (document.isMarkdown ? "Untitled.md" : "Untitled.txt")
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = true
        if let directory = document.fileURL?.deletingLastPathComponent() ?? selectedDocument?.fileURL?.deletingLastPathComponent() {
            panel.directoryURL = directory
        }
        let response: NSApplication.ModalResponse
        if let window = mainWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return false }
        let oldPath = document.path
        document.fileURL = url
        if !document.languageIsManual {
            document.language = LanguageRegistry.detect(path: url.path, content: String(document.text.prefix(4096)))
        }
        guard write(document, to: url) else { return false }
        if let oldPath, oldPath != url.path { recents.refreshMissing() }
        document.loadedPreview?.reloadTemplate()
        return true
    }

    func saveSelected() {
        guard let document = selectedDocument else { return }
        Task { await save(document) }
    }

    func saveAll() {
        Task {
            for document in documents where document.isDirty {
                guard await save(document) else { return }
            }
        }
    }

    private func write(_ document: EditorDocument, to url: URL) -> Bool {
        do {
            let date = try FileIO.save(document.text, to: url, encoding: document.encoding, hasBOM: document.hasBOM, lineEnding: document.lineEnding)
            didSave(document, url: url, date: date)
            return true
        } catch TextFileCodec.CodecError.unencodable(let name) {
            let alert = NSAlert()
            alert.messageText = "“\(document.displayName)” can’t be saved as \(name)"
            alert.informativeText = "The text contains characters that \(name) can’t represent. Save it as UTF-8 instead?"
            alert.addButton(withTitle: "Save as UTF-8")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            document.encoding = .utf8
            document.hasBOM = false
            return write(document, to: url)
        } catch {
            presentError(error, title: "Couldn’t save “\(document.displayName)”")
            return false
        }
    }

    private func didSave(_ document: EditorDocument, url: URL, date: Date?) {
        document.fileModificationDate = date
        document.externalChange = nil
        document.loadedEditor?.markSaved()
        document.pendingDirty = false
        document.isDirty = false
        document.saveCount += 1
        // A new path (Save As) can be in a repository; an untracked file can have become tracked.
        document.loadedEditor?.refreshGitBase()
        recents.noteOpened(url)
        toast("Saved \(document.displayName)", symbol: "checkmark.circle.fill", tint: .green)
        scheduleSessionSave()
    }

    // MARK: Reloading

    func revert(_ document: EditorDocument) {
        guard !document.isImage else { return }
        guard let url = document.fileURL, confirmDiscardingChanges(document, action: "Revert") else { return }
        reload(document, from: url, encoding: document.isBinary ? .isoLatin1 : nil, announce: "Reverted to saved")
    }

    func reopen(_ document: EditorDocument, encoding: String.Encoding) {
        guard !document.isImage else { return }
        guard let url = document.fileURL, confirmDiscardingChanges(document, action: "Reopen") else { return }
        document.isBinary = false
        reload(document, from: url, encoding: encoding, announce: "Reopened as \(TextFileCodec.name(of: encoding))")
    }

    /// Reverting or reopening throws away unsaved edits (and their undo history): ask first.
    private func confirmDiscardingChanges(_ document: EditorDocument, action: String) -> Bool {
        guard document.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard your changes to “\(document.displayName)”?"
        alert.informativeText = "\(action) loads the file from disk again. Your unsaved changes will be lost."
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func reload(_ document: EditorDocument, from url: URL, encoding: String.Encoding?, announce: String?, followTail: Bool = false) {
        do {
            let loaded = try FileIO.load(url, encoding: encoding, preserveLineEndings: document.isBinary)
            let editor = document.editor
            let atEnd = followTail && editor.isScrolledToEnd
            let caretAtEnd = followTail && editor.textView.selectedRange() == NSRange(location: editor.textStorage.length, length: 0)
            document.encoding = loaded.decoded.encoding
            document.hasBOM = loaded.decoded.hasBOM
            document.lineEnding = loaded.decoded.lineEnding
            document.fileModificationDate = loaded.modificationDate
            document.externalChange = nil
            editor.replaceAllText(loaded.decoded.text)
            if caretAtEnd { editor.textView.setSelectedRange(NSRange(location: editor.textStorage.length, length: 0)) }
            if atEnd { editor.scrollToEnd() }
            document.pendingDirty = false
            document.isDirty = false
            document.reloadCount += 1
            if let announce { toast(announce, symbol: "arrow.clockwise.circle.fill") }
        } catch {
            presentError(error, title: "Couldn’t reload “\(document.displayName)”")
        }
    }

    /// Reloads files changed by other apps (when clean) or flags them (when edited here).
    func checkExternalChanges(onlySelected: Bool = false) {
        let candidates = onlySelected ? [selectedDocument].compactMap { $0 } : documents
        for document in candidates {
            guard let url = document.fileURL else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else {
                if document.externalChange != .deleted, !document.deletionDismissed { document.externalChange = .deleted }
                continue
            }
            document.deletionDismissed = false
            if document.externalChange == .deleted { document.externalChange = nil }
            guard let date = FileIO.modificationDate(of: url), let known = document.fileModificationDate,
                  abs(date.timeIntervalSince(known)) > 0.0005 else { continue }
            if document.isImage {
                // A picture that keeps changing (a chart a script redraws) reloads quietly.
                let quiet = document.lastAutoReload.map { Date().timeIntervalSince($0) < 60 } ?? false
                reloadImage(document)
                document.lastAutoReload = Date()
                if !quiet {
                    toast("“\(document.displayName)” changed on disk — reloaded", symbol: "arrow.triangle.2.circlepath", tint: .blue)
                }
            } else if !document.isDirty, settings.reloadChangedFiles {
                // Files that change all the time (logs) reload quietly, and keep following the end.
                let quiet = document.language == .log || document.lastAutoReload.map { Date().timeIntervalSince($0) < 60 } ?? false
                reload(document, from: url, encoding: document.encoding, announce: nil, followTail: true)
                document.lastAutoReload = Date()
                if !quiet {
                    toast("“\(document.displayName)” changed on disk — reloaded", symbol: "arrow.triangle.2.circlepath", tint: .blue)
                }
            } else if document.externalChange == nil {
                document.externalChange = .modified
            }
        }
    }

    func keepLocalVersion(_ document: EditorDocument) {
        document.externalChange = nil
        if let url = document.fileURL { document.fileModificationDate = FileIO.modificationDate(of: url) }
    }

    func reloadFromDisk(_ document: EditorDocument) {
        if document.isImage {
            reloadImage(document)
            return
        }
        guard let url = document.fileURL else { return }
        reload(document, from: url, encoding: document.encoding, announce: "Reloaded from disk")
    }

    // MARK: File actions

    /// Git's state may have changed (a commit, checkout or `git add`): re-read the shown file's
    /// staged version now, and the other tabs' when they're next shown.
    func gitStateDidChange() {
        for document in documents where document.id != selectedID { document.loadedEditor?.markGitBaseStale() }
        selectedDocument?.loadedEditor?.refreshGitBase()
    }

    func revealInFinder(_ document: EditorDocument? = nil) {
        guard let url = (document ?? selectedDocument)?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPath(_ document: EditorDocument? = nil) {
        guard let url = (document ?? selectedDocument)?.fileURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        toast("Copied path", symbol: "doc.on.clipboard.fill")
    }

    func togglePin(_ document: EditorDocument? = nil) {
        guard let url = (document ?? selectedDocument)?.fileURL else { return }
        let path = url.canonicalPath
        if recents.item(for: path) == nil { recents.noteOpened(url) }
        recents.togglePin(path)
        let pinned = recents.item(for: path)?.pinned == true
        toast(pinned ? "Pinned to sidebar" : "Unpinned", symbol: pinned ? "pin.fill" : "pin.slash")
    }

    // MARK: Find

    func showFindBar(replace: Bool = false) {
        guard selectedDocument?.isImage != true else {
            NSSound.beep()
            return
        }
        if let editor = activeEditor {
            let selection = editor.textView.selectedRange()
            if selection.length > 0, selection.length < 300 {
                let selected = editor.nsText.substring(with: selection)
                if !selected.contains("\n") { findQuery = selected }
            }
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            findBarVisible = true
            if replace { replaceVisible = true }
        }
        findFocusRequest += 1
        performFind(reveal: false)
    }

    func hideFindBar() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            findBarVisible = false
        }
        for document in documents { document.loadedEditor?.endFind() }
        findMatchCount = 0
        findCurrentIndex = nil
        focusSelectedDocument()
    }

    /// In Markdown "Preview only" mode, find searches the rendered page.
    var findsInPreview: Bool {
        guard let document = selectedDocument else { return false }
        return document.isMarkdown && document.markdownMode == .preview
    }

    private func findInPreview(forward: Bool) {
        guard let preview = selectedDocument?.preview else { return }
        findError = nil
        preview.find(findQuery, forward: forward, caseSensitive: findOptions.caseSensitive) { found in
            Workspace.shared.findMatchCount = found ? 1 : 0
            Workspace.shared.findCurrentIndex = nil
        }
    }

    func performFind(reveal: Bool) {
        if findsInPreview {
            findInPreview(forward: true)
            return
        }
        guard let editor = activeEditor else { return }
        do {
            findError = nil
            findMatchCount = try editor.find(findQuery, options: findOptions, reveal: reveal)
        } catch {
            findError = error.localizedDescription
            findMatchCount = 0
            editor.endFind()
        }
        findCurrentIndex = editor.currentMatchIndex
    }

    func findNext(forward: Bool = true) {
        if !findBarVisible {
            showFindBar()
            return
        }
        if findsInPreview {
            findInPreview(forward: forward)
            return
        }
        guard let editor = activeEditor else { return }
        if !editor.hasFindMatches { performFind(reveal: true) }
        editor.findNext(forward: forward)
        findCurrentIndex = editor.currentMatchIndex
    }

    func useSelectionForFind() {
        guard let editor = activeEditor else { return }
        let selection = editor.textView.selectedRange()
        let range = selection.length > 0 ? selection : TextTransforms.wordRange(editor.nsText, at: selection.location)
        guard range.length > 0 else { return }
        findQuery = editor.nsText.substring(with: range)
        if !findBarVisible {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { findBarVisible = true }
        }
        performFind(reveal: false)
    }

    func replaceCurrent() {
        guard let editor = activeEditor else { return }
        do {
            try editor.replaceCurrent(query: findQuery, template: replaceQuery, options: findOptions)
            findMatchCount = editor.findMatches.count
            findCurrentIndex = editor.currentMatchIndex
        } catch {
            findError = error.localizedDescription
        }
    }

    func replaceAll() {
        guard let editor = activeEditor else { return }
        do {
            let count = try editor.replaceAll(query: findQuery, template: replaceQuery, options: findOptions)
            findMatchCount = editor.findMatches.count
            findCurrentIndex = editor.currentMatchIndex
            toast(count == 0 ? "Nothing to replace" : "Replaced \(count) occurrence\(count == 1 ? "" : "s")", symbol: "arrow.left.arrow.right.circle.fill")
        } catch {
            findError = error.localizedDescription
        }
    }

    // MARK: Palette

    func showPalette(_ mode: PaletteMode, seed: String = "") {
        paletteSeed = seed
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { palette = mode }
    }

    /// Gives the keyboard to the selected tab's editor, or its picture.
    func focusSelectedDocument() {
        if let editor = activeEditor {
            editor.focus()
        } else {
            selectedDocument?.loadedImageViewer?.focus()
        }
    }

    func hidePalette(refocus: Bool = true) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { palette = nil }
        if refocus { focusSelectedDocument() }
    }

    // MARK: Toasts

    func toast(_ message: String, symbol: String, tint: Color = .accentColor) {
        let toast = Toast(message: message, symbol: symbol, tint: tint)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            toasts.removeAll { $0.message == message }
            toasts.append(toast)
            if toasts.count > 3 { toasts.removeFirst() }
        }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeOut(duration: 0.3)) { toasts.removeAll { $0.id == toast.id } }
        }
    }

    // MARK: Helpers

    var mainWindow: NSWindow? {
        if let windowReference, windowReference.isVisible { return windowReference }
        return NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
            ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window = mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
