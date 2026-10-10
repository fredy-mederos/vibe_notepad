import SwiftUI
import VibeCore

/// Floating find & replace panel with regex, case and whole-word options and a live match counter.
struct FindBarView: View {
    @Environment(Workspace.self) private var workspace
    @FocusState private var focus: Field?

    private enum Field { case find, replace }

    var body: some View {
        @Bindable var workspace = workspace
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { workspace.replaceVisible.toggle() }
                        if workspace.replaceVisible, !workspace.findsInPreview { focus = .replace }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(workspace.replaceVisible ? 90 : 0))
                            .frame(width: 18, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(workspace.replaceVisible ? "Hide Replace" : "Show Replace (⌥⌘F)")

                    SearchField(text: $workspace.findQuery, placeholder: "Find", symbol: "magnifyingglass", isError: workspace.findError != nil) {
                        OptionToggle(label: "Aa", help: "Match Case", isOn: $workspace.findOptions.caseSensitive)
                        OptionToggle(label: "ab", help: "Whole Word", underline: true, isOn: $workspace.findOptions.wholeWord)
                        OptionToggle(label: ".*", help: "Regular Expression", isOn: $workspace.findOptions.isRegex)
                    }
                    .focused($focus, equals: .find)
                    .onSubmit { workspace.findNext(forward: !NSEvent.modifierFlags.contains(.shift)) }

                    Text(counterLabel)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(workspace.findError != nil || (workspace.findMatchCount == 0 && !workspace.findQuery.isEmpty) ? Color.orange : .secondary)
                        .contentTransition(.numericText())
                        .frame(minWidth: 70)
                        .animation(.snappy(duration: 0.2), value: counterLabel)

                    IconButton(symbol: "chevron.up", help: "Previous (⇧⌘G)") { workspace.findNext(forward: false) }
                        .disabled(workspace.findMatchCount == 0)
                    IconButton(symbol: "chevron.down", help: "Next (⌘G)") { workspace.findNext(forward: true) }
                        .disabled(workspace.findMatchCount == 0)
                    IconButton(symbol: "xmark", help: "Close (esc)") { workspace.hideFindBar() }
                }

                if workspace.replaceVisible, !workspace.findsInPreview {
                    HStack(spacing: 6) {
                        Color.clear.frame(width: 18, height: 1)
                        SearchField(text: $workspace.replaceQuery, placeholder: workspace.findOptions.isRegex ? "Replace ($1, \\n)" : "Replace", symbol: "arrow.left.arrow.right") {
                            EmptyView()
                        }
                        .focused($focus, equals: .replace)
                        .onSubmit { workspace.replaceCurrent() }
                        Button("Replace") { workspace.replaceCurrent() }
                            .disabled(workspace.findMatchCount == 0)
                        Button("All") { workspace.replaceAll() }
                            // Zero-length regex matches (`^`, `$`) aren't counted but can still be replaced.
                            .disabled(workspace.findMatchCount == 0 && !(workspace.findOptions.isRegex && !workspace.findQuery.isEmpty))
                            .help("Replace All")
                    }
                    .controlSize(.small)
                    .buttonStyle(.glass)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(9)
            .frame(width: 520)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .onKeyPress(.escape) {
            workspace.hideFindBar()
            return .handled
        }
        .onChange(of: workspace.findFocusRequest, initial: true) {
            DispatchQueue.main.async { focus = .find }
        }
        .task(id: workspace.findQuery) {
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            workspace.performFind(reveal: true)
        }
        .onChange(of: workspace.findOptions) {
            workspace.performFind(reveal: true)
        }
    }

    private var counterLabel: String {
        if workspace.findError != nil { return "Invalid regex" }
        if workspace.findQuery.isEmpty { return "" }
        if workspace.findMatchCount == 0 { return "No results" }
        if workspace.findsInPreview { return "In preview" }
        if let index = workspace.findCurrentIndex { return "\(index + 1) of \(workspace.findMatchCount)" }
        return "\(workspace.findMatchCount) found"
    }
}

/// A rounded text field with an icon and trailing accessory views.
private struct SearchField<Accessory: View>: View {
    @Binding var text: String
    let placeholder: String
    let symbol: String
    var isError = false
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            accessory()
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isError ? Color.orange.opacity(0.7) : Color.clear, lineWidth: 1)
        )
    }
}

/// Small toggle chip ("Aa", ".*", "ab").
private struct OptionToggle: View {
    let label: String
    let help: String
    var underline = false
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { isOn.toggle() }
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .underline(underline)
                .frame(width: 24, height: 20)
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isOn ? Color.accentColor : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(isHovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
