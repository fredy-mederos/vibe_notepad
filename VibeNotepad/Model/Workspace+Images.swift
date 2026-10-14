import AppKit
import SwiftUI

/// Pictures open in tabs of their own, read-only, in the image viewer (see `ImageViewerController`).
extension Workspace {
    /// A tab for the picture at `url`. Whether it can be decoded shows once it's on screen.
    func imageDocument(_ url: URL) -> EditorDocument {
        let document = EditorDocument(fileURL: url, text: "", language: .plainText, isImage: true)
        document.fileModificationDate = FileIO.modificationDate(of: url)
        return document
    }

    /// The selected tab's image viewer, when it shows a picture.
    var selectedImageViewer: ImageViewerController? {
        guard let document = selectedDocument, document.isImage else { return nil }
        return document.imageViewer
    }

    /// Another app changed the picture: show the new one (there's nothing to lose, so no asking).
    func reloadImage(_ document: EditorDocument) {
        guard let url = document.fileURL else { return }
        document.fileModificationDate = FileIO.modificationDate(of: url)
        document.externalChange = nil
        document.loadedImageViewer?.load()
        document.reloadCount += 1
    }

    // MARK: Zoom

    // ⌘+, ⌘− and ⌘0 zoom the picture when one is selected, and the text size otherwise.

    func zoomIn() {
        if let viewer = selectedImageViewer { viewer.zoomIn() } else { settings.zoom(by: 1) }
    }

    func zoomOut() {
        if let viewer = selectedImageViewer { viewer.zoomOut() } else { settings.zoom(by: -1) }
    }

    func resetZoom() {
        if let viewer = selectedImageViewer { viewer.actualSize() } else { settings.resetZoom() }
    }

    func toggleImageInfo() {
        withAnimation(.snappy(duration: 0.25)) { settings.showsImageInfo.toggle() }
    }

    /// Opens the file in the app macOS uses for it (Preview, say).
    func openInDefaultApp(_ document: EditorDocument? = nil) {
        guard let url = (document ?? selectedDocument)?.fileURL else { return }
        NSWorkspace.shared.open(url)
    }
}
