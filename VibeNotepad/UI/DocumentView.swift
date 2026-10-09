import AppKit
import SwiftUI
import VibeCore

/// The editor and/or Markdown preview for one document.
struct DocumentView: View {
    @Environment(Workspace.self) private var workspace
    @Bindable var document: EditorDocument
    @State private var splitFraction: CGFloat = 0.5

    var body: some View {
        VStack(spacing: 0) {
            if let change = document.externalChange {
                ExternalChangeBanner(document: document, change: change)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            GeometryReader { geometry in
                let mode = document.isMarkdown ? document.markdownMode : .editor
                HStack(spacing: 0) {
                    if mode != .preview {
                        EditorHost(document: document)
                            .frame(width: mode == .split ? max(220, geometry.size.width * splitFraction) : geometry.size.width)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    if mode == .split {
                        SplitDivider(fraction: $splitFraction, totalWidth: geometry.size.width)
                            .transition(.opacity)
                    }
                    if mode != .editor {
                        PreviewHost(document: document)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .coordinateSpace(.named("split"))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: document.externalChange)
        .modifier(DocumentProxy(url: document.fileURL))
    }
}

/// Embeds the document's AppKit editor.
struct EditorHost: NSViewRepresentable {
    let document: EditorDocument

    func makeNSView(context: Context) -> HostingContainerView {
        let container = HostingContainerView()
        container.onAttach = { [weak document] in
            guard let document else { return }
            document.editorDidAttach()
            if !Workspace.shared.findBarVisible, Workspace.shared.palette == nil, Workspace.shared.selectedDocument === document {
                document.loadedEditor?.focus()
            }
        }
        container.host(document.editor.rootView)
        return container
    }

    func updateNSView(_ container: HostingContainerView, context: Context) {
        container.host(document.editor.rootView)
    }

    static func dismantleNSView(_ container: HostingContainerView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Embeds the document's Markdown preview.
struct PreviewHost: NSViewRepresentable {
    let document: EditorDocument

    func makeNSView(context: Context) -> HostingContainerView {
        let container = HostingContainerView()
        container.onAttach = { [weak document] in
            document?.loadedPreview?.syncScroll(force: true)
        }
        container.host(document.preview.webView)
        return container
    }

    func updateNSView(_ container: HostingContainerView, context: Context) {
        container.host(document.preview.webView)
    }

    static func dismantleNSView(_ container: HostingContainerView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Draggable divider between editor and preview.
struct SplitDivider: View {
    @Environment(AppSettings.self) private var settings
    @Binding var fraction: CGFloat
    let totalWidth: CGFloat
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        let theme = settings.theme
        ZStack {
            Rectangle()
                .fill(theme.foreground.color.opacity(isHovering || isDragging ? 0.22 : 0.09))
                .frame(width: isHovering || isDragging ? 2 : 1)
            Capsule()
                .fill(theme.foreground.color.opacity(isHovering || isDragging ? 0.35 : 0))
                .frame(width: 4, height: 34)
        }
        .frame(width: 9)
        .contentShape(Rectangle())
        .pointerStyle(.columnResize)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("split"))
                .onChanged { value in
                    isDragging = true
                    guard totalWidth > 0 else { return }
                    fraction = min(0.82, max(0.18, value.location.x / totalWidth))
                }
                .onEnded { _ in isDragging = false }
        )
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { fraction = 0.5 }
        }
    }
}

/// Offers to reload or keep local edits when the file changed underneath us.
struct ExternalChangeBanner: View {
    @Environment(Workspace.self) private var workspace
    let document: EditorDocument
    let change: EditorDocument.ExternalChange

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: change == .deleted ? "trash.slash.fill" : "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeat(2))
            Text(change == .deleted ? "This file was moved or deleted on disk." : "This file changed on disk while you have unsaved edits.")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            if change == .modified {
                Button("Reload from Disk") { workspace.reloadFromDisk(document) }
                Button("Keep My Version") { workspace.keepLocalVersion(document) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Save Here Again") { Task { await workspace.save(document) } }
                Button("Dismiss") { document.externalChange = nil }
            }
        }
        .controlSize(.small)
        .buttonStyle(.glass)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.orange.opacity(0.25)).frame(height: 1) }
    }
}
