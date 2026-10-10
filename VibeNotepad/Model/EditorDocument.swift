import AppKit
import Observation
import VibeCore

/// One open tab: a file on disk (or an untitled buffer) plus its editing state.
@Observable
final class EditorDocument: Identifiable {
    struct Cursor: Equatable {
        var line = 1
        var column = 1
        var selectionLength = 0
        var selectedLines = 0
        var lineCount = 1
    }

    enum ExternalChange: Equatable {
        case modified
        case deleted
    }

    let id: UUID
    var fileURL: URL?
    var untitledNumber: Int

    var language: LanguageID {
        didSet {
            guard oldValue != language else { return }
            loadedEditor?.setLanguage(language)
            if language == .markdown, oldValue != .markdown { markdownMode = AppSettings.shared.markdownMode }
            Workspace.shared.scheduleSessionSave()
        }
    }
    var languageIsManual = false
    var encoding: String.Encoding = .utf8
    var hasBOM = false
    var lineEnding: LineEnding = .lf
    var indentation: Indentation {
        didSet {
            guard oldValue != indentation, let editor = loadedEditor else { return }
            editor.applySettings(AppSettings.shared, theme: AppSettings.shared.theme)
        }
    }
    var isDirty = false
    var fileModificationDate: Date?
    /// Opened as a binary file: decoded byte for byte, which reloads must do too.
    var isBinary = false
    var markdownMode: MarkdownMode
    /// Per-document override of the word-wrap setting.
    var wrapLines: Bool? {
        didSet { loadedEditor?.setWrap(wrapLines ?? AppSettings.shared.wrapLines) }
    }
    var cursor = Cursor()
    var wordCount: Int?
    var characterCount = 0
    var externalChange: ExternalChange?
    /// Bumped on every save so views can animate a confirmation.
    var saveCount = 0
    /// Bumped when the file is reloaded from disk.
    var reloadCount = 0

    @ObservationIgnored private var editorStorage: EditorController?
    @ObservationIgnored private var previewStorage: MarkdownPreviewController?
    @ObservationIgnored private var initialText: String
    @ObservationIgnored var pendingSelection: Int?
    @ObservationIgnored var pendingDirty = false
    @ObservationIgnored private var pendingNavigation: (line: Int, column: Int?)?
    @ObservationIgnored private var needsInitialScroll = false
    @ObservationIgnored private var statsTask: Task<Void, Never>?

    init(id: UUID = UUID(), fileURL: URL?, text: String, language: LanguageID, untitledNumber: Int = 0) {
        self.id = id
        self.fileURL = fileURL
        self.untitledNumber = untitledNumber
        self.initialText = text
        self.language = language
        self.markdownMode = AppSettings.shared.markdownMode
        self.indentation = Indentation(usesTabs: !AppSettings.shared.insertSpaces, width: AppSettings.shared.tabWidth)
        self.characterCount = (text as NSString).length
        if AppSettings.shared.detectIndentation, let detected = TextFileCodec.detectIndentation(in: text) {
            self.indentation = detected
        }
        scheduleStats(text: text)
    }

    // MARK: Derived

    var displayName: String {
        if let fileURL { return fileURL.lastPathComponent }
        return untitledNumber > 1 ? "Untitled \(untitledNumber)" : "Untitled"
    }

    var isUntitled: Bool { fileURL == nil }
    var isMarkdown: Bool { language == .markdown }
    var path: String? { fileURL?.canonicalPath }

    /// Whether this is an empty, unmodified untitled buffer that can be replaced by an opened file.
    var isPristineUntitled: Bool { fileURL == nil && !isDirty && characterCount == 0 }

    // MARK: Editor & preview

    /// The AppKit editor, created on first use.
    var editor: EditorController {
        if let editorStorage { return editorStorage }
        let editor = EditorController(document: self, text: initialText)
        initialText = ""
        editorStorage = editor
        if let selection = pendingSelection {
            let location = min(selection, editor.textStorage.length)
            editor.textView.setSelectedRange(NSRange(location: location, length: 0))
            pendingSelection = nil
            needsInitialScroll = location > 0
        }
        if pendingDirty {
            editor.markDirtyWithoutUndo()
            pendingDirty = false
        }
        editor.updateStatus()
        return editor
    }

    var loadedEditor: EditorController? { editorStorage }

    /// Moves the caret to a 1-based line (and column), now or once the editor is on screen.
    func navigate(toLine line: Int, column: Int?) {
        if let editor = editorStorage, editor.textView.window != nil {
            editor.goTo(line: line, column: column)
        } else {
            pendingNavigation = (line, column)
        }
    }

    /// Called by the editor host once the text view is in a window and sized.
    func editorDidAttach() {
        guard let editor = editorStorage else { return }
        if let navigation = pendingNavigation {
            pendingNavigation = nil
            editor.goTo(line: navigation.line, column: navigation.column)
        } else if needsInitialScroll {
            needsInitialScroll = false
            editor.scrollToCenter(editor.textView.selectedRange())
        }
        editor.styleVisible()
    }

    var preview: MarkdownPreviewController {
        if let previewStorage { return previewStorage }
        let preview = MarkdownPreviewController(document: self)
        previewStorage = preview
        return preview
    }

    var loadedPreview: MarkdownPreviewController? { previewStorage }

    var text: String { editorStorage?.text ?? initialText }

    var selectionLocation: Int {
        editorStorage?.textView.selectedRange().location ?? pendingSelection ?? 0
    }

    /// Marks a change that isn't in the text (line endings, encoding) so the document needs saving.
    func markChangedWithoutUndo() {
        if let editor = editorStorage { editor.markDirtyWithoutUndo() } else { pendingDirty = true }
        isDirty = true
    }

    /// Called by the editor after every edit.
    func contentDidChange() {
        guard let editor = editorStorage else { return }
        characterCount = editor.textStorage.length
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.scheduleStats(text: self.text)
        }
        loadedPreview?.textDidChange()
        Workspace.shared.scheduleSessionSave()
    }

    private func scheduleStats(text: String) {
        guard language.info.isProse || language == .markdown, (text as NSString).length < 3_000_000 else {
            wordCount = nil
            return
        }
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let isSpace = scalar.properties.isWhitespace
            if !isSpace && !inWord { count += 1 }
            inWord = !isSpace
        }
        wordCount = count
    }

    /// Releases views when the tab closes.
    func tearDown() {
        statsTask?.cancel()
        previewStorage?.tearDown()
        editorStorage?.endFind()
        editorStorage?.rootView.removeFromSuperview()
    }
}
