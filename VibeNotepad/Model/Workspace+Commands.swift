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

extension Workspace {
    /// Every command available for the current context.
    var commands: [PaletteCommand] {
        var list: [PaletteCommand] = []
        func add(_ title: String, _ category: String, _ symbol: String, _ shortcut: String? = nil, enabled: Bool = true, _ action: @escaping () -> Void) {
            list.append(PaletteCommand(id: "\(category).\(title)", title: title, category: category, symbol: symbol, shortcut: shortcut, isEnabled: enabled, action: action))
        }
        let document = selectedDocument
        let editor = document?.editor
        let hasDocument = document != nil
        let hasFile = document?.fileURL != nil

        // File
        add("New File", "File", "doc.badge.plus", "⌘N") { self.newDocument() }
        add("Open…", "File", "folder", "⌘O") { self.showOpenPanel() }
        add("Quick Open…", "File", "magnifyingglass", "⌘P") { self.showPalette(.files) }
        add("Save", "File", "square.and.arrow.down", "⌘S", enabled: hasDocument) { self.saveSelected() }
        add("Save As…", "File", "square.and.arrow.down.on.square", "⇧⌘S", enabled: hasDocument) {
            if let document { Task { await self.saveAs(document) } }
        }
        add("Save All", "File", "square.and.arrow.down.fill", "⌥⌘S") { self.saveAll() }
        add("Close Tab", "File", "xmark", "⌘W", enabled: hasDocument) { self.closeSelected() }
        add("Reopen Closed Tab", "File", "arrow.uturn.backward", "⇧⌘T") { self.reopenClosedTab() }
        add("Revert to Saved", "File", "clock.arrow.circlepath", enabled: hasFile) { if let document { self.revert(document) } }
        add("Reveal in Finder", "File", "finder", "⇧⌘R", enabled: hasFile) { self.revealInFinder() }
        add("Copy File Path", "File", "doc.on.clipboard", "⌥⇧⌘C", enabled: hasFile) { self.copyPath() }
        add(isPinned(document) ? "Unpin from Sidebar" : "Pin to Sidebar", "File", "pin", enabled: hasFile) { self.togglePin() }
        add("Copy All Text", "File", "doc.on.doc", enabled: hasDocument) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(document?.text ?? "", forType: .string)
            self.toast("Copied to clipboard", symbol: "doc.on.clipboard.fill")
        }

        // Navigation
        add("Go to Line…", "Go", "arrow.right.to.line", "⌃G", enabled: hasDocument) { self.showPalette(.goToLine) }
        add("Go to Symbol…", "Go", "list.bullet.indent", "⌘R", enabled: hasDocument) { self.showPalette(.symbols) }
        add("Find…", "Find", "magnifyingglass", "⌘F", enabled: hasDocument) { self.showFindBar() }
        add("Find and Replace…", "Find", "arrow.left.arrow.right", "⌥⌘F", enabled: hasDocument) { self.showFindBar(replace: true) }

        // Editing
        if let editor {
            add("Toggle Comment", "Edit", "number", "⌘/") { editor.toggleComment() }
            add("Indent Lines", "Edit", "increase.indent", "⌘]") { editor.indent() }
            add("Outdent Lines", "Edit", "decrease.indent", "⌘[") { editor.outdent() }
            add("Duplicate Line", "Edit", "plus.square.on.square", "⇧⌘D") { editor.duplicate() }
            add("Delete Line", "Edit", "trash", "⌃⇧K") { editor.deleteLines() }
            add("Move Line Up", "Edit", "arrow.up", "⌃⌘↑") { editor.moveLines(up: true) }
            add("Move Line Down", "Edit", "arrow.down", "⌃⌘↓") { editor.moveLines(up: false) }
            add("Join Lines", "Edit", "arrow.right.and.line.vertical.and.arrow.left", "⌘J") { editor.joinLines() }
            add("Select Line", "Edit", "text.line.first.and.arrowtriangle.forward", "⌘L") { editor.selectLine() }
            add("Sort Lines (A → Z)", "Edit", "arrow.up.arrow.down") { editor.sortLines() }
            add("Sort Lines (Z → A)", "Edit", "arrow.up.arrow.down") { editor.sortLines(descending: true) }
            add("Sort Lines & Remove Duplicates", "Edit", "line.3.horizontal.decrease") { editor.sortLines(unique: true) }
            add("Trim Trailing Whitespace", "Edit", "scissors") {
                if !editor.trimTrailingWhitespace() { self.toast("No trailing whitespace", symbol: "checkmark.circle") }
            }
            add("UPPERCASE", "Text", "textformat.size.larger") { editor.transformSelection("Uppercase") { $0.uppercased() } }
            add("lowercase", "Text", "textformat.size.smaller") { editor.transformSelection("Lowercase") { $0.lowercased() } }
            add("Title Case", "Text", "textformat") { editor.transformSelection("Title Case") { $0.capitalized } }
            add("camelCase", "Text", "textformat.abc") { editor.transformSelection("camelCase") { TextCase.camel($0) } }
            add("snake_case", "Text", "textformat.abc") { editor.transformSelection("snake_case") { TextCase.snake($0) } }
            add("kebab-case", "Text", "textformat.abc") { editor.transformSelection("kebab-case") { TextCase.kebab($0) } }
            add("Base64 Encode", "Text", "lock") { editor.transformSelection("Base64 Encode") { Data($0.utf8).base64EncodedString() } }
            add("Base64 Decode", "Text", "lock.open") {
                editor.transformSelection("Base64 Decode") { text in
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let data = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters), let decoded = String(data: data, encoding: .utf8) else { return text }
                    return decoded
                }
            }
            add("URL Encode", "Text", "link") { editor.transformSelection("URL Encode") { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? $0 } }
            add("URL Decode", "Text", "link") { editor.transformSelection("URL Decode") { $0.removingPercentEncoding ?? $0 } }
            add("Insert UUID", "Text", "number.square") {
                editor.textView.insertText(UUID().uuidString.lowercased(), replacementRange: editor.textView.selectedRange())
            }
            add("Insert Date & Time", "Text", "calendar") {
                editor.textView.insertText(Date.now.formatted(.iso8601), replacementRange: editor.textView.selectedRange())
            }
            add("Format JSON", "JSON", "curlybraces.square") { self.runJSON(editor, minify: false) }
            add("Minify JSON", "JSON", "curlybraces") { self.runJSON(editor, minify: true) }
        }

        // View
        if let document {
            if document.isMarkdown {
                add("Show Editor Only", "Markdown", MarkdownMode.editor.symbol, "⌥⌘1") { self.setMarkdownMode(.editor) }
                add("Show Editor & Preview", "Markdown", MarkdownMode.split.symbol, "⌥⌘2") { self.setMarkdownMode(.split) }
                add("Show Preview Only", "Markdown", MarkdownMode.preview.symbol, "⌥⌘3") { self.setMarkdownMode(.preview) }
                add("Export Preview as HTML…", "Markdown", "square.and.arrow.up") { document.preview.exportHTML() }
            }
            let wraps = document.wrapLines ?? settings.wrapLines
            add(wraps ? "Disable Word Wrap" : "Enable Word Wrap", "View", "text.word.spacing", "⌥⌘W") { document.wrapLines = !wraps }
            add("Change Language…", "View", "chevron.left.forwardslash.chevron.right") { self.showPalette(.language) }
            add("Indent Using Spaces (2)", "Indentation", "space") { document.indentation = Indentation(usesTabs: false, width: 2) }
            add("Indent Using Spaces (4)", "Indentation", "space") { document.indentation = Indentation(usesTabs: false, width: 4) }
            add("Indent Using Tabs", "Indentation", "arrow.right.to.line.compact") { document.indentation = Indentation(usesTabs: true, width: document.indentation.width) }
            add("Convert Indentation to Spaces", "Indentation", "arrow.triangle.swap") { self.convertIndentation(document, toTabs: false) }
            add("Convert Indentation to Tabs", "Indentation", "arrow.triangle.swap") { self.convertIndentation(document, toTabs: true) }
            for ending in LineEnding.allCases where ending != document.lineEnding {
                add("Line Endings: \(ending.description)", "File", "return") {
                    document.lineEnding = ending
                    document.isDirty = true
                    document.loadedEditor?.markDirtyWithoutUndo()
                }
            }
            if hasFile {
                add("Reopen with Encoding…", "File", "character.textbox") { self.showPalette(.commands, seed: "Reopen as ") }
                for encoding in TextFileCodec.commonEncodings where encoding != document.encoding {
                    add("Reopen as \(TextFileCodec.name(of: encoding))", "Encoding", "character.textbox") { self.reopen(document, encoding: encoding) }
                }
            }
            if document.encoding != .utf8 || document.hasBOM {
                add("Save with Encoding: UTF-8", "Encoding", "character.textbox") {
                    document.encoding = .utf8
                    document.hasBOM = false
                    Task { await self.save(document) }
                }
            }
        }
        add(settings.showLineNumbers ? "Hide Line Numbers" : "Show Line Numbers", "View", "list.number") { self.settings.showLineNumbers.toggle() }
        add(settings.showInvisibles ? "Hide Invisible Characters" : "Show Invisible Characters", "View", "paragraphsign") { self.settings.showInvisibles.toggle() }
        add(settings.highlightCurrentLine ? "Don’t Highlight Current Line" : "Highlight Current Line", "View", "highlighter") { self.settings.highlightCurrentLine.toggle() }
        add("Zoom In", "View", "plus.magnifyingglass", "⌘+") { self.settings.zoom(by: 1) }
        add("Zoom Out", "View", "minus.magnifyingglass", "⌘−") { self.settings.zoom(by: -1) }
        add("Actual Size", "View", "1.magnifyingglass", "⌘0") { self.settings.resetZoom() }
        add("Change Theme…", "View", "paintpalette") { self.showPalette(.theme) }
        add("Appearance: Match System", "View", "circle.lefthalf.filled") { self.settings.appearance = .system }
        add("Appearance: Light", "View", "sun.max") { self.settings.appearance = .light }
        add("Appearance: Dark", "View", "moon") { self.settings.appearance = .dark }
        add("Settings…", "App", "gearshape", "⌘,") { self.openSettings() }
        return list.filter(\.isEnabled)
    }

    private func isPinned(_ document: EditorDocument?) -> Bool {
        guard let path = document?.path else { return false }
        return recents.item(for: path)?.pinned == true
    }

    func runJSON(_ editor: EditorController, minify: Bool) {
        do {
            try editor.reformatJSON(minify: minify)
        } catch {
            toast(error.localizedDescription, symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    func setMarkdownMode(_ mode: MarkdownMode) {
        guard let document = selectedDocument, document.isMarkdown else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            document.markdownMode = mode
        }
        settings.markdownMode = mode
        scheduleSessionSave()
    }

    func cycleMarkdownPreview() {
        guard let document = selectedDocument, document.isMarkdown else { return }
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
