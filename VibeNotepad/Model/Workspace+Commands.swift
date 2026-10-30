import AppKit
import Foundation
import SwiftUI
import VibeCore

/// An entry in the command palette (⇧⌘P).
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var category: String
    var symbol: String
    var shortcut: String?
    var isEnabled = true
    let action: () -> Void
}

/// The command palette's categories, shown beside each command. Formats and languages show their own
/// names (JSON, Markdown, CSV).
enum PaletteCategory {
    static var file: String { String(localized: "File", comment: "Command palette category") }
    static var go: String { String(localized: "Go", comment: "Command palette category: moving around the document") }
    static var find: String { String(localized: "Find", comment: "Command palette category") }
    static var edit: String { String(localized: "Edit", comment: "Command palette category") }
    static var text: String { String(localized: "Text", comment: "Command palette category: changing the selected text") }
    static var folding: String { String(localized: "Folding", comment: "Command palette category: code folding") }
    static var image: String { String(localized: "Image", comment: "Command palette category") }
    static var view: String { String(localized: "View", comment: "Command palette category") }
    static var indentation: String { String(localized: "Indentation", comment: "Command palette category") }
    static var encoding: String { String(localized: "Encoding", comment: "Command palette category: text encodings") }
    static var panes: String { String(localized: "Panes", comment: "Command palette category: the split editor's panes") }
    static var app: String { String(localized: "App", comment: "Command palette category: the app itself") }
}

extension Workspace {
    /// Every command available for the current context.
    var commands: [PaletteCommand] {
        var list: [PaletteCommand] = []
        func add(_ title: String.LocalizationValue, _ category: String, _ symbol: String, _ shortcut: String? = nil, enabled: Bool = true, _ action: @escaping () -> Void) {
            let title = String(localized: title)
            list.append(PaletteCommand(id: "\(category).\(title)", title: title, category: category, symbol: symbol, shortcut: shortcut, isEnabled: enabled, action: action))
        }
        let document = selectedDocument
        let isImage = document?.isImage == true
        let editor = isImage ? nil : document?.editor
        let hasDocument = document != nil
        let hasText = hasDocument && !isImage
        let hasFile = document?.fileURL != nil

        // File
        add("New File", PaletteCategory.file, "doc.badge.plus", "⌘N") { self.newDocument() }
        add("Open…", PaletteCategory.file, "folder", "⌘O") { self.showOpenPanel() }
        add("Open Folder…", PaletteCategory.file, "folder.badge.plus", "⇧⌘O") { self.showOpenFolderPanel() }
        add("Open Enclosing Folder…", PaletteCategory.file, "folder.badge.plus", enabled: hasFile) {
            if let url = document?.fileURL { self.showOpenFolderPanel(revealing: url) }
        }
        for project in projects {
            add(projects.count > 1 ? "Close Folder “\(project.name)”" : "Close Folder", PaletteCategory.file, "folder.badge.minus") { self.closeProject(project) }
        }
        if projects.count > 1 { add("Close All Folders", PaletteCategory.file, "folder.badge.minus") { self.closeAllProjects() } }
        add("Quick Open…", PaletteCategory.file, "magnifyingglass", "⌘P") { self.showPalette(.files) }
        add("Save", PaletteCategory.file, "square.and.arrow.down", "⌘S", enabled: hasText) { self.saveSelected() }
        add("Save As…", PaletteCategory.file, "square.and.arrow.down.on.square", "⇧⌘S", enabled: hasText) {
            if let document { Task { await self.saveAs(document) } }
        }
        add("Save All", PaletteCategory.file, "square.and.arrow.down.fill", "⌥⌘S") { self.saveAll() }
        add("Close Tab", PaletteCategory.file, "xmark", "⌘W", enabled: hasDocument) { self.closeSelected() }
        add("Reopen Closed Tab", PaletteCategory.file, "arrow.uturn.backward", "⇧⌘T") { self.reopenClosedTab() }
        add("Revert to Saved", PaletteCategory.file, "clock.arrow.circlepath", enabled: hasFile && !isImage) { if let document { self.revert(document) } }
        add("Reveal in Finder", PaletteCategory.file, "finder", "⇧⌘R", enabled: hasFile) { self.revealInFinder() }
        add("Copy File Path", PaletteCategory.file, "doc.on.clipboard", "⌥⇧⌘C", enabled: hasFile) { self.copyPath() }
        add(isPinned(document) ? "Unpin from Sidebar" : "Pin to Sidebar", PaletteCategory.file, "pin", enabled: hasFile) { self.togglePin() }
        add("Copy All Text", PaletteCategory.file, "doc.on.doc", enabled: hasText) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(document?.text ?? "", forType: .string)
            self.toast(String(localized: "Copied to clipboard"), symbol: "doc.on.clipboard.fill")
        }

        // Navigation
        add("Go to Line…", PaletteCategory.go, "arrow.right.to.line", "⌃G", enabled: hasText) { self.showPalette(.goToLine) }
        add("Go to Symbol…", PaletteCategory.go, "list.bullet.indent", "⌘R", enabled: hasText) { self.showPalette(.symbols) }
        add("Find…", PaletteCategory.find, "magnifyingglass", "⌘F", enabled: hasText) { self.showFindBar() }
        add("Find and Replace…", PaletteCategory.find, "arrow.left.arrow.right", "⌥⌘F", enabled: hasText) { self.showFindBar(replace: true) }

        // Editing
        if let editor {
            add("Toggle Comment", PaletteCategory.edit, "number", "⌘/") { editor.toggleComment() }
            add("Indent Lines", PaletteCategory.edit, "increase.indent", "⌘]") { editor.indent() }
            add("Outdent Lines", PaletteCategory.edit, "decrease.indent", "⌘[") { editor.outdent() }
            add("Duplicate Line", PaletteCategory.edit, "plus.square.on.square", "⇧⌘D") { editor.duplicate() }
            add("Delete Line", PaletteCategory.edit, "trash", "⌃⇧K") { editor.deleteLines() }
            add("Move Line Up", PaletteCategory.edit, "arrow.up", "⌃⌘↑") { editor.moveLines(up: true) }
            add("Move Line Down", PaletteCategory.edit, "arrow.down", "⌃⌘↓") { editor.moveLines(up: false) }
            add("Join Lines", PaletteCategory.edit, "arrow.right.and.line.vertical.and.arrow.left", "⌘J") { editor.joinLines() }
            add("Select Line", PaletteCategory.edit, "text.line.first.and.arrowtriangle.forward", "⌘L") { editor.selectLine() }
            add("Sort Lines (A → Z)", PaletteCategory.edit, "arrow.up.arrow.down") { editor.sortLines() }
            add("Sort Lines (Z → A)", PaletteCategory.edit, "arrow.up.arrow.down") { editor.sortLines(descending: true) }
            add("Sort Lines & Remove Duplicates", PaletteCategory.edit, "line.3.horizontal.decrease") { editor.sortLines(unique: true) }
            add("Trim Trailing Whitespace", PaletteCategory.edit, "scissors") {
                if !editor.trimTrailingWhitespace() { self.toast(String(localized: "No trailing whitespace"), symbol: "checkmark.circle") }
            }
            add("UPPERCASE", PaletteCategory.text, "textformat.size.larger") { editor.transformSelection("Uppercase") { $0.uppercased() } }
            add("lowercase", PaletteCategory.text, "textformat.size.smaller") { editor.transformSelection("Lowercase") { $0.lowercased() } }
            add("Title Case", PaletteCategory.text, "textformat") { editor.transformSelection("Title Case") { $0.capitalized } }
            add("camelCase", PaletteCategory.text, "textformat.abc") { editor.transformSelection("camelCase") { TextCase.camel($0) } }
            add("snake_case", PaletteCategory.text, "textformat.abc") { editor.transformSelection("snake_case") { TextCase.snake($0) } }
            add("kebab-case", PaletteCategory.text, "textformat.abc") { editor.transformSelection("kebab-case") { TextCase.kebab($0) } }
            add("Base64 Encode", PaletteCategory.text, "lock") { editor.transformSelection("Base64 Encode") { Data($0.utf8).base64EncodedString() } }
            add("Base64 Decode", PaletteCategory.text, "lock.open") {
                editor.transformSelection("Base64 Decode") { text in
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let data = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters), let decoded = String(data: data, encoding: .utf8) else { return text }
                    return decoded
                }
            }
            add("URL Encode", PaletteCategory.text, "link") { editor.transformSelection("URL Encode") { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? $0 } }
            add("URL Decode", PaletteCategory.text, "link") { editor.transformSelection("URL Decode") { $0.removingPercentEncoding ?? $0 } }
            add("Insert UUID", PaletteCategory.text, "number.square") {
                editor.textView.insertText(UUID().uuidString.lowercased(), replacementRange: editor.textView.selectedRange())
            }
            add("Insert Date & Time", PaletteCategory.text, "calendar") {
                editor.textView.insertText(Date.now.formatted(.iso8601), replacementRange: editor.textView.selectedRange())
            }
            if editor.supportsFolding {
                add("Fold", PaletteCategory.folding, "chevron.down.square", "⌥⌘[") { editor.foldAtCaret() }
                add("Unfold", PaletteCategory.folding, "chevron.right.square", "⌥⌘]") { editor.unfoldAtCaret() }
                add("Fold All", PaletteCategory.folding, "rectangle.compress.vertical", "⇧⌥⌘[") { editor.foldAll() }
                add("Unfold All", PaletteCategory.folding, "rectangle.expand.vertical", "⇧⌥⌘]") { editor.unfoldAll() }
                for level in 1...3 {
                    add("Fold Level \(String(level))", PaletteCategory.folding, "list.bullet.indent") { editor.foldAll(level: level) }
                }
            }
            for format in [DataFormat.json, .xml] {
                add("Format \(format.name)", format.name, format.symbol, format == shortcutFormat ? "⌥⌘J" : nil) {
                    self.reformat(editor, as: format, minify: false)
                }
                add("Minify \(format.name)", format.name, format.minifySymbol) { self.reformat(editor, as: format, minify: true) }
            }
            if document?.language == .xml {
                add("Copy XPath", "XML", "doc.on.clipboard", "⌃⇧⌘C") { self.copyXPath(editor.xmlPathAtCaret()) }
                add("Select Element", "XML", "selection.pin.in.out") { self.selectXMLElement(in: editor) }
            }
        }

        // Images (and SVG previews)
        if let viewer = pictureViewer {
            add("Zoom to Fit", PaletteCategory.image, "arrow.down.right.and.arrow.up.left", "⌥⌘0") { viewer.zoomToFit() }
            add("Copy Image", PaletteCategory.image, "photo.on.rectangle") { viewer.copyImage() }
            for background in ImageBackground.allCases where background != settings.imageBackground {
                add("Image Background: \(background.title)", PaletteCategory.image, background.symbol) { self.settings.imageBackground = background }
            }
        }
        if selectedImageViewer != nil, let document {
            add(settings.showsImageInfo ? "Hide Image Info" : "Show Image Info", PaletteCategory.image, "info.circle", "⌘I") { self.toggleImageInfo() }
            add("Open in Default App", PaletteCategory.image, "arrow.up.forward.app") { self.openInDefaultApp(document) }
        }

        // View
        if let document, !document.isImage {
            if document.hasPreview {
                let category = document.isSVG ? "SVG" : (document.isCSV ? document.language.displayName : "Markdown")
                add("Show Editor Only", category, MarkdownMode.editor.symbol, "⌥⌘1") { self.setMarkdownMode(.editor) }
                add("Show Editor & Preview", category, MarkdownMode.split.symbol, "⌥⌘2") { self.setMarkdownMode(.split) }
                add("Show Preview Only", category, MarkdownMode.preview.symbol, "⌥⌘3") { self.setMarkdownMode(.preview) }
            }
            if document.isCSV, let table = document.loadedCSVPreview, table.table != nil {
                let category = document.language.displayName
                add(table.usesHeader ? "Don’t Use First Row as Header" : "Use First Row as Header", category, "tablecells") { table.setUsesHeader(!table.usesHeader) }
                for delimiter in CSVTable.Delimiter.allCases where delimiter != table.table?.delimiter {
                    add("Separate Columns by \(delimiter.localizedName) (\(delimiter.symbol))", category, "tablecells") { table.choose(delimiter) }
                }
                if table.sortSummary != nil {
                    add("Show Rows in File Order", category, "arrow.up.arrow.down") { table.clearSort() }
                }
            }
            if document.isMarkdown {
                add("Export Preview as HTML…", "Markdown", "square.and.arrow.up") { document.preview.exportHTML() }
            }
            let wraps = document.wrapLines ?? settings.wrapLines
            add(wraps ? "Disable Word Wrap" : "Enable Word Wrap", PaletteCategory.view, "text.word.spacing", "⌥⌘W") { document.wrapLines = !wraps }
            add("Change Language…", PaletteCategory.view, "chevron.left.forwardslash.chevron.right") { self.showPalette(.language) }
            add("Indent Using Spaces (2)", PaletteCategory.indentation, "space") { document.indentation = Indentation(usesTabs: false, width: 2) }
            add("Indent Using Spaces (4)", PaletteCategory.indentation, "space") { document.indentation = Indentation(usesTabs: false, width: 4) }
            add("Indent Using Tabs", PaletteCategory.indentation, "arrow.right.to.line.compact") { document.indentation = Indentation(usesTabs: true, width: document.indentation.width) }
            add("Convert Indentation to Spaces", PaletteCategory.indentation, "arrow.triangle.swap") { self.convertIndentation(document, toTabs: false) }
            add("Convert Indentation to Tabs", PaletteCategory.indentation, "arrow.triangle.swap") { self.convertIndentation(document, toTabs: true) }
            for ending in LineEnding.allCases where ending != document.lineEnding {
                add("Line Endings: \(ending.localizedDescription)", PaletteCategory.file, "return") {
                    document.lineEnding = ending
                    document.markChangedWithoutUndo()
                }
            }
            if hasFile {
                add("Reopen with Encoding…", PaletteCategory.file, "character.textbox") { self.showPalette(.commands, seed: PaletteCategory.encoding) }
                for encoding in TextFileCodec.commonEncodings where encoding != document.encoding {
                    add("Reopen as \(TextFileCodec.name(of: encoding))", PaletteCategory.encoding, "character.textbox") { self.reopen(document, encoding: encoding) }
                }
            }
            if document.encoding != .utf8 || document.hasBOM {
                add("Save with Encoding: UTF-8", PaletteCategory.encoding, "character.textbox") {
                    document.encoding = .utf8
                    document.hasBOM = false
                    Task { await self.save(document) }
                }
            }
        }
        let canSplit = paneCount < Self.maxPanes
        add("Split Right", PaletteCategory.panes, "rectangle.split.2x1", "⌘\\", enabled: canSplit) { self.splitPane(.horizontal) }
        add("Split Down", PaletteCategory.panes, "rectangle.split.1x2", "⇧⌘\\", enabled: canSplit) { self.splitPane(.vertical) }
        if isSplit {
            add("Close Pane", PaletteCategory.panes, "xmark.square", "⌃⌘W") { self.closePane() }
            add("Close Other Panes", PaletteCategory.panes, "rectangle") { self.closeOtherPanes() }
            add("Focus Next Pane", PaletteCategory.panes, "arrow.right.square", "⌥⌘`") { self.focusNextPane() }
        }
        for preset in PaneLayout.Preset.allCases where preset != .single || isSplit {
            add("Layout: \(preset.localizedTitle)", PaletteCategory.panes, preset.symbol) { self.applyLayout(preset) }
        }
        add(settings.showLineNumbers ? "Hide Line Numbers" : "Show Line Numbers", PaletteCategory.view, "list.number") { self.settings.showLineNumbers.toggle() }
        add(settings.showInvisibles ? "Hide Invisible Characters" : "Show Invisible Characters", PaletteCategory.view, "paragraphsign") { self.settings.showInvisibles.toggle() }
        add(settings.showMinimap ? "Hide Minimap" : "Show Minimap", PaletteCategory.view, "sidebar.right") { self.settings.showMinimap.toggle() }
        add(settings.highlightCurrentLine ? "Don’t Highlight Current Line" : "Highlight Current Line", PaletteCategory.view, "highlighter") { self.settings.highlightCurrentLine.toggle() }
        add("Zoom In", PaletteCategory.view, "plus.magnifyingglass", "⌘+") { self.zoomIn() }
        add("Zoom Out", PaletteCategory.view, "minus.magnifyingglass", "⌘−") { self.zoomOut() }
        add("Actual Size", PaletteCategory.view, "1.magnifyingglass", "⌘0") { self.resetZoom() }
        add("Change Theme…", PaletteCategory.view, "paintpalette") { self.showPalette(.theme) }
        add("Appearance: Match System", PaletteCategory.view, "circle.lefthalf.filled") { self.settings.appearance = .system }
        add("Appearance: Light", PaletteCategory.view, "sun.max") { self.settings.appearance = .light }
        add("Appearance: Dark", PaletteCategory.view, "moon") { self.settings.appearance = .dark }
        add("Settings…", PaletteCategory.app, "gearshape", "⌘,") { self.openSettings() }
        return list.filter(\.isEnabled)
    }

    private func isPinned(_ document: EditorDocument?) -> Bool {
        guard let path = document?.path else { return false }
        return recents.item(for: path)?.pinned == true
    }

    // MARK: XML element path

    /// Copies the XPath of the element at the caret (`/project/dependencies/dependency[3]/version`).
    func copyXPath(_ path: XMLPath?) {
        guard let path else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path.xpath, forType: .string)
        toast(String(localized: "Copied \(path.xpath)"), symbol: "doc.on.clipboard.fill")
    }

    /// Selects the element around the caret or the selection, from its start tag through its end
    /// tag; again, its parent.
    func selectXMLElement(in editor: EditorController) {
        let selection = editor.textView.selectedRange()
        let text = editor.nsText
        var path = XMLPath.at(selection.location, in: text)
        // Before a "<" is its parent's content, so starting at the element's start goes up a level.
        while let range = path?.elementRange,
              range == selection || range.location > selection.location || NSMaxRange(range) < NSMaxRange(selection) {
            path = XMLPath.at(range.location, in: text)
        }
        guard let range = path?.elementRange else {
            NSSound.beep()
            return
        }
        editor.unfoldIfNeeded(range)
        editor.textView.setSelectedRange(range)
        editor.textView.scrollRangeToVisible(NSRange(location: range.location, length: 0))
        editor.focus()
    }

    /// Selects the name in an element's start tag.
    func goToXMLElement(_ element: XMLPath.Element, in editor: EditorController) {
        editor.reveal(range: NSRange(location: element.start + 1, length: (element.name as NSString).length))
        editor.focus()
    }

    /// The toolbar's Format button: the whole selected document, then back to typing.
    func reformatSelectedDocument(minify: Bool) {
        guard let document = selectedDocument, let format = document.dataFormat else { return }
        let editor = document.editor
        reformat(editor, as: format, minify: minify, wholeDocument: true)
        editor.focus()
    }

    /// The format ⌥⌘J formats: XML in an XML document, JSON anywhere else (including a selection of
    /// JSON in another kind of file).
    var shortcutFormat: DataFormat { selectedDocument?.language == .xml ? .xml : .json }

    /// Formats or minifies the selection (or the whole document) as JSON or XML. Text that already
    /// looks formatted is reformatted all the same (a different indentation, stray spaces).
    func reformat(_ editor: EditorController, as format: DataFormat, minify: Bool, wholeDocument: Bool = false) {
        do {
            if try !editor.reformat(as: format, minify: minify, wholeDocument: wholeDocument) {
                toast(minify ? String(localized: "Already minified") : String(localized: "Already formatted"), symbol: "checkmark.circle")
            }
        } catch {
            toast(VibeCoreStrings.message(for: error), symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    /// Editor, editor and preview, or preview, for Markdown, SVG and CSV. Markdown and CSV files open
    /// the way the last one was shown.
    func setMarkdownMode(_ mode: MarkdownMode) {
        guard let document = selectedDocument, document.hasPreview else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            document.markdownMode = mode
        }
        if document.isMarkdown { settings.markdownMode = mode }
        if document.isCSV { settings.csvMode = mode }
        scheduleSessionSave()
    }

    func cycleMarkdownPreview() {
        guard let document = selectedDocument, document.hasPreview else { return }
        setMarkdownMode(document.markdownMode == .preview ? .editor : .preview)
    }

    func convertIndentation(_ document: EditorDocument, toTabs: Bool) {
        let editor = document.editor
        let width = document.indentation.width
        let lines = document.text.components(separatedBy: "\n")
        let converted = lines.map { line -> String in
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let columns = leading.reduce(0) { $0 + ($1 == "\t" ? width - $0 % width : 1) }
            let indent = toTabs ? String(repeating: "\t", count: columns / width) + String(repeating: " ", count: columns % width)
                                : String(repeating: " ", count: columns)
            return indent + line.dropFirst(leading.count)
        }.joined(separator: "\n")
        let length = editor.textStorage.length
        editor.apply(TextEdit(range: NSRange(location: 0, length: length), replacement: converted,
                              selection: NSRange(location: min(editor.textView.selectedRange().location, (converted as NSString).length), length: 0)),
                     actionName: "Convert Indentation")
        document.indentation = Indentation(usesTabs: toTabs, width: width)
    }
}

/// Identifier case conversions for the command palette.
enum TextCase {
    private static func words(_ s: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for ch in s {
            if ch == "_" || ch == "-" || ch == " " || ch == "." {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if ch.isUppercase, let previous, previous.isLowercase || previous.isNumber {
                if !current.isEmpty { words.append(current) }
                current = String(ch)
            } else {
                current.append(ch)
            }
            previous = ch
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static func camel(_ s: String) -> String {
        let parts = words(s).map { $0.lowercased() }
        guard let first = parts.first else { return s }
        return first + parts.dropFirst().map(\.capitalized).joined()
    }

    static func snake(_ s: String) -> String { words(s).map { $0.lowercased() }.joined(separator: "_") }
    static func kebab(_ s: String) -> String { words(s).map { $0.lowercased() }.joined(separator: "-") }
}
