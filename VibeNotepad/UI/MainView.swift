import AppKit
import SwiftUI
import VibeCore

/// The single main window: recents sidebar, tabs, editor/preview, status bar and overlays.
struct MainView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var isDropTargeted = false
    /// Follows `showsSidebar` once the sidebar has stopped moving (see `MainToolbar`).
    @State private var toolbarHidden = !AppSettings.shared.showsSidebar

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 380)
        } detail: {
            DetailView()
        }
        .navigationTitle(workspace.selectedDocument?.displayName ?? "Vibe Notepad")
        .navigationSubtitle(subtitle)
        .toolbar { MainToolbar(hidden: toolbarHidden) }
        .onChange(of: settings.showsSidebar) { _, shows in
            Task {
                try? await Task.sleep(for: SidebarAnimation.settleDelay)
                if settings.showsSidebar == shows { toolbarHidden = !shows }
            }
        }
        .overlay { PaletteOverlay() }
        .overlay(alignment: .bottom) {
            ToastStack()
                .padding(.bottom, workspace.showsStatusBar ? 44 : 18)
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
            workspace.installTabReveal(on: window)
        })
        .onAppear {
            AppDelegate.shared?.openMainWindow = { openWindow(id: "main") }
            workspace.openSettingsAction = { openSettings() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebarRequest)) { _ in
            withAnimation(SidebarAnimation.animation) { settings.showsSidebar.toggle() }
        }
    }

    /// The sidebar's visibility, kept in settings so it survives relaunches (the status bar follows it).
    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { settings.showsSidebar ? .all : .detailOnly },
            set: { settings.showsSidebar = $0 != .detailOnly }
        )
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

/// Collapsing or expanding the sidebar. The tab and status bars slide with it.
enum SidebarAnimation {
    static let animation = Animation.snappy(duration: 0.3)
    /// When the slide is over. Changes too slow to make on every frame of it (the toolbar's items,
    /// the editor's wrap width and minimap) are made then.
    static let settleDelay: Duration = .milliseconds(400)
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
        let showsBars = settings.showsSidebar
        // The tab and status bars are overlays that slide over spacers making room for them, and
        // they stay alive while the sidebar is collapsed: when the sidebar animates, laying the bars
        // out on every frame (or rebuilding every tab) makes it stutter, while sliding them is cheap.
        VStack(spacing: 0) {
            if !workspace.documents.isEmpty {
                Color.clear.frame(height: showsBars ? TabBarView.height : 0)
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
            if workspace.selectedDocument != nil {
                Color.clear.frame(height: showsBars ? StatusBarView.height : 0)
            }
        }
        .overlay(alignment: .top) {
            if !workspace.documents.isEmpty {
                TabBarView()
                    .slidAway(!showsBars, by: -TabBarView.height)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let document = workspace.selectedDocument {
                StatusBarView(document: document)
                    .slidAway(!showsBars, by: StatusBarView.height)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            // Sidebar collapsed: the tabs float over the text while the pointer is in the title bar.
            if !settings.showsSidebar, workspace.tabsRevealed, !workspace.documents.isEmpty {
                TabBarView()
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                    .transition(.opacity.combined(with: .offset(y: -8)))
            }
        }
        .background(theme.background.color)
        .animation(.snappy(duration: 0.3), value: workspace.documents.isEmpty)
        .animation(SidebarAnimation.animation, value: settings.showsSidebar)
    }
}

extension View {
    /// Slides a bar out of its slot (`offset` points down, so negative goes up) and fades it,
    /// without changing its layout.
    func slidAway(_ away: Bool, by offset: CGFloat) -> some View {
        self.offset(y: away ? offset : 0)
            .opacity(away ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: abs(offset), alignment: offset < 0 ? .bottom : .top)
            .clipped()
            .allowsHitTesting(!away)
            .accessibilityHidden(away)
    }
}

/// Window toolbar. With the sidebar collapsed ("just the text") it's empty, leaving the title,
/// the path and the sidebar button; everything comes back with the sidebar (shortcuts always work).
/// Changing the toolbar takes tens of milliseconds, so it changes once the sidebar has stopped
/// moving (`hidden` lags `showsSidebar`) instead of stalling the animation.
struct MainToolbar: ToolbarContent {
    @Environment(Workspace.self) private var workspace
    let hidden: Bool

    var body: some ToolbarContent {
        if !hidden {
            ToolbarItem(placement: .navigation) {
                Button {
                    workspace.newDocument()
                } label: {
                    Label("New File", systemImage: "square.and.pencil")
                }
                .help("New File (⌘N)")
            }
            actions
        }
    }

    @ToolbarContentBuilder
    private var actions: some ToolbarContent {
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
