import AppKit
import Foundation

/// A request to open a file, optionally at a position.
struct OpenRequest: Equatable {
    var url: URL
    var line: Int?
    var column: Int?
}

/// Turns command-line arguments, `vibeNotePad://` links and `path:line:column` strings into open requests.
///
/// Supported links (the scheme is case-insensitive):
/// - `vibeNotePad://open?path=/abs/file.md&line=42&column=7` (`file=` and `url=` also accepted)
/// - `vibeNotePad://open/abs/file.md?line=42`
/// - `vibeNotePad://new?text=Hello&language=markdown`
enum LaunchRouter {
    /// Parses `file`, `file:12` or `file:12:5`, resolving relative paths against `directory`.
    static func request(for argument: String, relativeTo directory: String = FileManager.default.currentDirectoryPath) -> OpenRequest {
        var path = (argument as NSString).expandingTildeInPath
        var line: Int?
        var column: Int?
        if !FileManager.default.fileExists(atPath: absolute(path, directory)) {
            let parts = path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 3, let l = Int(parts[parts.count - 2]), let c = Int(parts[parts.count - 1]) {
                path = parts.dropLast(2).joined(separator: ":")
                line = l
                column = c
            } else if parts.count >= 2, let l = Int(parts[parts.count - 1]) {
                path = parts.dropLast().joined(separator: ":")
                line = l
            }
        }
        return OpenRequest(url: URL(fileURLWithPath: absolute(path, directory)).standardizedFileURL, line: line, column: column)
    }

    private static func absolute(_ path: String, _ directory: String) -> String {
        path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
    }

    /// File arguments passed when the executable is launched directly.
    static func requests(fromArguments arguments: [String]) -> [OpenRequest] {
        var result: [OpenRequest] = []
        var skipNext = false
        for argument in arguments.dropFirst() {
            if skipNext { skipNext = false; continue }
            // AppKit/Xcode pass `-NSSomething YES` style pairs.
            if argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") || argument.hasPrefix("-com.apple") { skipNext = true; continue }
            if argument.hasPrefix("-") { continue }
            if let url = URL(string: argument), isAppLink(url) {
                continue // handled through the URL event
            }
            result.append(request(for: argument))
        }
        return result
    }

    static let scheme = "vibenotepad"

    static func isAppLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// Handles a `vibeNotePad://` URL.
    static func handle(_ url: URL) {
        let workspace = Workspace.shared
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let action = (url.host ?? "open").lowercased()

        switch action {
        #if DEBUG
        case "debug-snapshot":
            DebugTools.snapshot(to: value("path") ?? "/tmp/vibe-snapshot.png", windowTitle: value("window"))
        case "debug-settings":
            Workspace.shared.openSettingsAction?()
        case "debug-open":
            if let path = value("path") {
                let start = Date()
                Workspace.shared.open(url: URL(fileURLWithPath: path))
                NSLog("[debug] open took %.1f ms", Date().timeIntervalSince(start) * 1000)
            }
        case "debug-mode":
            if let mode = value("mode").flatMap(MarkdownMode.init(rawValue:)) { Workspace.shared.setMarkdownMode(mode) }
        case "debug-palette":
            Workspace.shared.showPalette(.files, seed: value("q") ?? "")
        case "debug-find":
            Workspace.shared.findQuery = value("q") ?? ""
            Workspace.shared.showFindBar(replace: value("replace") != nil)
        case "debug-theme":
            if let id = value("id"), let theme = Themes.theme(id: id) { AppSettings.shared.select(theme: theme) }
        case "debug-type":
            if let editor = Workspace.shared.activeEditor {
                if let location = value("at").flatMap(Int.init) { editor.textView.setSelectedRange(NSRange(location: location, length: 0)) }
                for character in value("text") ?? "" {
                    if character == "\n" { editor.textView.insertNewline(nil) } else { editor.textView.insertText(String(character), replacementRange: editor.textView.selectedRange()) }
                }
            }
        case "debug-undo":
            Workspace.shared.activeEditor?.undoManager.undo()
        case "debug-save":
            Workspace.shared.saveSelected()
        case "debug-state":
            for document in Workspace.shared.documents {
                NSLog("[debug] doc %@ dirty=%d selected=%d mode=%@ chars=%d line=%d col=%d", document.displayName, document.isDirty ? 1 : 0, document.id == Workspace.shared.selectedID ? 1 : 0, document.markdownMode.rawValue, document.characterCount, document.cursor.line, document.cursor.column)
            }
        case "debug-close-all":
            for document in Workspace.shared.documents { document.isDirty = false; Workspace.shared.close(document) }
        #endif
        case "new":
            let language = value("language").flatMap { LanguageRegistryBridge.language(named: $0) } ?? .plainText
            workspace.newDocument(text: value("text") ?? "", language: language)
        default:
            var path = value("path") ?? value("file") ?? value("url")
            if path == nil, !url.path.isEmpty, url.path != "/" { path = url.path }
            guard var raw = path else {
                workspace.toast("The link didn’t include a file path", symbol: "link.badge.plus", tint: .orange)
                return
            }
            if raw.hasPrefix("file://"), let fileURL = URL(string: raw) { raw = fileURL.path }
            var request = request(for: raw, relativeTo: NSHomeDirectory())
            if let line = value("line").flatMap(Int.init) { request.line = line }
            if let column = value("column").flatMap(Int.init) ?? value("col").flatMap(Int.init) { request.column = column }
            open(request)
        }
    }

    static func open(_ request: OpenRequest) {
        let workspace = Workspace.shared
        if !FileManager.default.fileExists(atPath: request.url.path) {
            workspace.toast("“\(request.url.lastPathComponent)” doesn’t exist", symbol: "questionmark.folder", tint: .orange)
            return
        }
        guard let document = workspace.open(url: request.url) else { return }
        if let line = request.line {
            document.navigate(toLine: line, column: request.column)
        }
    }
}

import VibeCore

/// Small helper so URL handling can map names like "md" or "Markdown" to languages.
enum LanguageRegistryBridge {
    static func language(named name: String) -> LanguageID? {
        if let id = LanguageID(rawValue: name.lowercased()) { return id }
        if let id = LanguageRegistry.language(forFenceInfo: name) { return id }
        return LanguageRegistry.all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
    }
}
