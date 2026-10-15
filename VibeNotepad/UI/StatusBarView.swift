import SwiftUI
import VibeCore

/// Caret position, counts, and quick menus for indentation, line endings, encoding and language (for a
/// picture: its size and format, and the zoom).
struct StatusBarView: View {
    static let height: CGFloat = 26

    @Environment(Workspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    @Bindable var document: EditorDocument

    var body: some View {
        let theme = settings.theme
        HStack(spacing: 14) {
            if document.isImage {
                ImageStatusItems(viewer: document.imageViewer)
            } else {
                textItems
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(theme.mutedForeground.color)
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(theme.chromeBackground.color)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.foreground.color.opacity(0.08)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var textItems: some View {
        let theme = settings.theme
        let cursor = document.cursor
        Button {
            workspace.showPalette(.goToLine)
        } label: {
            HStack(spacing: 3) {
                Text("Ln \(cursor.line), Col \(cursor.column)")
                    .contentTransition(.numericText())
                if cursor.selectionLength > 0 {
                    Text(cursor.selectedLines > 1 ? "· \(cursor.selectedLines) lines, \(cursor.selectionLength) chars" : "· \(cursor.selectionLength) selected")
                        .foregroundStyle(theme.accent.color)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .animation(.snappy(duration: 0.2), value: cursor)
        }
        .buttonStyle(StatusButtonStyle())
        .help("Go to Line (⌃G)")

        if let words = document.wordCount {
            Text("\(words) words")
                .contentTransition(.numericText())
                .animation(.snappy, value: words)
        }
        Text("\(cursor.lineCount) lines")
            .contentTransition(.numericText())
            .animation(.snappy, value: cursor.lineCount)
        if let path = document.xmlPath {
            XMLPathMenu(document: document, path: path)
                .layoutPriority(-1)
        }

        Spacer(minLength: 8)

        Menu {
            Button("Spaces: 2") { document.indentation = Indentation(usesTabs: false, width: 2) }
            Button("Spaces: 4") { document.indentation = Indentation(usesTabs: false, width: 4) }
            Button("Spaces: 8") { document.indentation = Indentation(usesTabs: false, width: 8) }
            Divider()
            Button("Tabs (width 2)") { document.indentation = Indentation(usesTabs: true, width: 2) }
            Button("Tabs (width 4)") { document.indentation = Indentation(usesTabs: true, width: 4) }
            Divider()
            Button("Convert Indentation to Spaces") { workspace.convertIndentation(document, toTabs: false) }
            Button("Convert Indentation to Tabs") { workspace.convertIndentation(document, toTabs: true) }
        } label: {
            Text(document.indentation.label)
        }
        .menuStyle(.button)
        .buttonStyle(StatusButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()

        Menu {
            ForEach(LineEnding.allCases, id: \.self) { ending in
                Button {
                    guard document.lineEnding != ending else { return }
                    document.lineEnding = ending
                    document.markChangedWithoutUndo()
                } label: {
                    if ending == document.lineEnding {
                        Label(ending.description, systemImage: "checkmark")
                    } else {
                        Text(ending.description)
                    }
                }
            }
        } label: {
            Text(document.lineEnding.label)
        }
        .menuStyle(.button)
        .buttonStyle(StatusButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Line endings used when saving")

        Menu {
            Section("Reopen with Encoding") {
                ForEach(TextFileCodec.commonEncodings, id: \.rawValue) { encoding in
                    Button(TextFileCodec.name(of: encoding)) { workspace.reopen(document, encoding: encoding) }
                        .disabled(document.fileURL == nil)
                }
            }
            Section("Save with Encoding") {
                Button("UTF-8") {
                    document.encoding = .utf8
                    document.hasBOM = false
                    Task { await workspace.save(document) }
                }
                Button("UTF-8 with BOM") {
                    document.encoding = .utf8
                    document.hasBOM = true
                    Task { await workspace.save(document) }
                }
            }
        } label: {
            Text(TextFileCodec.name(of: document.encoding) + (document.hasBOM ? " BOM" : ""))
        }
        .menuStyle(.button)
        .buttonStyle(StatusButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()

        Button {
            workspace.showPalette(.language)
        } label: {
            HStack(spacing: 5) {
                FileIcon(language: document.language, size: 13)
                Text(document.language.displayName)
            }
        }
        .buttonStyle(StatusButtonStyle())
        .help("Change syntax highlighting")
    }
}

/// The elements around the caret in an XML document, `project › dependencies › dependency[2]`.
/// A click copies the XPath; holding it opens a menu that also selects the element or goes to one
/// of its parents.
struct XMLPathMenu: View {
    @Environment(Workspace.self) private var workspace
    let document: EditorDocument
    let path: XMLPath

    var body: some View {
        Menu {
            Button("Copy XPath", systemImage: "doc.on.clipboard") { workspace.copyXPath(path) }
            Button("Select Element", systemImage: "selection.pin.in.out") { workspace.selectXMLElement(in: document.editor) }
            Section("Go to") {
                ForEach(Array(path.elements.enumerated()), id: \.offset) { depth, element in
                    Button(String(repeating: "    ", count: depth) + "<\(element.step)>") {
                        workspace.goToXMLElement(element, in: document.editor)
                    }
                }
            }
        } label: {
            Text(breadcrumb)
                .lineLimit(1)
                .truncationMode(.head)
        } primaryAction: {
            workspace.copyXPath(path)
        }
        .menuStyle(.button)
        .buttonStyle(StatusButtonStyle())
        .menuIndicator(.hidden)
        .help("\(path.xpath)\nClick to copy the XPath, hold for more")
    }

    /// The last few steps: `… › dependency[2] › version › @scope`.
    private var breadcrumb: String {
        var steps = path.elements.map(\.step)
        if let attribute = path.attribute { steps.append("@" + attribute) }
        let shown = steps.suffix(4)
        return (steps.count > shown.count ? "… › " : "") + shown.joined(separator: " › ")
    }
}

/// Flat status-bar button with a subtle hover background.
struct StatusButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (isHovering ? 0.07 : 0)))
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}
