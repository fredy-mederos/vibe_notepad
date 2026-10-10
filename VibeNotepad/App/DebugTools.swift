#if DEBUG
import AppKit
import QuartzCore

/// Development helpers reachable through `vibenotepad://debug-…` links (Debug builds only).
enum DebugTools {
    /// Toggles the sidebar like ⌘B and, for `seconds`, samples the editor's geometry and times every
    /// main run loop pass. Writes a report to `path`: long passes are dropped frames.
    static func measureSidebarToggle(to path: String, seconds: Double = 1.2) {
        guard let editor = Workspace.shared.activeEditor else { return }
        // Let the link's own event handling (it orders the window) finish first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { measureSidebarToggle(editor: editor, to: path, seconds: seconds) }
    }

    private static func measureSidebarToggle(editor: EditorController, to path: String, seconds: Double) {
        let window = editor.textView.window
        let start = CACurrentMediaTime()
        var samples: [String] = []
        var passes: [(at: Double, ms: Double)] = []
        var passStart = start
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, 0) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting {
                passStart = now
            } else {
                passes.append(((passStart - start) * 1000, (now - passStart) * 1000))
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        var lastLine = ""
        let timer = Timer(timeInterval: 1.0 / 240, repeats: true) { _ in
            let line = String(format: "root %.1f×%.1f text %.1f minimap %d", editor.rootView.frame.width, editor.rootView.frame.height,
                              editor.scrollView.frame.width, editor.rootView.isMinimapVisible ? 1 : 0)
            guard line != lastLine else { return }
            lastLine = line
            samples.append(String(format: "%7.1f ms  ", (CACurrentMediaTime() - start) * 1000) + line)
        }
        RunLoop.main.add(timer, forMode: .common)
        let before = AppSettings.shared.showsSidebar
        NotificationCenter.default.post(name: .toggleSidebarRequest, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            timer.invalidate()
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            let long = passes.filter { $0.ms > 12 }
            var report = "sidebar \(before ? "collapse" : "expand"), app active \(NSApp.isActive), window visible \(window?.occlusionState.contains(.visible) == true)\n"
            report += "file \(Workspace.shared.selectedDocument?.displayName ?? "-"), \(editor.engine.lineCount) lines, wrap \(editor.textContainer.widthTracksTextView)\n"
            report += String(format: "run loop passes %d, busy %.1f ms, longest %.1f ms, over 12 ms: %d\n", passes.count,
                             passes.reduce(0) { $0 + $1.ms }, passes.map(\.ms).max() ?? 0, long.count)
            report += long.map { String(format: "  long pass at %.1f ms: %.1f ms", $0.at, $0.ms) }.joined(separator: "\n") + "\n"
            report += "geometry changes:\n" + samples.joined(separator: "\n") + "\n"
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Selects sidebar row `row` (as clicking it does; nil selects nothing), then writes the number of
    /// rows, the expanded project folders and whether an alert sheet came up to `path`.
    static func selectSidebarRow(_ row: Int?, report path: String) {
        guard let window = Workspace.shared.windowReference, let root = window.contentView?.superview ?? window.contentView,
              let table = firstSubview(of: NSTableView.self, in: root) else {
            try? "no sidebar table\n".write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        if let row, row < table.numberOfRows { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let lines = ["selected row \(row.map(String.init) ?? "-") of \(table.numberOfRows), alert sheet \(window.attachedSheet != nil)",
                         "expanded \(Workspace.shared.project?.expandedFolders.map { ($0 as NSString).lastPathComponent }.sorted() ?? [])",
                         "document \(Workspace.shared.selectedDocument?.displayName ?? "-")"]
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Does what choosing `folder` in "Open Enclosing Folder…" for `file` does, then writes the project,
    /// its expanded folders, the open tabs and the sidebar's rows and scroll position to `path`.
    static func openEnclosingFolder(_ folder: String, revealing file: String, report path: String) {
        Workspace.shared.openProject(URL(fileURLWithPath: folder), revealing: URL(fileURLWithPath: file))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let workspace = Workspace.shared
            var lines = ["project \(workspace.project?.root.path ?? "-")",
                         "expanded \(workspace.project?.expandedFolders.sorted() ?? [])",
                         "tabs \(workspace.documents.count), selected \(workspace.selectedDocument?.displayName ?? "-")"]
            if let root = workspace.windowReference?.contentView?.superview, let table = firstSubview(of: NSTableView.self, in: root) {
                let visible = table.rows(in: table.visibleRect)
                lines.append("rows \(table.numberOfRows), selected row \(table.selectedRow), visible \(visible.location)..<\(visible.location + visible.length), offset \(Int(table.visibleRect.minY))")
            }
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    /// Renders the main window into a PNG without activating the app.
    static func snapshot(to path: String, windowTitle: String? = nil) {
        let titled = windowTitle.flatMap { title in NSApp.windows.first { $0.title.localizedCaseInsensitiveContains(title) } }
        guard let window = titled ?? Workspace.shared.windowReference ?? NSApp.windows.first(where: { $0.isVisible }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("[debug] snapshot: no window")
            return
        }
        let renderStart = Date()
        // A window that was never on screen (Stage Manager's strip) may not be laid out yet.
        window.layoutIfNeeded()
        view.cacheDisplay(in: view.bounds, to: rep)
        NSLog("[debug] render took %.1f ms", Date().timeIntervalSince(renderStart) * 1000)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSLog("[debug] snapshot written to %@", path)
        } catch {
            NSLog("[debug] snapshot failed: %@", error.localizedDescription)
        }
        // Web content renders out of process, so capture the preview separately.
        if let preview = Workspace.shared.selectedDocument?.loadedPreview, preview.webView.window != nil {
            let previewPath = (path as NSString).deletingPathExtension + "-preview.png"
            preview.webView.takeSnapshot(with: nil) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let data = bitmap.representation(using: .png, properties: [:]) else {
                    NSLog("[debug] preview snapshot failed: %@", String(describing: error))
                    return
                }
                try? data.write(to: URL(fileURLWithPath: previewPath))
                NSLog("[debug] preview snapshot written to %@", previewPath)
            }
        }
    }
}
#endif
