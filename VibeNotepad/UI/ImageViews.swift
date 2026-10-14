import AppKit
import SwiftUI
import VibeCore

/// A picture, with its info panel beside it when that's on (⌘I).
struct ImageDocumentView: View {
    @Environment(AppSettings.self) private var settings
    let document: EditorDocument
    /// See `EditorHost.isInFocusedPane`.
    let isInFocusedPane: Bool

    var body: some View {
        let viewer = document.imageViewer
        HStack(spacing: 0) {
            ZStack {
                ImageHost(document: document, viewer: viewer, isInFocusedPane: isInFocusedPane, takesFocus: true)
                if case .failed(let message) = viewer.state {
                    ImageErrorView(document: document, message: message)
                        .transition(.opacity)
                }
            }
            if settings.showsImageInfo {
                ImageInfoPanel(document: document, viewer: viewer)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
}

/// Embeds an image viewer: a document's picture, or an SVG's preview.
struct ImageHost: NSViewRepresentable {
    let document: EditorDocument
    let viewer: ImageViewerController
    /// See `EditorHost.isInFocusedPane`.
    let isInFocusedPane: Bool
    /// Whether it takes the keyboard when it appears (an SVG's preview does only when it shows alone).
    let takesFocus: Bool

    func makeNSView(context: Context) -> HostingContainerView {
        let container = HostingContainerView()
        container.onAttach = { [weak document, weak viewer, takesFocus] in
            guard let document, let viewer else { return }
            viewer.fitToPane()
            let workspace = Workspace.shared
            if takesFocus, !workspace.findBarVisible, workspace.palette == nil, workspace.selectedDocument === document { viewer.focus() }
        }
        container.host(viewer.scrollView)
        return container
    }

    func updateNSView(_ container: HostingContainerView, context: Context) {
        container.host(viewer.scrollView)
    }

    static func dismantleNSView(_ container: HostingContainerView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Shown instead of a picture macOS can't decode (or a file that can't be read).
private struct ImageErrorView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    let document: EditorDocument
    let message: String

    var body: some View {
        let theme = settings.theme
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.mutedForeground.color)
            Text("Can’t show “\(document.displayName)”")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.foreground.color)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.mutedForeground.color)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Open in Default App") { workspace.openInDefaultApp(document) }
                Button("Reveal in Finder") { workspace.revealInFinder(document) }
            }
            .controlSize(.small)
            .buttonStyle(.glass)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.color)
    }
}

/// What there is to know about a picture: dimensions, resolution, color, frames, camera and file.
struct ImageInfoPanel: View {
    static let width: CGFloat = 264

    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    let document: EditorDocument
    let viewer: ImageViewerController

    var body: some View {
        let theme = settings.theme
        VStack(spacing: 0) {
            header(theme: theme)
            Rectangle().fill(theme.foreground.color.opacity(0.08)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let details = viewer.details {
                        section("Image", theme: theme) { imageRows(details) }
                        if details.camera != nil || details.lens != nil || details.exposure != nil || details.dateTaken != nil {
                            section("Camera", theme: theme) { cameraRows(details) }
                        }
                        section("File", theme: theme) { fileRows(details) }
                    } else if viewer.state == .loading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    }
                    HStack(spacing: 8) {
                        Button("Reveal in Finder") { workspace.revealInFinder(document) }
                        Button(openTitle) { workspace.openInDefaultApp(document) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.glass)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.width)
        .background(theme.chromeBackground.color)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.foreground.color.opacity(0.08)).frame(width: 1)
        }
    }

    private func header(theme: Theme) -> some View {
        HStack(spacing: 9) {
            FileIcon(language: document.language, size: 26, isImage: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(document.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.foreground.color)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let format = viewer.details?.format {
                    Text(format)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.mutedForeground.color)
                }
            }
            Spacer(minLength: 4)
            Button {
                workspace.toggleImageInfo()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.mutedForeground.color)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide Image Info (⌘I)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func imageRows(_ details: ImageDetails) -> some View {
        InfoRow(label: "Dimensions", value: "\(details.dimensions) pixels")
        if let size = viewer.image?.size, Int(size.width.rounded()) != details.pixelWidth || Int(size.height.rounded()) != details.pixelHeight {
            InfoRow(label: "At 100%", value: "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) points")
        }
        if let dpi = details.dpi {
            InfoRow(label: "Resolution", value: "\(dpi.formatted(.number.precision(.fractionLength(0...1)))) dpi")
        }
        if let color = details.colorSummary { InfoRow(label: "Color", value: color) }
        if let profile = details.colorProfile { InfoRow(label: "Profile", value: profile) }
        if details.isAnimated {
            InfoRow(label: "Frames", value: "\(details.frameCount) (animated)")
        } else if details.frameCount > 1 {
            InfoRow(label: "Images", value: "\(details.frameCount) (sizes or pages)")
        }
        if let orientation = details.orientationDescription { InfoRow(label: "Orientation", value: orientation) }
    }

    @ViewBuilder
    private func cameraRows(_ details: ImageDetails) -> some View {
        if let camera = details.camera { InfoRow(label: "Camera", value: camera) }
        if let lens = details.lens { InfoRow(label: "Lens", value: lens) }
        if let exposure = details.exposure { InfoRow(label: "Exposure", value: exposure) }
        if let taken = details.dateTaken { InfoRow(label: "Taken", value: taken) }
    }

    @ViewBuilder
    private func fileRows(_ details: ImageDetails) -> some View {
        if let size = details.fileSize {
            InfoRow(label: "Size", value: "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) (\(size.formatted()) bytes)")
        }
        if let created = details.created { InfoRow(label: "Created", value: created.formatted(date: .abbreviated, time: .shortened)) }
        if let modified = details.modified { InfoRow(label: "Modified", value: modified.formatted(date: .abbreviated, time: .shortened)) }
        if let url = document.fileURL { InfoRow(label: "Where", value: url.abbreviatedParentPath) }
    }

    private func section(_ title: String, theme: Theme, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.mutedForeground.color.opacity(0.8))
            rows()
        }
    }

    /// "Open in Preview", or whichever app opens the file.
    private var openTitle: String {
        guard let url = document.fileURL, let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "Open in Default App" }
        return "Open in \(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))"
    }
}

/// A label and a value that can be selected and copied.
private struct InfoRow: View {
    @Environment(AppSettings.self) private var settings
    let label: String
    let value: String

    var body: some View {
        let theme = settings.theme
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(theme.mutedForeground.color)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .foregroundStyle(theme.foreground.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
    }
}

/// The status bar for a picture: its size, format and file size, then the zoom and background controls.
struct ImageStatusItems: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    let viewer: ImageViewerController

    var body: some View {
        let theme = settings.theme
        if let details = viewer.details {
            Text("\(details.dimensions) px")
            if let format = details.shortFormat { Text(format) }
            if let size = details.fileSize { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
            if details.isAnimated { Text("\(details.frameCount) frames") }
        } else if case .failed = viewer.state {
            Text("Can’t show this image")
        }

        Spacer(minLength: 8)

        if viewer.state == .loaded {
            ImageZoomControls(viewer: viewer)
            if viewer.details?.hasAlpha != false { ImageBackgroundMenu() }
        }

        Button {
            workspace.toggleImageInfo()
        } label: {
            Image(systemName: settings.showsImageInfo ? "info.circle.fill" : "info.circle")
                .foregroundStyle(settings.showsImageInfo ? theme.accent.color : theme.mutedForeground.color)
        }
        .buttonStyle(StatusButtonStyle())
        .help("Image Info (⌘I)")
    }
}

/// Zoom out, the zoom (a menu of zooms), zoom in, and fit / actual size.
struct ImageZoomControls: View {
    let viewer: ImageViewerController

    var body: some View {
        HStack(spacing: 2) {
            Button { viewer.zoomOut() } label: { Image(systemName: "minus") }
                .buttonStyle(StatusButtonStyle())
                .help("Zoom Out (⌘−)")
            Menu {
                Button("Zoom to Fit") { viewer.zoomToFit() }
                Button("Actual Size") { viewer.actualSize() }
                Divider()
                ForEach([0.25, 0.5, 1, 2, 4, 8] as [CGFloat], id: \.self) { zoom in
                    Button("\(Int(zoom * 100))%") { viewer.setZoom(zoom) }
                }
            } label: {
                Text("\(Int((viewer.zoom * 100).rounded()))%")
                    .contentTransition(.numericText())
                    .frame(minWidth: 38)
            }
            .menuStyle(.button)
            .buttonStyle(StatusButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Zoom")
            Button { viewer.zoomIn() } label: { Image(systemName: "plus") }
                .buttonStyle(StatusButtonStyle())
                .help("Zoom In (⌘+)")
            Button {
                if viewer.fitsPane { viewer.actualSize() } else { viewer.zoomToFit() }
            } label: {
                Image(systemName: viewer.fitsPane ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(StatusButtonStyle())
            .help(viewer.fitsPane ? "Fitting the pane: click for Actual Size (⌘0)" : "Zoom to Fit (⌥⌘0)")
        }
    }
}

/// What shows behind transparent pictures: a checkerboard, white, black or nothing.
struct ImageBackgroundMenu: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Menu {
            Picker("Background", selection: $settings.imageBackground) {
                ForEach(ImageBackground.allCases, id: \.self) { background in
                    Label(background.title, systemImage: background.symbol).tag(background)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: settings.imageBackground.symbol)
        }
        .menuStyle(.button)
        .buttonStyle(StatusButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Background for transparent parts: \(settings.imageBackground.title)")
    }
}

/// An SVG's live preview: the picture (zoomable, like an image), its size and zoom controls in a bar
/// over its corner, and what's wrong with the text while it doesn't render.
struct SVGPreviewView: View {
    @Environment(AppSettings.self) private var settings
    let document: EditorDocument
    /// See `EditorHost.isInFocusedPane`.
    let isInFocusedPane: Bool

    var body: some View {
        let theme = settings.theme
        let viewer = document.svgPreview.viewer
        ZStack(alignment: .bottomTrailing) {
            ImageHost(document: document, viewer: viewer, isInFocusedPane: isInFocusedPane, takesFocus: document.markdownMode == .preview)
            if viewer.state == .loaded {
                HStack(spacing: 8) {
                    if let details = viewer.details {
                        Text(details.dimensions)
                            .foregroundStyle(theme.mutedForeground.color)
                            .padding(.leading, 6)
                    }
                    ImageZoomControls(viewer: viewer)
                    ImageBackgroundMenu()
                }
                .font(.system(size: 11).monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
                .padding(12)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let error = viewer.renderError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.foreground.color)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.14))
                .background(theme.background.color)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.orange.opacity(0.25)).frame(height: 1) }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: viewer.renderError)
    }
}
