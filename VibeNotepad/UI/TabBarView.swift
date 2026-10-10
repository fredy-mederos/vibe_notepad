import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeCore

extension UTType {
    /// A tab being dragged to a new position (private to the app, so other apps ignore it).
    nonisolated static let vibeNotepadTab = UTType(exportedAs: "com.fredymederos.vibenotepad.tab")
}

/// What a dragged tab carries.
nonisolated struct TabDragItem: Codable, Sendable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .vibeNotepadTab)
    }
}

/// Open documents as tabs: a sliding selection pill, dirty dots that morph into close
/// buttons on hover, drag to reorder.
struct TabBarView: View {
    static let height: CGFloat = 38

    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    @Namespace private var namespace

    var body: some View {
        let theme = settings.theme
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(workspace.documents) { document in
                        TabItemView(document: document,
                                    isSelected: document.id == workspace.selectedID,
                                    namespace: namespace)
                            .id(document.id)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.7, anchor: .leading).combined(with: .opacity),
                                removal: .scale(scale: 0.85).combined(with: .opacity)))
                    }
                    Button {
                        workspace.newDocument()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.mutedForeground.color)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New File (⌘N)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .onChange(of: workspace.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: Self.height)
        .background(theme.chromeBackground.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.foreground.color.opacity(0.08)).frame(height: 1)
        }
    }
}

struct TabItemView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    @Bindable var document: EditorDocument
    let isSelected: Bool
    let namespace: Namespace.ID

    @State private var isHovering = false
    @State private var isHoveringClose = false
    @State private var showSavedCheck = false
    @State private var isDropTarget = false

    var body: some View {
        let theme = settings.theme
        HStack(spacing: 7) {
            ZStack {
                FileIcon(language: document.language, size: 15)
                    .opacity(showSavedCheck ? 0 : 1)
                    .scaleEffect(showSavedCheck ? 0.4 : 1)
                if showSavedCheck {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .frame(width: 16, height: 16)

            Text(document.displayName)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .italic(document.isUntitled)

            closeButton(theme: theme)
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 28)
        .frame(maxWidth: 240)
        .foregroundStyle(isSelected ? theme.foreground.color : theme.mutedForeground.color)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.isDark ? theme.background.mixed(with: RGBA(r: 1, g: 1, b: 1), 0.07).color : theme.background.color)
                    .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.1), radius: 2.5, y: 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.foreground.color.opacity(theme.isDark ? 0.12 : 0.07), lineWidth: 1)
                    )
                    .matchedGeometryEffect(id: "selected-tab", in: namespace)
            } else if isHovering || isDropTarget {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.foreground.color.opacity(isDropTarget ? 0.12 : 0.055))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { workspace.select(document) }
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.15)) { isHovering = hovering }
        }
        .help(document.fileURL?.abbreviatedPath ?? document.displayName)
        .draggable(TabDragItem(id: document.id)) {
            HStack(spacing: 6) {
                FileIcon(language: document.language, size: 15)
                Text(document.displayName).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .dropDestination(for: TabDragItem.self) { items, _ in
            guard let id = items.first?.id, id != document.id else { return false }
            workspace.moveDocument(id, before: document.id)
            return true
        } isTargeted: { targeted in
            withAnimation(.snappy(duration: 0.15)) { isDropTarget = targeted }
        }
        .contextMenu { TabContextMenu(document: document) }
        .onChange(of: document.saveCount) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { showSavedCheck = true }
            Task {
                try? await Task.sleep(for: .seconds(1.1))
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showSavedCheck = false }
            }
        }
    }

    /// A dot while there are unsaved changes; an ✕ on hover (or for the selected tab).
    @ViewBuilder
    private func closeButton(theme: Theme) -> some View {
        let showDot = document.isDirty && !isHovering
        ZStack {
            if showDot {
                Circle()
                    .fill(theme.accent.color)
                    .frame(width: 7, height: 7)
                    .transition(.scale.combined(with: .opacity))
            } else if isHovering || isSelected {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 18, height: 18)
        .background(Circle().fill(theme.foreground.color.opacity(isHoveringClose && !showDot ? 0.14 : 0)))
        .contentShape(Circle())
        .onHover { isHoveringClose = $0 }
        .onTapGesture { workspace.close(document) }
        .animation(.snappy(duration: 0.18), value: showDot)
        .help("Close (⌘W)")
    }
}

struct TabContextMenu: View {
    @Environment(Workspace.self) private var workspace
    let document: EditorDocument

    var body: some View {
        Button("Close", systemImage: "xmark") { workspace.close(document) }
        Button("Close Other Tabs") { workspace.closeOthers(document) }
            .disabled(workspace.documents.count < 2)
        Button("Close Tabs to the Right") { workspace.closeToTheRight(of: document) }
            .disabled(workspace.documents.last?.id == document.id)
        Divider()
        if let url = document.fileURL {
            EnclosingFolderButton(item: url)
        }
        Button("Reveal in Finder", systemImage: "folder") { workspace.revealInFinder(document) }
            .disabled(document.fileURL == nil)
        Button("Copy Path", systemImage: "doc.on.clipboard") { workspace.copyPath(document) }
            .disabled(document.fileURL == nil)
        Button("Pin / Unpin in Sidebar", systemImage: "pin") { workspace.togglePin(document) }
            .disabled(document.fileURL == nil)
    }
}
