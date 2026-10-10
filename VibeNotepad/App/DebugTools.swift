#if DEBUG
import AppKit

/// Development helpers reachable through `vibenotepad://debug-…` links (Debug builds only).
enum DebugTools {
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
