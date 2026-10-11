import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeCore

/// One part of the editor area: a pane, or a split holding two parts side by side or stacked.
struct PaneNodeView: View {
    let node: PaneLayout

    var body: some View {
        switch node {
        case .pane(let id):
            PaneView(paneID: id)
        case .split(let id, let axis, let ratio, let first, let second):
            PaneSplitView(splitID: id, axis: axis, ratio: ratio, first: first, second: second)
        }
    }
}

/// Two parts of the layout with a thin, draggable divider between them.
struct PaneSplitView: View {
    let splitID: UUID
    let axis: SplitAxis
    let ratio: Double
    let first: PaneLayout
    let second: PaneLayout

    var body: some View {
        GeometryReader { geometry in
            let horizontal = axis == .horizontal
            let total = horizontal ? geometry.size.width : geometry.size.height
            let available = max(0, total - PaneDivider.thickness)
            let firstLength = (available * ratio).rounded()
            let stack = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            stack {
                PaneNodeView(node: first)
                    .frame(width: horizontal ? firstLength : nil, height: horizontal ? nil : firstLength)
                PaneDivider(splitID: splitID, axis: axis, available: available)
                PaneNodeView(node: second)
            }
            .coordinateSpace(.named(splitID))
        }
    }
}

/// The line between two panes: one point wide, with a wider grab area in the editor's background
/// color. Drag it to resize, double-click it to share the room equally.
struct PaneDivider: View {
    static let thickness: CGFloat = 7

    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    let splitID: UUID
    let axis: SplitAxis
    /// The room the two parts share, along the axis.
    let available: CGFloat
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        let theme = settings.theme
        let horizontal = axis == .horizontal
        let active = isHovering || isDragging
        ZStack {
            theme.background.color
            Rectangle()
                .fill(active ? theme.accent.color.opacity(0.75) : theme.foreground.color.opacity(0.12))
                .frame(width: horizontal ? (active ? 2 : 1) : nil, height: horizontal ? nil : (active ? 2 : 1))
        }
        .frame(width: horizontal ? Self.thickness : nil, height: horizontal ? nil : Self.thickness)
        .contentShape(Rectangle())
        .pointerStyle(horizontal ? .columnResize : .rowResize)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(splitID))
                .onChanged { value in
                    isDragging = true
                    guard available > 0 else { return }
                    let position = (horizontal ? value.location.x : value.location.y) - Self.thickness / 2
                    workspace.setPaneRatio(Double(position / available), of: splitID)
                }
                .onEnded { _ in
                    isDragging = false
                    workspace.scheduleSessionSave()
                }
        )
        .onTapGesture(count: 2) { workspace.equalizeSplit(splitID) }
        .accessibilityLabel("Pane divider")
    }
}

/// A pane: its header (when the editor is split and the sidebar shows), then the document, the
/// welcome screen (as the only pane, with nothing open) or a hint. Unfocused panes are dimmed a bit,
/// and tabs can be dropped on a pane or on its sides.
struct PaneView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    let paneID: UUID
    @State private var size: CGSize = .zero

    var body: some View {
        let theme = settings.theme
        let document = workspace.document(inPane: paneID)
        let isFocused = workspace.focusedPaneID == paneID
        let isSplit = workspace.isSplit
        VStack(spacing: 0) {
            if isSplit, settings.showsSidebar {
                PaneHeader(paneID: paneID, document: document, isFocused: isFocused)
            }
            ZStack(alignment: .topTrailing) {
                if let document {
                    DocumentView(document: document, isInFocusedPane: isFocused || !isSplit)
                        .id(document.id)
                        .transition(.opacity)
                } else if isSplit {
                    EmptyPaneView(paneID: paneID)
                } else {
                    WelcomeView()
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
                if isFocused, workspace.findBarVisible, document != nil {
                    FindBarView()
                        .padding(.top, 10)
                        .padding(.trailing, 18)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if isSplit, !isFocused {
                theme.background.color
                    .opacity(settings.showsSidebar ? 0.22 : 0.32)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let target = workspace.paneDropTarget, target.pane == paneID {
                PaneDropHighlight(zone: target.zone)
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            workspace.paneFrames[paneID] = frame
            size = frame.size
        }
        .onDrop(of: [.vibeNotepadTab], delegate: PaneDropDelegate(paneID: paneID, size: size))
    }
}

/// A thin bar naming what a pane shows, with split and close buttons. The focused pane's has an
/// accent line along the top. Drag it onto another pane (or a side of one) to move the document.
struct PaneHeader: View {
    static let height: CGFloat = 26

    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    let paneID: UUID
    let document: EditorDocument?
    let isFocused: Bool
    @State private var isHovering = false

    var body: some View {
        let theme = settings.theme
        HStack(spacing: 6) {
            if let document {
                FileIcon(language: document.language, size: 13)
                Text(document.displayName)
                    .font(.system(size: 11.5, weight: isFocused ? .semibold : .regular))
                    .italic(document.isUntitled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isFocused ? theme.foreground.color : theme.mutedForeground.color)
                if document.isDirty {
                    Circle()
                        .fill(theme.accent.color)
                        .frame(width: 6, height: 6)
                        .transition(.scale.combined(with: .opacity))
                }
            } else {
                Text("Empty pane")
                    .font(.system(size: 11.5))
                    .italic()
                    .foregroundStyle(theme.mutedForeground.color)
            }
            Spacer(minLength: 4)
            if isHovering || isFocused {
                HStack(spacing: 1) {
                    PaneHeaderButton(symbol: "rectangle.split.2x1", help: "Split Right (⌘\\)") {
                        workspace.splitPane(.horizontal, pane: paneID)
                    }
                    .disabled(workspace.paneCount >= Workspace.maxPanes)
                    PaneHeaderButton(symbol: "rectangle.split.1x2", help: "Split Down (⇧⌘\\)") {
                        workspace.splitPane(.vertical, pane: paneID)
                    }
                    .disabled(workspace.paneCount >= Workspace.maxPanes)
                    PaneHeaderButton(symbol: "xmark", help: "Close Pane (⌃⌘W)") {
                        workspace.closePane(paneID)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: Self.height)
        .background(theme.background.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.foreground.color.opacity(0.08)).frame(height: 1)
        }
        .overlay(alignment: .top) {
            if isFocused {
                Rectangle().fill(theme.accent.color).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.15)) { isHovering = hovering }
        }
        .onTapGesture { workspace.focusPane(paneID, focusEditor: true) }
        .modifier(PaneHeaderDrag(document: document))
        .contextMenu { PaneMenu(paneID: paneID) }
        .help(document?.fileURL?.abbreviatedPath ?? document?.displayName ?? "Empty pane")
    }
}

/// Lets a pane's header be dragged like its tab.
private struct PaneHeaderDrag: ViewModifier {
    let document: EditorDocument?

    func body(content: Content) -> some View {
        if let document {
            content.draggable(TabDragItem(id: document.id)) {
                HStack(spacing: 6) {
                    FileIcon(language: document.language, size: 15)
                    Text(document.displayName).font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            content
        }
    }
}

private struct PaneHeaderButton: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.isEnabled) private var isEnabled
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let theme = settings.theme
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.mutedForeground.color.opacity(isEnabled ? 1 : 0.4))
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.foreground.color.opacity(isHovering && isEnabled ? 0.09 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// Split, layout and close actions for a pane (its header's context menu).
struct PaneMenu: View {
    @Environment(Workspace.self) private var workspace
    let paneID: UUID

    var body: some View {
        let canSplit = workspace.paneCount < Workspace.maxPanes
        Button("Split Right", systemImage: "rectangle.split.2x1") { workspace.splitPane(.horizontal, pane: paneID) }
            .disabled(!canSplit)
        Button("Split Down", systemImage: "rectangle.split.1x2") { workspace.splitPane(.vertical, pane: paneID) }
            .disabled(!canSplit)
        Divider()
        if let document = workspace.document(inPane: paneID) {
            Button("Close Tab", systemImage: "xmark") { workspace.close(document) }
        }
        Button("Close Pane", systemImage: "xmark.square") { workspace.closePane(paneID) }
            .disabled(!workspace.isSplit)
        Button("Close Other Panes") {
            workspace.focusPane(paneID)
            workspace.closeOtherPanes()
        }
        .disabled(!workspace.isSplit)
    }
}

/// A pane with nothing in it yet.
struct EmptyPaneView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    let paneID: UUID

    var body: some View {
        let theme = settings.theme
        VStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(theme.mutedForeground.color.opacity(0.7))
            Text("Empty pane")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.foreground.color.opacity(0.85))
            Text("Pick a tab or a file, press ⌘P, or drag a tab here.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.mutedForeground.color)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Quick Open") {
                    workspace.focusPane(paneID)
                    workspace.showPalette(.files)
                }
                Button("Close Pane") { workspace.closePane(paneID) }
            }
            .controlSize(.small)
            .buttonStyle(.glass)
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.color)
    }
}

/// Where a tab dragged over a pane would go: the whole pane tinted, or the half on one side.
private struct PaneDropHighlight: View {
    @Environment(AppSettings.self) private var settings
    let zone: PaneDropZone

    var body: some View {
        let accent = settings.theme.accent.color
        GeometryReader { geometry in
            let size = geometry.size
            let rect: CGRect = switch zone {
            case .center: CGRect(origin: .zero, size: size)
            case .left: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
            case .right: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
            case .top: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
            case .bottom: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
            }
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.13))
                .strokeBorder(accent.opacity(0.65), lineWidth: 2)
                .frame(width: max(0, rect.width - 12), height: max(0, rect.height - 12))
                .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
    }
}

/// Accepts tabs (and pane headers) dragged onto a pane's header or an empty pane (over the text or
/// a preview, those views take the drag; see `Workspace.tabDragMoved`). Near an edge the tab goes into a
/// new pane on that side; elsewhere it shows in this pane.
private struct PaneDropDelegate: DropDelegate {
    let paneID: UUID
    let size: CGSize

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.vibeNotepadTab])
    }

    func dropEntered(info: DropInfo) {
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        let workspace = Workspace.shared
        if workspace.paneDropTarget?.pane == paneID { workspace.setPaneDropTarget(nil) }
    }

    func performDrop(info: DropInfo) -> Bool {
        let workspace = Workspace.shared
        let zone = workspace.dropZone(at: info.location, in: size)
        workspace.setPaneDropTarget(nil)
        guard let provider = info.itemProviders(for: [.vibeNotepadTab]).first else { return false }
        let pane = paneID
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.vibeNotepadTab.identifier) { data, _ in
            guard let data, let item = try? JSONDecoder().decode(TabDragItem.self, from: data) else { return }
            Task { @MainActor in Workspace.shared.dropTab(item.id, on: pane, zone: zone) }
        }
        return true
    }

    private func update(_ info: DropInfo) {
        let workspace = Workspace.shared
        // A late report about the drag that just ended.
        if let drop = workspace.lastTabDrop, Date().timeIntervalSince(drop) < 0.5 { return }
        workspace.setPaneDropTarget(PaneDropTarget(pane: paneID, zone: workspace.dropZone(at: info.location, in: size)))
    }
}
