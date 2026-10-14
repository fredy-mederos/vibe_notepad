#if DEBUG
import AppKit
import QuartzCore
import VibeCore

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
                         "expanded \(Workspace.shared.projects.flatMap(\.expandedFolders).map { ($0 as NSString).lastPathComponent }.sorted())",
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
            var lines = ["projects \(workspace.projects.map { $0.root.path + ($0.isCollapsed ? " (collapsed)" : "") })",
                         "expanded \(workspace.projects.flatMap(\.expandedFolders).sorted())",
                         "tabs \(workspace.documents.count), selected \(workspace.selectedDocument?.displayName ?? "-")"]
            if let root = workspace.windowReference?.contentView?.superview, let table = firstSubview(of: NSTableView.self, in: root) {
                let visible = table.rows(in: table.visibleRect)
                lines.append("rows \(table.numberOfRows), selected row \(table.selectedRow), visible \(visible.location)..<\(visible.location + visible.length), offset \(Int(table.visibleRect.minY))")
            }
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Times every main run loop pass for `seconds` and writes a summary to `path` (long passes are
    /// dropped frames), for measuring something done meanwhile, like dragging a pane divider.
    static func measureRunLoop(seconds: Double, to path: String) {
        let start = CACurrentMediaTime()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            let long = passes.filter { $0.ms > 16 }
            var report = String(format: "run loop passes %d, busy %.1f ms, longest %.1f ms, over 16 ms: %d\n", passes.count,
                                passes.reduce(0) { $0 + $1.ms }, passes.map(\.ms).max() ?? 0, long.count)
            report += long.map { String(format: "  long pass at %.0f ms: %.1f ms", $0.at, $0.ms) }.joined(separator: "\n") + "\n"
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Drives the panes, then writes how they're laid out to `path`. Ops: split (value h or v, of pane
    /// index `pane`), layout (a preset name), focus (left, right, up, down, next), close (pane index),
    /// click (value "x,y" as fractions of the window, through the click monitor), drop (value
    /// "tab,zone": a tab name dropped on pane index `pane`), report.
    static func panes(_ op: String, value: String?, pane index: Int?, report path: String) {
        let workspace = Workspace.shared
        let panes = workspace.paneLayout.paneIDs
        let pane = index.flatMap { $0 < panes.count ? panes[$0] : nil }
        switch op {
        case "split":
            workspace.splitPane(value == "v" ? .vertical : .horizontal, pane: pane)
        case "layout":
            if let preset = PaneLayout.Preset(rawValue: value ?? "") { workspace.applyLayout(preset) }
        case "focus":
            switch value {
            case "left": workspace.focusPane(toward: .left)
            case "right": workspace.focusPane(toward: .right)
            case "up": workspace.focusPane(toward: .up)
            case "down": workspace.focusPane(toward: .down)
            default: workspace.focusNextPane()
            }
        case "close":
            workspace.closePane(pane)
        case "click":
            let parts = (value ?? "").split(separator: ",").compactMap { Double($0) }
            if parts.count == 2, let window = workspace.windowReference, let content = window.contentView {
                let point = NSPoint(x: content.bounds.width * parts[0], y: content.bounds.height * (1 - parts[1]))
                let location = content.convert(point, to: nil)
                if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    workspace.paneClicked(event)
                }
            }
        case "drop":
            let parts = (value ?? "").split(separator: ",").map(String.init)
            let zones: [String: PaneDropZone] = ["center": .center, "left": .left, "right": .right, "top": .top, "bottom": .bottom]
            if parts.count == 2, let pane, let zone = zones[parts[1]], let document = workspace.documents.first(where: { $0.displayName == parts[0] }) {
                workspace.dropTab(document.id, on: pane, zone: zone)
            }
        default:
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let workspace = Workspace.shared
            let window = workspace.windowReference
            let responder = (window?.firstResponder as? CodeTextView)?.controller?.document.displayName ?? String(describing: window?.firstResponder.map { type(of: $0) })
            var lines = ["layout \(describe(workspace.paneLayout))",
                         "focused \(workspace.paneLayout.paneIDs.firstIndex(of: workspace.focusedPaneID).map(String.init) ?? "?"), selected \(workspace.selectedDocument?.displayName ?? "-"), first responder \(responder)"]
            for (index, id) in workspace.paneLayout.paneIDs.enumerated() {
                let frame = workspace.paneFrames[id].map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "-"
                let hosted = workspace.document(inPane: id)?.loadedEditor.map { editor -> String in
                    if editor.rootView.window != nil { return "on screen" }
                    guard let container = editor.rootView.superview else { return "not hosted" }
                    return "in a container \(container.window == nil ? "off screen" : "on screen?") (superview \(container.superview == nil ? "none" : "yes"))"
                } ?? "-"
                lines.append("pane \(index): \(workspace.document(inPane: id)?.displayName ?? "(empty)") at \(frame), editor \(hosted)")
            }
            lines.append("tabs \(workspace.documents.map(\.displayName).joined(separator: " "))")
            lines.append("drop target \(workspace.paneDropTarget.map { "P\(workspace.paneLayout.paneIDs.firstIndex(of: $0.pane) ?? -1) \($0.zone)" } ?? "-")")
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func describe(_ layout: PaneLayout) -> String {
        switch layout {
        case .pane(let id):
            return Workspace.shared.paneLayout.paneIDs.firstIndex(of: id).map { "P\($0)" } ?? "P?"
        case .split(_, let axis, let ratio, let first, let second):
            return "\(axis == .horizontal ? "H" : "V")(\(String(format: "%.2f", ratio)) \(describe(first)) \(describe(second)))"
        }
    }

    private static func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    /// Drives the selected picture's viewer (`in`, `out`, `actual`, `fit`, `zoom` to `value`, `info`,
    /// `copy`, `focus`, `scroll` by `value` "dx,dy" points, `layers` to render what the window shows to `path`.png) and
    /// writes what it shows to `path`.
    static func image(_ op: String, value: String?, report path: String) {
        let workspace = Workspace.shared
        guard let viewer = workspace.pictureViewer else {
            try? "no image selected (\(workspace.selectedDocument?.displayName ?? "-"))\n".write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        switch op {
        case "in": viewer.zoomIn()
        case "out": viewer.zoomOut()
        case "actual": viewer.actualSize()
        case "fit": viewer.zoomToFit()
        case "zoom": if let zoom = value.flatMap(Double.init) { viewer.setZoom(CGFloat(zoom)) }
        case "info": workspace.toggleImageInfo()
        case "copy": viewer.copyImage()
        case "background": if let background = value.flatMap(ImageBackground.init(rawValue:)) { workspace.settings.imageBackground = background }
        case "focus": viewer.focus()
        case "layers":
            // Renders the viewer's layer tree (what the window shows, unlike a snapshot, which draws).
            let view = viewer.scrollView
            if let layer = view.layer, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
                                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
               let context = NSGraphicsContext(bitmapImageRep: rep) {
                // A flipped layer's y axis goes down; the bitmap's goes up.
                if layer.isGeometryFlipped {
                    context.cgContext.translateBy(x: 0, y: view.bounds.height)
                    context.cgContext.scaleBy(x: 1, y: -1)
                }
                layer.render(in: context.cgContext)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".png"))
            }
        case "scroll":
            let parts = (value ?? "").split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                let clip = viewer.scrollView.contentView
                var bounds = clip.bounds
                bounds.origin.x += parts[0]
                bounds.origin.y += parts[1]
                clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
                viewer.scrollView.reflectScrolledClipView(clip)
            }
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let window = workspace.windowReference
            let clip = viewer.scrollView.contentView
            let responder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-"
            var lines = ["state \(viewer.state), vector \(viewer.isVector), error \(viewer.renderError ?? "-"), background \(workspace.settings.imageBackground.rawValue), zoom \(String(format: "%.4f", viewer.zoom)), fits \(viewer.fitsPane), magnification \(String(format: "%.4f", viewer.scrollView.magnification))",
                         "scroll view \(NSStringFromRect(viewer.scrollView.frame)) in window \(viewer.scrollView.window != nil), clip bounds \(NSStringFromRect(clip.bounds)), canvas \(NSStringFromRect(viewer.canvas.frame))",
                         "image size \(viewer.image.map { NSStringFromSize($0.size) } ?? "-"), first responder \(responder), info panel \(workspace.settings.showsImageInfo)",
                         "pasteboard \(NSPasteboard.general.types?.map(\.rawValue).joined(separator: " ") ?? "-")"]
            if let details = viewer.details {
                lines.append("details \(details.dimensions) \(details.format ?? "-") (\(details.shortFormat ?? "-")), \(details.fileSize ?? 0) bytes, dpi \(details.dpi.map { String($0) } ?? "-"), color \(details.colorSummary ?? "-"), profile \(details.colorProfile ?? "-"), frames \(details.frameCount), orientation \(details.orientation), camera \(details.camera ?? "-"), exposure \(details.exposure ?? "-"), taken \(details.dateTaken ?? "-")")
            }
            lines.append("tabs \(workspace.documents.map { "\($0.displayName)\($0.isImage ? "[image]" : "")" }.joined(separator: " ")), selected \(workspace.selectedDocument?.displayName ?? "-")")
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
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
