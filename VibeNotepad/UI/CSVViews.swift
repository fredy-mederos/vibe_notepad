import AppKit
import SwiftUI
import VibeCore

/// A CSV or TSV document's table, under a bar with the outlined cell's name and whole value (like a
/// spreadsheet's formula bar), how the rows are sorted, the table's size, its delimiter and whether
/// the first row holds the column titles.
struct CSVPreviewView: View {
    @Environment(AppSettings.self) private var settings
    let document: EditorDocument
    /// See `EditorHost.isInFocusedPane`.
    let isInFocusedPane: Bool

    var body: some View {
        let theme = settings.theme
        let preview = document.csvPreview
        VStack(spacing: 0) {
            CSVBar(preview: preview)
            ZStack {
                CSVTableHost(document: document, preview: preview, isInFocusedPane: isInFocusedPane, takesFocus: document.markdownMode == .preview)
                if preview.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if let table = preview.table, preview.shownRowCount == 0 {
                    Text(table.rowCount == 0 ? "No rows yet" : "No rows under the header")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.mutedForeground.color)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(theme.background.color)
    }
}

private struct CSVBar: View {
    @Environment(AppSettings.self) private var settings
    let preview: CSVPreviewController

    /// How much the bar holds: everything, down to what a narrow pane has room for.
    private enum Detail {
        case full
        case withoutSize
        case compact
        case minimal
    }

    var body: some View {
        let theme = settings.theme
        ViewThatFits(in: .horizontal) {
            row(.full)
            row(.withoutSize)
            row(.compact)
            row(.minimal)
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.mutedForeground.color)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(theme.chromeBackground.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.foreground.color.opacity(0.08)).frame(height: 1)
        }
    }

    private func row(_ detail: Detail) -> some View {
        let theme = settings.theme
        return HStack(spacing: 8) {
            if let reference = preview.activeReference, let value = preview.activeValue {
                Text(reference)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.accent.color)
                    .fixedSize()
                if detail != .minimal {
                    Rectangle()
                        .fill(theme.foreground.color.opacity(0.12))
                        .frame(width: 1, height: 14)
                    // Room for a few characters at least, or the bar holds less.
                    Text(value.isEmpty ? "Empty" : CSVPreviewController.flattened(String(value.prefix(2_000))))
                        .foregroundStyle(value.isEmpty ? theme.mutedForeground.color : theme.foreground.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .help(String(value.prefix(4_000)))
                        .frame(minWidth: 0, idealWidth: 70, maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 8)
            if preview.isSorting {
                ProgressView()
                    .controlSize(.mini)
                    .help("Sorting…")
            }
            if let sort = preview.sortSummary {
                Button {
                    preview.clearSort()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
                        if detail == .full || detail == .withoutSize {
                            Text(sort.title)
                                .lineLimit(1)
                        }
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.mutedForeground.color)
                    }
                    .foregroundStyle(theme.accent.color)
                }
                .buttonStyle(StatusButtonStyle())
                .fixedSize()
                .help("Sorted by \(sort.title), \(sort.ascending ? "ascending" : "descending"). Click to show the rows in the file’s order")
            }
            if let table = preview.table {
                if detail == .full {
                    Text(size(rows: preview.shownRowCount, columns: table.columnCount, shown: preview.shownColumnCount))
                        .fixedSize()
                }
                delimiterMenu(table.delimiter)
            }
            Button {
                preview.setUsesHeader(!preview.usesHeader)
            } label: {
                if detail == .full || detail == .withoutSize {
                    Label("Header Row", systemImage: preview.usesHeader ? "checkmark.square.fill" : "square")
                        .labelStyle(.titleAndIcon)
                } else {
                    Image(systemName: preview.usesHeader ? "checkmark.square.fill" : "square")
                }
            }
            .buttonStyle(StatusButtonStyle())
            .fixedSize()
            .help(preview.usesHeader ? "Header row: the first row holds the column titles" : "Use the first row as the column titles")
        }
    }

    private func delimiterMenu(_ delimiter: CSVTable.Delimiter) -> some View {
        Menu {
            Picker("Separator", selection: Binding(get: { preview.chosenDelimiter }, set: { preview.choose($0) })) {
                Text("Detect Automatically").tag(CSVTable.Delimiter?.none)
                ForEach(CSVTable.Delimiter.allCases, id: \.self) { delimiter in
                    Text("\(delimiter.name)   \(delimiter.symbol)").tag(Optional(delimiter))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(delimiter.name)
        }
        .menuStyle(.button)
        .buttonStyle(StatusButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Columns are separated by \(delimiter.name.lowercased())s (\(delimiter.symbol))\(preview.chosenDelimiter == nil ? ", detected from the text" : "")")
    }

    private func size(rows: Int, columns: Int, shown: Int) -> String {
        let rowText = rows == 1 ? "1 row" : "\(rows.formatted()) rows"
        let columnText = shown < columns ? "\(shown.formatted()) of \(columns.formatted()) columns" : (columns == 1 ? "1 column" : "\(columns.formatted()) columns")
        return "\(rowText) × \(columnText)"
    }
}

/// Embeds a CSV document's table.
struct CSVTableHost: NSViewRepresentable {
    let document: EditorDocument
    let preview: CSVPreviewController
    /// See `EditorHost.isInFocusedPane`.
    let isInFocusedPane: Bool
    /// Whether it takes the keyboard when it appears (when it shows without the editor).
    let takesFocus: Bool

    func makeNSView(context: Context) -> HostingContainerView {
        let container = HostingContainerView()
        container.onAttach = { [weak document, weak preview, takesFocus] in
            guard let document, let preview else { return }
            let workspace = Workspace.shared
            if takesFocus, !workspace.findBarVisible, workspace.palette == nil, workspace.selectedDocument === document { preview.focus() }
        }
        container.host(preview.scrollView)
        return container
    }

    func updateNSView(_ container: HostingContainerView, context: Context) {
        container.host(preview.scrollView)
    }

    static func dismantleNSView(_ container: HostingContainerView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}
