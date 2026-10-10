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

    #if DEBUG
    static let scheme = "vibenotepad-dev"
    #else
    static let scheme = "vibenotepad"
    #endif

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
            if let tab = value("tab") { UserDefaults.standard.set(tab, forKey: "settingsTab") }
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
            if value("hide") != nil {
                Workspace.shared.hidePalette(refocus: false)
            } else {
                Workspace.shared.showPalette(.files, seed: value("q") ?? "")
            }
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
        case "debug-key":
            // Runs a text view command (deleteForward, moveRight…) and logs the result.
            guard let editor = Workspace.shared.activeEditor else { break }
            if let location = value("at").flatMap(Int.init) { editor.textView.setSelectedRange(NSRange(location: location, length: 0)) }
            let op = value("op") ?? "moveRight"
            for _ in 0..<(value("count").flatMap(Int.init) ?? 1) { editor.textView.doCommand(by: NSSelectorFromString(op + ":")) }
            NSLog("[debug] key %@ → selection %@, folds %d, length %d", op, NSStringFromRange(editor.textView.selectedRange()),
                  editor.layoutManager.foldSpans.count, editor.textStorage.length)
        case "debug-click":
            // Clicks the fold pill (or its closing preview) on a line.
            guard let editor = Workspace.shared.activeEditor, let window = editor.textView.window,
                  let line = value("line").flatMap(Int.init),
                  let span = editor.layoutManager.span(endingLineAt: editor.engine.lineContentEnd(line - 1)),
                  let hit = editor.layoutManager.foldHitRect(for: span) else { NSLog("[debug] click: no fold"); break }
            let x = value("target") == "preview" ? hit.maxX - 4 : hit.minX + 6
            let origin = editor.textView.textContainerOrigin
            let point = editor.textView.convert(NSPoint(x: x + origin.x, y: hit.midY + origin.y), to: nil)
            if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                editor.textView.mouseDown(with: event)
            }
            NSLog("[debug] click line %d → folds %d", line, editor.layoutManager.foldSpans.count)
        case "debug-task":
            // Clicks the nth task checkbox in the preview, like a reader would.
            guard let preview = Workspace.shared.selectedDocument?.loadedPreview else { break }
            let index = value("index").flatMap(Int.init) ?? 0
            preview.webView.callAsyncJavaScript("document.querySelectorAll('.task-list-item-checkbox')[index]?.click()",
                                                arguments: ["index": index], in: nil, in: .defaultClient, completionHandler: nil)
        case "debug-check":
            Workspace.shared.checkExternalChanges()
            if let editor = Workspace.shared.activeEditor {
                NSLog("[debug] check → length %d, selection %@, at end %d", editor.textStorage.length,
                      NSStringFromRange(editor.textView.selectedRange()), editor.isScrolledToEnd ? 1 : 0)
            }
        case "debug-shortcut":
            // Sends a ⌘-key equivalent through the main menu, like pressing it.
            let key = value("key") ?? "t"
            var flags: NSEvent.ModifierFlags = [.command]
            if value("shift") != nil { flags.insert(.shift) }
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                            windowNumber: Workspace.shared.windowReference?.windowNumber ?? 0, context: nil,
                                            characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) {
                let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    NSLog("[debug] shortcut ⌘%@ handled=%d tabs=%@", key, handled ? 1 : 0,
                          Workspace.shared.documents.map(\.displayName).joined(separator: ", "))
                }
            }
        case "debug-fold":
            guard let editor = Workspace.shared.activeEditor else { break }
            let start = Date()
            let op = value("op") ?? "toggle"
            switch op {
            case "all": editor.foldAll(level: value("level").flatMap(Int.init))
            case "none": editor.unfoldAll()
            case "stress":
                let line = (value("line").flatMap(Int.init) ?? 2) - 1
                for _ in 0..<(value("count").flatMap(Int.init) ?? 60) {
                    editor.toggleFold(atLine: line)
                    editor.textView.displayIfNeeded()
                }
            case "random":
                // Random fold, unfold and scroll operations; logs the slowest ones.
                var generator = SystemRandomNumberGenerator()
                var timings: [(Double, String)] = []
                let clip = editor.scrollView.contentView
                for _ in 0..<(value("count").flatMap(Int.init) ?? 100) {
                    let opStart = Date()
                    let name: String
                    switch Int.random(in: 0..<10, using: &generator) {
                    case 0:
                        let before = editor.layoutManager.foldSpans.count
                        let top = editor.visibleLines().lowerBound
                        editor.foldAll()
                        name = "fold all (spans \(before) → \(editor.layoutManager.foldSpans.count), top line \(top + 1))"
                    case 1:
                        let before = editor.layoutManager.foldSpans.count
                        editor.unfoldAll()
                        name = "unfold all (spans \(before))"
                    case 2:
                        let level = Int.random(in: 1...3, using: &generator)
                        let before = editor.layoutManager.foldSpans.count
                        let top = editor.visibleLines().lowerBound
                        editor.foldAll(level: level)
                        name = "fold level \(level) (spans \(before) → \(editor.layoutManager.foldSpans.count), top line \(top + 1))"
                    case 3, 4:
                        let y = Double.random(in: 0...1, using: &generator) * max(0, editor.textView.frame.height - clip.bounds.height)
                        clip.scroll(to: NSPoint(x: 0, y: y))
                        editor.scrollView.reflectScrolledClipView(clip)
                        name = "scroll"
                    default:
                        // Toggle a foldable line on screen (or anywhere).
                        let lines = editor.visibleLines()
                        var line = Int.random(in: lines.lowerBound..<max(lines.lowerBound + 1, lines.upperBound), using: &generator)
                        if Bool.random(using: &generator) { line = Int.random(in: 0..<editor.engine.lineCount, using: &generator) }
                        if let region = editor.foldRegions.last(where: { editor.engine.lineIndex(containing: $0.hiddenStart) <= line }) {
                            line = editor.engine.lineIndex(containing: region.hiddenStart)
                        }
                        editor.toggleFold(atLine: line)
                        name = "toggle \(line + 1)"
                    }
                    editor.textView.displayIfNeeded()
                    editor.gutter.displayIfNeeded()
                    timings.append((Date().timeIntervalSince(opStart) * 1000, name))
                }
                for (ms, name) in timings.sorted(by: { $0.0 > $1.0 }).prefix(6) { NSLog("[debug]   %.1f ms %@", ms, name) }
            default: editor.toggleFold(atLine: (value("line").flatMap(Int.init) ?? 1) - 1)
            }
            editor.textView.displayIfNeeded()
            NSLog("[debug] fold %@ took %.1f ms (height %.0f)", op, Date().timeIntervalSince(start) * 1000, editor.textView.frame.height)
        case "debug-measure":
            guard let editor = Workspace.shared.activeEditor else { break }
            var start = Date()
            let lines = editor.visibleLines(margin: 80)
            let visibleTime = Date().timeIntervalSince(start) * 1000
            start = Date()
            let used = editor.layoutManager.usedRect(for: editor.textContainer)
            let usedTime = Date().timeIntervalSince(start) * 1000
            NSLog("[debug] visibleLines %d..<%d took %.1f ms; used height %.0f took %.1f ms; frame %.0f; spans %d",
                  lines.lowerBound, lines.upperBound, visibleTime, used.height, usedTime, editor.textView.frame.height,
                  editor.layoutManager.foldSpans.count)
            let layout = editor.layoutManager
            NSLog("[debug] firstUnlaidChar %d of %d, nonContiguous %d", layout.firstUnlaidCharacterIndex(), editor.textStorage.length,
                  layout.hasNonContiguousLayout ? 1 : 0)
            if let span = layout.foldSpans.first {
                var effective = NSRange()
                let glyph = layout.glyphIndexForCharacter(at: span.hidden.location)
                let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective, withoutAdditionalLayout: true)
                NSLog("[debug] span glyph %d fragment %@ effective %@ (glyphs %d)", glyph, NSStringFromRect(rect),
                      NSStringFromRange(effective), layout.numberOfGlyphs)
            }
            let raw = layout.glyphRange(forBoundingRect: editor.textView.visibleRect, in: editor.textContainer)
            NSLog("[debug] visible rect %@ glyphs %@", NSStringFromRect(editor.textView.visibleRect), NSStringFromRange(raw))
        case "debug-scroll":
            // Scrolls to a 0…1 fraction of the document and times the redraw.
            guard let editor = Workspace.shared.activeEditor else { break }
            let start = Date()
            let clip = editor.scrollView.contentView
            let fraction = value("to").flatMap(Double.init) ?? 1
            let target = max(0, (editor.textView.frame.height - clip.bounds.height) * fraction)
            clip.scroll(to: NSPoint(x: 0, y: target))
            editor.scrollView.reflectScrolledClipView(clip)
            editor.textView.displayIfNeeded()
            editor.gutter.displayIfNeeded()
            editor.minimap.displayIfNeeded()
            NSLog("[debug] scroll to %.2f took %.1f ms (y %.0f of %.0f)", fraction, Date().timeIntervalSince(start) * 1000, clip.bounds.minY, editor.textView.frame.height)
        case "debug-minimap":
            // Times minimap and editor redraws at scroll positions through the file; writes them to `path`.
            guard let editor = Workspace.shared.activeEditor else { break }
            let clip = editor.scrollView.contentView
            if let y = value("click").flatMap(Double.init), let window = editor.minimap.window {
                // Clicks the minimap `y` points from its top and reports where the editor scrolled.
                let point = editor.minimap.convert(NSPoint(x: 40, y: y), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        if type == .leftMouseDown { editor.minimap.mouseDown(with: event) } else { editor.minimap.mouseUp(with: event) }
                    }
                }
                let lines = editor.visibleLines()
                let report = "clicked \(y): lines \(lines.lowerBound + 1)-\(lines.upperBound) of \(editor.engine.lineCount)\n"
                try? report.write(toFile: value("path") ?? "/tmp/vibe-minimap.txt", atomically: true, encoding: .utf8)
                break
            }
            var report = "lines \(editor.engine.lineCount), minimap visible \(editor.rootView.isMinimapVisible)\n"
            for step in 0...10 {
                let target = max(0, (editor.textView.frame.height - clip.bounds.height) * Double(step) / 10)
                clip.scroll(to: NSPoint(x: 0, y: target))
                editor.scrollView.reflectScrolledClipView(clip)
                editor.textView.displayIfNeeded()
                var start = Date()
                editor.minimap.display()
                let firstTime = Date().timeIntervalSince(start) * 1000
                start = Date()
                editor.minimap.display()
                let againTime = Date().timeIntervalSince(start) * 1000
                start = Date()
                editor.textView.display()
                let textTime = Date().timeIntervalSince(start) * 1000
                report += String(format: "%.1f: minimap %.2f ms (again %.2f ms), text %.2f ms\n", Double(step) / 10, firstTime, againTime, textTime)
            }
            try? report.write(toFile: value("path") ?? "/tmp/vibe-minimap.txt", atomically: true, encoding: .utf8)
        case "debug-hover":
            // Moves the pointer (as far as the tab reveal can tell) to `y` points from the window's top.
            guard let window = Workspace.shared.windowReference else { break }
            let fromTop = value("y").flatMap(Double.init) ?? 10
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 300, y: window.frame.height - fromTop), modifierFlags: [],
                                              timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                Workspace.shared.pointerMoved(event)
            }
        case "debug-sidebar-select":
            DebugTools.selectSidebarRow(value("row").flatMap(Int.init), report: value("path") ?? "/tmp/vibe-sidebar-rows.txt")
        case "debug-sidebar":
            DebugTools.measureSidebarToggle(to: value("path") ?? "/tmp/vibe-sidebar.txt")
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
        case "debug-updates":
            AppUpdater.shared.debugCheck(repository: value("repository"))
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
        if request.url.isFolder {
            workspace.openProject(request.url)
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
