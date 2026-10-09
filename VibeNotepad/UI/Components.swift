import AppKit
import SwiftUI
import VibeCore

/// A small colored badge identifying a file's language.
struct FileIcon: View {
    let language: LanguageID
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(language.tint.gradient)
            switch language.icon {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            case .text(let label):
                Text(label)
                    .font(.system(size: size * (label.count > 1 ? 0.42 : 0.56), weight: .heavy, design: .rounded))
                    .foregroundStyle(language == .javascript ? Color.black.opacity(0.78) : .white)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: language.tint.opacity(0.3), radius: 1.5, y: 0.5)
        .accessibilityLabel(language.displayName)
    }
}

/// Compact relative dates for the sidebar: "now", "5m", "3h", "2d", "Mar 4".
enum RelativeTime {
    static func short(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 7): return "\(Int(seconds / 86_400))d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

/// Text with fuzzy-matched characters emphasized.
struct HighlightedText: View {
    let text: String
    let positions: [Int]
    var font: Font = .system(size: 13)
    var highlight: Color = .accentColor

    var body: some View {
        Text(attributed).font(font)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        let marked = Set(positions)
        for (index, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if marked.contains(index) {
                piece.foregroundColor = highlight
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            result.append(piece)
        }
        return result
    }
}

/// A rounded keyboard-shortcut hint.
struct KeyHint: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.primary.opacity(0.07)))
    }
}

/// Gives SwiftUI access to the hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.configure = configure
        return view
    }

    func updateNSView(_ nsView: AccessorView, context: Context) {}

    final class AccessorView: NSView {
        var configure: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { configure?(window) }
        }
    }
}

/// Hosts an AppKit view owned elsewhere (the editor's scroll view, the preview's web view),
/// so it survives SwiftUI recreating the representable when tabs switch.
final class HostingContainerView: NSView {
    var onAttach: (() -> Void)?

    func host(_ view: NSView) {
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.onAttach?() }
    }
}

/// Builds an attributed preview of `code` with a theme's syntax colors.
enum ThemedSnippet {
    static func attributed(_ code: String, language: LanguageID, theme: Theme, size: CGFloat = 11) -> AttributedString {
        let lines = code.components(separatedBy: "\n")
        let tokens = SyntaxHighlighter.tokenize(code, language: language)
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            let units = Array(line.utf16)
            var kinds = [TokenKind](repeating: .plain, count: units.count)
            for token in index < tokens.count ? tokens[index] : [] {
                for k in max(0, token.start)..<min(units.count, token.start + token.length) { kinds[k] = token.kind }
            }
            var start = 0
            while start < units.count {
                var end = start + 1
                while end < units.count, kinds[end] == kinds[start] { end += 1 }
                var piece = AttributedString(String(decoding: units[start..<end], as: UTF16.self))
                let style = theme.style(for: kinds[start])
                piece.foregroundColor = (style?.color ?? theme.foreground).color
                piece.font = .system(size: size, weight: style?.bold == true ? .bold : .regular, design: .monospaced)
                    .italic(style?.italic == true)
                result.append(piece)
                start = end
            }
            if index < lines.count - 1 { result.append(AttributedString("\n")) }
        }
        return result
    }
}
