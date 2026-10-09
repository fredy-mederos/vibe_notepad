import AppKit
import SwiftUI
import VibeCore

/// The single main window: recents sidebar, tabs, editor/preview, status bar and overlays.
struct MainView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 380)
        } detail: {
            DetailView()
        }
        .navigationTitle(workspace.selectedDocument?.displayName ?? "Vibe Notepad")
        .navigationSubtitle(subtitle)
        .toolbar { MainToolbar() }
        .overlay { PaletteOverlay() }
        .overlay(alignment: .bottom) {
            ToastStack()
                .padding(.bottom, 44)
        }
        .overlay {
            if isDropTargeted {
                DropOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 1.015)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isDropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            workspace.open(urls: files)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .background(WindowAccessor { window in
            workspace.windowReference = window
            window.tabbingMode = .disallowed
            window.isRestorable = false
        })
        .onAppear {
            AppDelegate.shared?.openMainWindow = { openWindow(id: "main") }
            workspace.openSettingsAction = { openSettings() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebarRequest)) { _ in
            withAnimation(.snappy) {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
    }

    private var subtitle: String {
        guard let document = workspace.selectedDocument else { return "" }
        if let url = document.fileURL { return url.abbreviatedParentPath }
        return document.isDirty ? "Unsaved" : ""
    }
}

extension Notification.Name {
    static let toggleSidebarRequest = Notification.Name("VibeNotepad.toggleSidebar")
}

/// Adds the title-bar proxy icon (drag the file, ⌘-click for its path) when there is a file.
/// Applied inside the per-document view so the branch never rebuilds the split view.
struct DocumentProxy: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.navigationDocument(url)
        } else {
            content
        }
    }
}

/// Tabs, the current document (or the welcome screen), find bar and status bar.
struct DetailView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let theme = settings.theme
        VStack(spacing: 0) {
            if !workspace.documents.isEmpty {
                TabBarView()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ZStack(alignment: .topTrailing) {
                if let document = workspace.selectedDocument {
                    DocumentView(document: document)
                        .id(document.id)
                        .transition(.opacity)
                } else {
                    WelcomeView()
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
                if workspace.findBarVisible, workspace.selectedDocument != nil {
                    FindBarView()
                        .padding(.top, 10)
                        .padding(.trailing, 18)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let document = workspace.selectedDocument {
                StatusBarView(document: document)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(theme.background.color)
        .animation(.snappy(duration: 0.3), value: workspace.documents.isEmpty)
    }
}

/// Window toolbar.
struct MainToolbar: ToolbarContent {
    @Environment(Workspace.self) private var workspace

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                workspace.newDocument()
            } label: {
                Label("New File", systemImage: "square.and.pencil")
            }
            .help("New File (⌘N)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if let document = workspace.selectedDocument, document.isMarkdown {
                Picker("View", selection: Binding(get: { document.markdownMode }, set: { workspace.setMarkdownMode($0) })) {
                    ForEach(MarkdownMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help("Editor (⌥⌘1) · Split (⌥⌘2) · Preview (⌥⌘3)")
            }
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                workspace.showFindBar()
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .help("Find (⌘F)")
            .disabled(workspace.selectedDocument == nil)

            Button {
                workspace.showPalette(.files)
            } label: {
                Label("Quick Open", systemImage: "sparkle.magnifyingglass")
            }
            .help("Quick Open (⌘P)")

            Menu {
                Button("Command Palette…", systemImage: "command") { workspace.showPalette(.commands) }
                Button("Go to Line…", systemImage: "arrow.right.to.line") { workspace.showPalette(.goToLine) }
                    .disabled(workspace.selectedDocument == nil)
                Button("Go to Symbol…", systemImage: "list.bullet.indent") { workspace.showPalette(.symbols) }
                    .disabled(workspace.selectedDocument == nil)
                Divider()
                Button("Reveal in Finder", systemImage: "folder") { workspace.revealInFinder() }
                    .disabled(workspace.selectedDocument?.fileURL == nil)
                Button("Copy File Path", systemImage: "doc.on.clipboard") { workspace.copyPath() }
                    .disabled(workspace.selectedDocument?.fileURL == nil)
                Button("Pin / Unpin in Sidebar", systemImage: "pin") { workspace.togglePin() }
                    .disabled(workspace.selectedDocument?.fileURL == nil)
                Divider()
                Button("Change Theme…", systemImage: "paintpalette") { workspace.showPalette(.theme) }
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("More")
        }
    }
}

/// Shown while files are dragged over the window.
struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2.5, dash: [10, 8]))
            .foregroundStyle(.tint)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.tint.opacity(0.07)))
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.document.fill")
                        .font(.system(size: 46, weight: .medium))
                        .foregroundStyle(.tint)
                        .symbolEffect(.bounce.up.byLayer, options: .repeat(.periodic(delay: 0.6)))
                    Text("Drop to open")
                        .font(.title2.weight(.semibold))
                }
                .padding(28)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
            .padding(14)
            .allowsHitTesting(false)
    }
}

/// Transient confirmations ("Saved", "Copied path"...).
struct ToastStack: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 8) {
            ForEach(workspace.toasts) { toast in
                HStack(spacing: 8) {
                    Image(systemName: toast.symbol)
                        .foregroundStyle(toast.tint)
                        .symbolEffect(.bounce, value: toast.id)
                    Text(toast.message)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
            }
        }
        .allowsHitTesting(false)
    }
}
