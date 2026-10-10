import AppKit
import SwiftUI
import VibeCore

/// Shown when no document is open: a calm animated backdrop, quick actions and recent files.
struct WelcomeView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    @State private var appeared = false

    var body: some View {
        let theme = settings.theme
        let recents = Array(workspace.recents.all.filter { !workspace.recents.isMissing($0.path) }.prefix(6))
        ZStack {
            AuroraBackground(theme: theme)
            ScrollView {
                VStack(spacing: 30) {
                    VStack(spacing: 14) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 104, height: 104)
                            .shadow(color: theme.accent.color.opacity(0.35), radius: 24, y: 10)
                            .phaseAnimator([0.0, 1.0]) { content, phase in
                                content.offset(y: phase * -6).rotationEffect(.degrees(phase * 1.5 - 0.75))
                            } animation: { _ in .easeInOut(duration: 3.2) }
                        Text("Vibe Notepad")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.foreground.color)
                        Text("Open anything. Read it beautifully.")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.mutedForeground.color)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)

                    GlassEffectContainer(spacing: 12) {
                        let actions = actions
                        // One row when there's room, two otherwise.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { ForEach(actions.indices, id: \.self) { actions[$0] } }
                            VStack(spacing: 12) {
                                HStack(spacing: 12) { ForEach(0..<2, id: \.self) { actions[$0] } }
                                HStack(spacing: 12) { ForEach(2..<actions.count, id: \.self) { actions[$0] } }
                            }
                        }
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)

                    if !recents.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Jump back in")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.mutedForeground.color)
                                .textCase(.uppercase)
                                .tracking(0.6)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                                ForEach(Array(recents.enumerated()), id: \.element.id) { index, item in
                                    RecentCard(item: item)
                                        .opacity(appeared ? 1 : 0)
                                        .offset(y: appeared ? 0 : 18)
                                        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.12 + Double(index) * 0.05), value: appeared)
                                }
                            }
                        }
                        .frame(maxWidth: 720)
                    }

                    Label("Drop files or a folder anywhere to open them", systemImage: "arrow.down.document")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.mutedForeground.color.opacity(0.8))
                        .opacity(appeared ? 1 : 0)
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 56)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) { appeared = true }
        }
    }

    private var actions: [WelcomeAction] {
        [
            WelcomeAction(title: "New File", symbol: "square.and.pencil", keys: "⌘N") { workspace.newDocument() },
            WelcomeAction(title: "Open…", symbol: "doc", keys: "⌘O") { workspace.showOpenPanel() },
            WelcomeAction(title: "Open Folder…", symbol: "folder", keys: "⇧⌘O") { workspace.showOpenFolderPanel() },
            WelcomeAction(title: "Quick Open", symbol: "sparkle.magnifyingglass", keys: "⌘P") { workspace.showPalette(.files) },
        ]
    }
}

private struct WelcomeAction: View {
    let title: String
    let symbol: String
    let keys: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .symbolEffect(.bounce, value: isHovering)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                KeyHint(keys: keys)
            }
            .frame(width: 128, height: 100)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .scaleEffect(isHovering ? 1.04 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

private struct RecentCard: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    let item: RecentFile
    @State private var isHovering = false

    var body: some View {
        let theme = settings.theme
        let language = item.language ?? LanguageRegistry.detect(path: item.path)
        Button {
            workspace.open(url: item.url)
        } label: {
            HStack(spacing: 11) {
                FileIcon(language: language, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.foreground.color)
                        .lineLimit(1)
                    Text(item.url.abbreviatedParentPath)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.mutedForeground.color)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.accent.color)
                } else {
                    Text(RelativeTime.short(item.lastOpened))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(theme.mutedForeground.color)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.foreground.color.opacity(isHovering ? 0.09 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.foreground.color.opacity(isHovering ? 0.16 : 0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.02 : 1)
        .shadow(color: .black.opacity(isHovering ? 0.12 : 0), radius: 10, y: 4)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isHovering)
        .onHover { isHovering = $0 }
        .help(item.path)
    }
}

/// Slowly drifting mesh gradient tinted with the theme's accent colors. It drifts for a while
/// when the window comes forward and then rests: a full-window gradient (and the glass that
/// samples it) redrawn forever would cost a steady slice of CPU.
struct AuroraBackground: View {
    let theme: Theme
    @Environment(\.appearsActive) private var appearsActive
    @State private var drifting = false

    var body: some View {
        let base = theme.background
        let tint1 = (theme.style(for: .keyword)?.color ?? theme.accent).withAlpha(theme.isDark ? 0.22 : 0.16).flattened(over: base)
        let tint2 = (theme.style(for: .function)?.color ?? theme.accent).withAlpha(theme.isDark ? 0.18 : 0.13).flattened(over: base)
        let tint3 = (theme.style(for: .string)?.color ?? theme.accent).withAlpha(theme.isDark ? 0.14 : 0.1).flattened(over: base)
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !drifting)) { context in
            let t = context.date.timeIntervalSinceReferenceDate / 7
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [Float(0.5 + 0.18 * sin(t)), Float(0.5 + 0.14 * cos(t * 1.3))], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    base.color, tint1.color, base.color,
                    tint2.color, base.color, tint3.color,
                    base.color, tint1.color, base.color,
                ]
            )
        }
        .ignoresSafeArea()
        .task(id: appearsActive) {
            drifting = appearsActive
            guard appearsActive else { return }
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { drifting = false }
        }
    }
}
