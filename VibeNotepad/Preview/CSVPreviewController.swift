import AppKit
import Observation
import SwiftUI
import VibeCore

/// The table preview of a CSV or TSV document, laid out like a spreadsheet: the first record as the
/// column titles (when it reads as titles), each record's line down the side, and the field under the
/// editor's caret outlined. Clicking a cell puts the caret on its field; double-clicking it (or Return)
/// goes there in the editor. The text is read again a moment after typing stops, a large one off the
/// main thread. Sorting by a column only changes what's shown, never the file.
@Observable
final class CSVPreviewController: NSObject {
    /// A field: its record (the header is record 0) and column.
    struct Cell: Equatable {
        var row: Int
        var column: Int
    }

    /// The order rows are shown in.
    enum Sort: Equatable {
        case file(ascending: Bool)
        case column(Int, ascending: Bool)
    }

    /// Columns past this many are left out: a table view with thousands of columns crawls.
    static let maxColumns = 500

    @ObservationIgnored unowned let document: EditorDocument
    @ObservationIgnored let scrollView: NSScrollView
    @ObservationIgnored let tableView: CSVTableView

    /// The table as last read; nil until the first read is done.
    private(set) var table: CSVTable?
    /// Whether the first record is shown as the column titles.
    private(set) var usesHeader = false
    /// The delimiter picked by hand; nil reads the text with the one it seems to use.
    private(set) var chosenDelimiter: CSVTable.Delimiter?
    /// The outlined cell: the caret's field, or the one last clicked.
    private(set) var activeCell: Cell?
    private(set) var sort = Sort.file(ascending: true)
    /// A large file is being read for the first time.
    private(set) var isLoading = false
    /// A large table is being sorted (it shows in the file's order meanwhile).
    private(set) var isSorting = false

    @ObservationIgnored private(set) var style = CSVTableStyle()
    /// Records in the order shown (nil: the file's order).
    @ObservationIgnored private var order: [Int]?
    /// For each record, the row showing it while sorted (-1 for the header).
    @ObservationIgnored private var shownRows: [Int32] = []
    /// Header on or off by hand (nil: guessed from the first record).
    @ObservationIgnored private var headerChoice: Bool?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var sortTask: Task<Void, Never>?
    @ObservationIgnored private var isReading = false
    @ObservationIgnored private var needsRead = false
    @ObservationIgnored private var textVersion = 0
    /// The `textVersion` and length of the text the table was read from: its offsets only hold while
    /// they match.
    @ObservationIgnored private var tableVersion = -1
    @ObservationIgnored private var tableLength = 0
    /// Set while the table moves the editor's caret, so the caret doesn't move the table back.
    @ObservationIgnored private var isMovingCaret = false

    init(document: EditorDocument) {
        self.document = document
        let table = CSVTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.style = .plain
        table.headerView = CSVHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: 26))
        table.cornerView = nil
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = true
        table.allowsTypeSelect = false
        table.selectionHighlightStyle = .regular
        table.focusRingType = .none
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = table
        tableView = table
        scrollView = scroll
        super.init()
        table.controller = self
        (table.headerView as? CSVHeaderView)?.controller = self
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked(_:))
        table.doubleAction = #selector(tableDoubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        if let path = document.path, let remembered = Workspace.shared.recents.item(for: path) {
            headerChoice = remembered.csvHeader
            chosenDelimiter = remembered.csvDelimiter.flatMap { CSVTable.Delimiter(rawValue: $0) }
        }
        applyTheme()
        read()
    }

    // MARK: Reading

    /// Called after every edit: reads the text again once typing pauses.
    func textDidChange() {
        textVersion += 1
        guard document.isCSV else { return }
        readTask?.cancel()
        readTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.read()
        }
    }

    /// The language changed between CSV and TSV: tabs may be the delimiter now.
    func languageDidChange() {
        guard chosenDelimiter == nil else { return }
        read()
    }

    /// Reads the text and shows it: a large text off the main thread, one read at a time.
    func read() {
        guard !isReading else {
            needsRead = true
            return
        }
        let version = textVersion
        let text = document.text
        let delimiter = chosenDelimiter
        let preferred = document.csvPreferredDelimiter
        let length = (text as NSString).length
        guard length > 200_000 else {
            show(CSVTable(text, delimiter: delimiter, preferred: preferred), version: version, length: length)
            return
        }
        isReading = true
        if table == nil { isLoading = true }
        Task { [weak self] in
            let table = await Task.detached(priority: .userInitiated) { CSVTable(text, delimiter: delimiter, preferred: preferred) }.value
            guard let self else { return }
            self.isReading = false
            self.isLoading = false
            self.show(table, version: version, length: length)
            if self.needsRead {
                self.needsRead = false
                self.read()
            }
        }
    }

    private func show(_ new: CSVTable, version: Int, length: Int) {
        let old = table
        let delimiterChanged = old?.delimiter != new.delimiter
        order = nil
        shownRows = []
        table = new
        tableVersion = version
        tableLength = length
        if let headerChoice {
            usesHeader = headerChoice
        } else if delimiterChanged {
            usesHeader = new.firstRowLooksLikeHeader
        }
        if delimiterChanged, old != nil {
            // Other columns altogether: their widths and the sort mean nothing now.
            sort = .file(ascending: true)
            tableView.sortDescriptors = []
        }
        if let cell = activeCell, cell.row >= new.rowCount { activeCell = nil }
        // The editor colors the columns the table shows.
        document.loadedEditor?.setCSVDelimiter(new.delimiter.rawValue)
        updateColumns(fitAll: delimiterChanged)
        reorder()
        moveToCaret(scroll: true)
    }

    /// The first record shown as a row (the one after the header).
    private var firstRecord: Int { usesHeader ? 1 : 0 }

    var shownRowCount: Int { max(0, (table?.rowCount ?? 0) - firstRecord) }

    /// The columns shown (at most `maxColumns`).
    var shownColumnCount: Int { min(table?.columnCount ?? 0, Self.maxColumns) }

    func record(atShownRow row: Int) -> Int? {
        guard row >= 0, row < shownRowCount else { return nil }
        if let order { return row < order.count ? order[row] : nil }
        return row + firstRecord
    }

    func shownRow(ofRecord record: Int) -> Int? {
        guard let table, record >= firstRecord, record < table.rowCount else { return nil }
        guard order != nil else { return record - firstRecord }
        let row = record < shownRows.count ? Int(shownRows[record]) : -1
        return row >= 0 ? row : nil
    }

    /// Column `column`'s title: its field in the header (empty without one).
    func title(ofColumn column: Int) -> String {
        guard usesHeader, let table else { return "" }
        return Self.flattened(table.value(row: 0, column: column)).trimmingCharacters(in: .whitespaces)
    }

    /// A value on one line: line breaks show as ↵.
    static func flattened(_ value: String) -> String {
        guard value.contains(where: \.isNewline) else { return value }
        return value.replacingOccurrences(of: "\r\n", with: " ↵ ").replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\r", with: " ↵ ")
    }

    // MARK: Columns

    private func updateColumns(fitAll: Bool) {
        guard let table else { return }
        if tableView.tableColumns.isEmpty {
            let line = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
            line.title = ""
            line.sortDescriptorPrototype = NSSortDescriptor(key: "line", ascending: true)
            line.resizingMask = []
            line.headerToolTip = "Line in the file · Click to show the rows in the file’s order"
            tableView.addTableColumn(line)
        }
        let count = shownColumnCount
        var existing = tableView.tableColumns.count - 1
        if fitAll {
            for column in tableView.tableColumns.dropFirst() { tableView.removeTableColumn(column) }
            existing = 0
        }
        if existing > count {
            for column in tableView.tableColumns.suffix(existing - count) { tableView.removeTableColumn(column) }
        }
        let sample = max(10, min(200, 20_000 / max(1, count)))
        for index in 0..<count {
            let title = title(ofColumn: index)
            let name = CSVTable.columnName(index)
            if index >= existing {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
                column.sortDescriptorPrototype = NSSortDescriptor(key: String(index), ascending: true)
                column.minWidth = 28
                column.maxWidth = 5_000
                column.resizingMask = .userResizingMask
                column.title = title.isEmpty ? name : title
                column.width = fittingWidth(ofColumn: index, rows: sample)
                tableView.addTableColumn(column)
            } else {
                tableView.tableColumns[index + 1].title = title.isEmpty ? name : title
            }
            tableView.tableColumns[index + 1].headerToolTip = title.isEmpty ? "Column \(name)" : "Column \(name): \(title)"
        }
        let lastLine = table.rowCount > 0 ? table.line(ofRow: table.rowCount - 1) + 1 : 1
        tableView.tableColumns[0].width = ceil(textWidth(String(lastLine), font: style.font)) + style.padding * 2 + 4
        tableView.headerView?.needsDisplay = true
    }

    /// The width that shows column `column`'s title and the values in its first `rows` records.
    func fittingWidth(ofColumn column: Int, rows: Int) -> CGFloat {
        guard let table else { return 80 }
        let title = title(ofColumn: column)
        var width = textWidth(title.isEmpty ? CSVTable.columnName(column) : title, font: style.headerFont) + 16
        let limit: CGFloat = 340
        for record in firstRecord..<min(table.rowCount, firstRecord + rows) where width < limit {
            let value = table.value(row: record, column: column)
            if !value.isEmpty { width = max(width, textWidth(Self.flattened(value), font: style.font)) }
        }
        return min(max(ceil(width) + style.padding * 2 + 2, 44), limit + style.padding * 2)
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (String(text.prefix(120)) as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: Order

    /// Puts the rows in `sort`'s order and shows them; a large table is sorted off the main thread.
    private func reorder() {
        sortTask?.cancel()
        isSorting = false
        guard let table else { return }
        let records = Array(firstRecord..<max(firstRecord, table.rowCount))
        switch sort {
        case .file(let ascending):
            setOrder(ascending ? nil : records.reversed())
        case .column(let column, let ascending):
            guard records.count >= 20_000 else {
                setOrder(table.sorted(records, byColumn: column, ascending: ascending))
                return
            }
            setOrder(nil)
            isSorting = true
            let sort = self.sort
            sortTask = Task { [weak self] in
                let order = await Task.detached(priority: .userInitiated) { table.sorted(records, byColumn: column, ascending: ascending) }.value
                guard !Task.isCancelled, let self, self.sort == sort, self.table?.rowCount == table.rowCount else { return }
                self.isSorting = false
                self.setOrder(order)
            }
        }
    }

    private func setOrder(_ order: [Int]?) {
        self.order = order
        shownRows = []
        if let order, let table {
            var rows = [Int32](repeating: -1, count: table.rowCount)
            for (shown, record) in order.enumerated() { rows[record] = Int32(shown) }
            shownRows = rows
        }
        tableView.reloadData()
        selectActiveRow(scroll: false)
    }

    /// Shows the rows in the file's order again.
    func clearSort() {
        tableView.sortDescriptors = []
    }

    /// The title of the column the rows are sorted by, and the direction; nil in the file's order.
    var sortSummary: (title: String, ascending: Bool)? {
        guard case .column(let column, let ascending) = sort else { return nil }
        let title = title(ofColumn: column)
        return (title.isEmpty ? CSVTable.columnName(column) : title, ascending)
    }

    // MARK: Header and delimiter

    func setUsesHeader(_ uses: Bool) {
        headerChoice = uses
        remember()
        guard uses != usesHeader, table != nil else { return }
        usesHeader = uses
        order = nil
        shownRows = []
        updateColumns(fitAll: false)
        if uses {
            // Room for the titles.
            for (index, column) in tableView.tableColumns.dropFirst().enumerated() {
                let needed = ceil(textWidth(title(ofColumn: index), font: style.headerFont)) + 16 + style.padding * 2 + 2
                if column.width < needed { column.width = min(needed, 340 + style.padding * 2) }
            }
        }
        reorder()
        selectActiveRow(scroll: true)
    }

    /// Reads the text with `delimiter` (nil: the one it seems to use).
    func choose(_ delimiter: CSVTable.Delimiter?) {
        guard delimiter != chosenDelimiter else { return }
        chosenDelimiter = delimiter
        remember()
        read()
    }

    /// The header and delimiter picked by hand come back when the file is opened again.
    private func remember() {
        guard let path = document.path else { return }
        let header = headerChoice, delimiter = chosenDelimiter?.rawValue
        Workspace.shared.recents.update(path) { item in
            item.csvHeader = header
            item.csvDelimiter = delimiter
        }
    }

    // MARK: Active cell

    /// The editor's caret moved: outline its field (once the table is read from the current text).
    func caretDidMove() {
        guard !isMovingCaret else { return }
        moveToCaret(scroll: true)
    }

    /// Whether the table was read from the text as it is now (so its offsets point at the right places).
    private var isCurrent: Bool {
        tableVersion == textVersion && (document.loadedEditor?.textStorage.length ?? tableLength) == tableLength
    }

    private func moveToCaret(scroll: Bool) {
        guard let table, isCurrent, let cell = table.cell(at: document.selectionLocation) else { return }
        activate(Cell(row: cell.row, column: cell.column), scroll: scroll, moveCaret: false)
    }

    /// Outlines `cell` and selects its row (unless `selectsRow` is off: a click that extended the
    /// selection), and puts the caret on its field when `moveCaret` is set.
    func activate(_ cell: Cell, selectsRow: Bool = true, scroll: Bool, moveCaret: Bool) {
        let old = activeCell
        if old != cell {
            activeCell = cell
            for record in [old?.row, cell.row].compactMap({ $0 }) { redrawRow(ofRecord: record) }
            if old?.column != cell.column { tableView.headerView?.needsDisplay = true }
        }
        if selectsRow { selectActiveRow(scroll: scroll) } else if scroll { scrollToActiveCell() }
        if moveCaret { placeCaret(on: cell) }
    }

    private func selectActiveRow(scroll: Bool) {
        guard let cell = activeCell else { return }
        if let row = shownRow(ofRecord: cell.row) {
            if tableView.selectedRowIndexes != IndexSet(integer: row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else if !tableView.selectedRowIndexes.isEmpty {
            // The header's field: no row to select.
            tableView.deselectAll(nil)
        }
        if scroll { scrollToActiveCell() }
    }

    private func scrollToActiveCell() {
        guard let cell = activeCell else { return }
        if let row = shownRow(ofRecord: cell.row) { tableView.scrollRowToVisible(row) }
        if cell.column + 1 < tableView.numberOfColumns { tableView.scrollColumnToVisible(cell.column + 1) }
    }

    private func redrawRow(ofRecord record: Int) {
        guard let row = shownRow(ofRecord: record), row < tableView.numberOfRows else { return }
        tableView.rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
    }

    /// Selects the cell's field in the editor (inside its quotes), or puts the caret at the end of a
    /// record too short to have it.
    private func placeCaret(on cell: Cell) {
        guard let table, isCurrent, cell.row < table.rowCount else { return }
        let range = table.contentRange(row: cell.row, column: cell.column) ?? NSRange(location: NSMaxRange(table.rowRange(cell.row)), length: 0)
        isMovingCaret = true
        document.select(range)
        isMovingCaret = false
    }

    /// Moves the outline by rows (in the order shown) and columns.
    func moveActiveCell(rows: Int, columns: Int) {
        let count = shownRowCount, width = shownColumnCount
        guard count > 0, width > 0, let first = record(atShownRow: 0) else { return }
        var cell = activeCell ?? Cell(row: first, column: 0)
        cell.column = min(max(cell.column + columns, 0), width - 1)
        if rows != 0 {
            // From the header, down goes to the first row.
            let current = shownRow(ofRecord: cell.row) ?? -1
            cell.row = record(atShownRow: min(max(current + rows, 0), count - 1)) ?? cell.row
        }
        activate(cell, scroll: true, moveCaret: true)
    }

    /// The outlined cell's value, for the bar above the table.
    var activeValue: String? {
        guard let table, let cell = activeCell, cell.row < table.rowCount else { return nil }
        return table.value(row: cell.row, column: cell.column)
    }

    /// The outlined cell's name, `B7`: its column's letters and its line in the file.
    var activeReference: String? {
        guard let table, let cell = activeCell, cell.row < table.rowCount else { return nil }
        return CSVTable.columnName(cell.column) + String(table.line(ofRow: cell.row) + 1)
    }

    /// Goes to the outlined cell's field in the editor, showing the editor first when only the table shows.
    func showActiveCellInEditor() {
        guard let cell = activeCell else { return }
        if document.markdownMode == .preview {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { document.markdownMode = .split }
            Workspace.shared.scheduleSessionSave()
        }
        placeCaret(on: cell)
        if let editor = document.loadedEditor, editor.textView.window != nil { editor.focus() }
    }

    // MARK: Clicks

    @objc private func tableClicked(_ sender: Any?) {
        let row = tableView.clickedRow, column = tableView.clickedColumn
        guard row >= 0, let record = record(atShownRow: row) else { return }
        let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]) ?? []
        let cell = Cell(row: record, column: column > 0 ? column - 1 : (activeCell?.column ?? 0))
        activate(cell, selectsRow: modifiers.isEmpty, scroll: false, moveCaret: true)
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        showActiveCellInEditor()
    }

    func focus() {
        guard let window = tableView.window, window.firstResponder !== tableView else { return }
        window.makeFirstResponder(tableView)
    }

    // MARK: Copying

    /// ⌘C: the outlined cell's value, or the selected rows (tab-separated, for pasting into a
    /// spreadsheet) when several are selected.
    func copySelection() {
        let rows = tableView.selectedRowIndexes
        if rows.count > 1 {
            copyRows(rows)
        } else if let value = activeValue {
            copy(value)
        }
    }

    private func copyRows(_ rows: IndexSet) {
        guard let table else { return }
        let lines = rows.compactMap { record(atShownRow: $0) }.map { record in
            (0..<shownColumnCount).map { CSVTable.field(table.value(row: record, column: $0), delimiter: .tab) }.joined(separator: "\t")
        }
        copy(lines.joined(separator: "\n"))
        Workspace.shared.toast(lines.count == 1 ? "Copied the row" : "Copied \(lines.count) rows", symbol: "doc.on.doc")
    }

    private func copyColumn(_ column: Int) {
        guard let table else { return }
        let values = (firstRecord..<table.rowCount).map { record(atShownRow: $0 - firstRecord) ?? $0 }.map { table.value(row: $0, column: column) }
        copy(values.joined(separator: "\n"))
        let title = title(ofColumn: column)
        Workspace.shared.toast("Copied \(title.isEmpty ? "column \(CSVTable.columnName(column))" : "“\(title)”")", symbol: "doc.on.doc")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Appearance

    func applyTheme() {
        let settings = AppSettings.shared
        let theme = settings.theme
        let oldSize = style.font.pointSize
        style = CSVTableStyle(theme: theme, fontSize: settings.fontSize)
        scrollView.backgroundColor = style.background
        scrollView.scrollerKnobStyle = theme.isDark ? .light : .dark
        scrollView.appearance = theme.appearance
        tableView.backgroundColor = style.background
        tableView.rowHeight = style.rowHeight
        if let header = tableView.headerView, header.frame.height != style.headerHeight {
            header.frame.size.height = style.headerHeight
            scrollView.tile()
        }
        // Text got bigger or smaller: so do the columns.
        if oldSize != style.font.pointSize, oldSize > 0, table != nil {
            let scale = style.font.pointSize / oldSize
            for column in tableView.tableColumns.dropFirst() { column.width = (column.width * scale).rounded() }
            if let table {
                let lastLine = table.rowCount > 0 ? table.line(ofRow: table.rowCount - 1) + 1 : 1
                tableView.tableColumns.first?.width = ceil(textWidth(String(lastLine), font: style.font)) + style.padding * 2 + 4
            }
        }
        tableView.enumerateAvailableRowViews { view, _ in view.needsDisplay = true }
        tableView.headerView?.needsDisplay = true
    }

    // MARK: Drawing

    /// Draws row `row` (in the order shown): its line number, its fields, the grid and the outline.
    func drawRow(_ row: Int, in view: NSView, dirtyRect: NSRect) {
        guard let table, let record = record(atShownRow: row) else { return }
        let height = view.bounds.height
        let isActiveRow = activeCell?.row == record
        let lineHeight = ceil(style.font.ascender - style.font.descender)
        let textY = ((height - lineHeight) / 2).rounded()
        let columns = tableView.columnIndexes(in: NSRect(x: dirtyRect.minX, y: tableView.rect(ofRow: row).minY, width: max(dirtyRect.width, 1), height: 1))
        for index in columns {
            let rect = tableView.rect(ofColumn: index)
            let cellRect = NSRect(x: rect.minX, y: 0, width: rect.width, height: height)
            let textRect = NSRect(x: cellRect.minX + style.padding, y: textY, width: max(0, cellRect.width - style.padding * 2), height: lineHeight)
            if index == 0 {
                style.gutterBackground.setFill()
                cellRect.fill()
                let attributes = isActiveRow ? style.activeLineAttributes : style.lineAttributes
                (String(table.line(ofRow: record) + 1) as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
            } else {
                let value = table.value(row: record, column: index - 1)
                if !value.isEmpty {
                    let shown = Self.flattened(value.count > 400 ? String(value.prefix(400)) : value)
                    let attributes = CSVTable.number(value) != nil ? style.numberAttributes : style.textAttributes
                    (shown as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
                }
            }
            style.grid.setFill()
            NSRect(x: cellRect.maxX - 1, y: 0, width: 1, height: height).fill()
        }
        style.grid.setFill()
        NSRect(x: dirtyRect.minX, y: height - 1, width: dirtyRect.width, height: 1).fill()
        if isActiveRow, let cell = activeCell, cell.column + 1 < tableView.numberOfColumns {
            let rect = tableView.rect(ofColumn: cell.column + 1)
            let outline = NSRect(x: rect.minX, y: 0, width: rect.width, height: height).insetBy(dx: 1, dy: 1)
            style.accent.withAlphaComponent(0.10).setFill()
            outline.fill()
            let path = NSBezierPath(rect: outline.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 2
            style.accent.setStroke()
            path.stroke()
        }
    }

    /// Draws the column titles, the outlined cell's column highlighted and the sorted one's arrow.
    func drawHeader(in view: NSTableHeaderView, dirtyRect: NSRect) {
        style.headerBackground.setFill()
        dirtyRect.fill()
        let height = view.bounds.height
        let lineHeight = ceil(style.headerFont.ascender - style.headerFont.descender)
        let textY = ((height - lineHeight) / 2).rounded()
        for index in tableView.columnIndexes(in: NSRect(x: dirtyRect.minX, y: 0, width: max(dirtyRect.width, 1), height: 1)) {
            let rect = view.headerRect(ofColumn: index)
            if index > 0, activeCell?.column == index - 1 {
                style.activeHeaderBackground.setFill()
                rect.fill()
            }
            var textRect = NSRect(x: rect.minX + style.padding, y: textY, width: max(0, rect.width - style.padding * 2), height: lineHeight)
            if let ascending = sortDirection(ofColumn: index) {
                let size: CGFloat = 9
                let symbol = NSImage(systemSymbolName: ascending ? "chevron.up" : "chevron.down", accessibilityDescription: ascending ? "Ascending" : "Descending")?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .bold).applying(.init(paletteColors: [style.accent])))
                if let symbol {
                    let imageRect = NSRect(x: rect.maxX - style.padding - symbol.size.width, y: ((height - symbol.size.height) / 2).rounded(), width: symbol.size.width, height: symbol.size.height)
                    symbol.draw(in: imageRect)
                    textRect.size.width = max(0, imageRect.minX - 4 - textRect.minX)
                }
            }
            if index == 0 {
                ("#" as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: style.lineAttributes)
            } else {
                let column = index - 1
                let title = title(ofColumn: column)
                let attributes = title.isEmpty ? style.headerPlaceholderAttributes : style.headerAttributes(column: column)
                ((title.isEmpty ? CSVTable.columnName(column) : title) as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
            }
            style.grid.setFill()
            NSRect(x: rect.maxX - 1, y: 0, width: 1, height: height).fill()
        }
        style.grid.setFill()
        NSRect(x: dirtyRect.minX, y: height - 1, width: dirtyRect.width, height: 1).fill()
    }

    /// Whether the rows are sorted by table column `index` (0 is the line column), and which way.
    private func sortDirection(ofColumn index: Int) -> Bool? {
        switch sort {
        case .file(let ascending): index == 0 && !ascending ? false : nil
        case .column(let column, let ascending): column == index - 1 ? ascending : nil
        }
    }

    func tearDown() {
        readTask?.cancel()
        sortTask?.cancel()
        scrollView.removeFromSuperview()
    }
}

// MARK: - Table view data source and delegate

extension CSVPreviewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { shownRowCount }

    /// No views for the cells: each row view draws its own (`drawRow`), which keeps scrolling cheap.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: CSVRowView.reuseIdentifier, owner: nil) as? CSVRowView ?? CSVRowView()
        view.identifier = CSVRowView.reuseIdentifier
        view.controller = self
        view.row = row
        view.needsDisplay = true
        return view
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        if let descriptor = tableView.sortDescriptors.first, let key = descriptor.key {
            sort = key == "line" ? .file(ascending: descriptor.ascending) : .column(Int(key) ?? 0, ascending: descriptor.ascending)
        } else {
            sort = .file(ascending: true)
        }
        tableView.headerView?.needsDisplay = true
        reorder()
        if let cell = activeCell, let row = shownRow(ofRecord: cell.row) { tableView.scrollRowToVisible(row) }
    }

    /// Double-clicking a column's edge fits it to its values.
    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
        column == 0 ? tableView.tableColumns[0].width : fittingWidth(ofColumn: column - 1, rows: 2_000)
    }
}

// MARK: - Context menu

extension CSVPreviewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow, column = tableView.clickedColumn
        if row >= 0, let record = record(atShownRow: row) {
            let cell = Cell(row: record, column: column > 0 ? column - 1 : (activeCell?.column ?? 0))
            if column > 0 {
                menu.addItem(actionItem("Copy Cell") { [weak self] in
                    guard let self, let table = self.table else { return }
                    self.copy(table.value(row: cell.row, column: cell.column))
                })
            }
            let selection = tableView.selectedRowIndexes.contains(row) ? tableView.selectedRowIndexes : IndexSet(integer: row)
            menu.addItem(actionItem(selection.count > 1 ? "Copy \(selection.count) Rows" : "Copy Row") { [weak self] in self?.copyRows(selection) })
            if column > 0 {
                menu.addItem(actionItem("Copy Column") { [weak self] in self?.copyColumn(cell.column) })
            }
            menu.addItem(.separator())
            menu.addItem(actionItem("Show in Editor") { [weak self] in
                self?.activate(cell, scroll: false, moveCaret: true)
                self?.showActiveCellInEditor()
            })
            menu.addItem(.separator())
        }
        let header = actionItem("Use First Row as Header") { [weak self] in
            guard let self else { return }
            self.setUsesHeader(!self.usesHeader)
        }
        header.state = usesHeader ? .on : .off
        menu.addItem(header)
        if sortSummary != nil {
            menu.addItem(actionItem("Show in File Order") { [weak self] in self?.clearSort() })
        }
    }
}

/// A menu item that runs a closure (the item keeps its target alive).
private func actionItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(handler)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
    item.target = action
    item.representedObject = action
    return item
}

private final class MenuAction: NSObject {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}

// MARK: - Views

/// The table: keys move the outlined cell, and only the focused pane's table takes the keyboard (see
/// `EditorHost.isInFocusedPane`).
final class CSVTableView: NSTableView {
    weak var controller: CSVPreviewController?

    override var acceptsFirstResponder: Bool {
        guard let document = controller?.document else { return super.acceptsFirstResponder }
        return Workspace.shared.acceptsKeyboardFocus(document)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let document = controller?.document { Workspace.shared.documentDidTakeFocus(document) }
        return became
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.specialKey, modifiers) {
        case (.leftArrow?, []): controller.moveActiveCell(rows: 0, columns: -1)
        case (.rightArrow?, []), (.tab?, []): controller.moveActiveCell(rows: 0, columns: 1)
        case (.backTab?, _): controller.moveActiveCell(rows: 0, columns: -1)
        case (.upArrow?, []): controller.moveActiveCell(rows: -1, columns: 0)
        case (.downArrow?, []): controller.moveActiveCell(rows: 1, columns: 0)
        case (.upArrow?, [.command]): controller.moveActiveCell(rows: -Int(Int32.max), columns: 0)
        case (.downArrow?, [.command]): controller.moveActiveCell(rows: Int(Int32.max), columns: 0)
        case (.leftArrow?, [.command]): controller.moveActiveCell(rows: 0, columns: -Int(Int32.max))
        case (.rightArrow?, [.command]): controller.moveActiveCell(rows: 0, columns: Int(Int32.max))
        case (.carriageReturn?, []), (.enter?, []): controller.showActiveCellInEditor()
        default: super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        controller?.copySelection()
    }
}

/// One row of the table. It draws its cells itself (see `CSVPreviewController.drawRow`), in the
/// theme's colors.
final class CSVRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("CSVRow")
    weak var controller: CSVPreviewController?
    var row = -1

    override var isFlipped: Bool { true }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let style = controller?.style else { return super.drawBackground(in: dirtyRect) }
        (row % 2 == 1 ? style.stripe : style.background).setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let style = controller?.style else { return super.drawSelection(in: dirtyRect) }
        style.selection.setFill()
        dirtyRect.fill()
    }

    override func drawSeparator(in dirtyRect: NSRect) {}

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        controller?.drawRow(row, in: self, dirtyRect: dirtyRect)
    }
}

/// The column titles, drawn in the theme's colors (see `CSVPreviewController.drawHeader`).
final class CSVHeaderView: NSTableHeaderView {
    weak var controller: CSVPreviewController?

    override func draw(_ dirtyRect: NSRect) {
        guard let controller else { return super.draw(dirtyRect) }
        controller.drawHeader(in: self, dirtyRect: dirtyRect)
    }
}

/// Colors, fonts and sizes of the table, from the editor's theme and font size.
struct CSVTableStyle {
    var font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    var headerFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    var background = NSColor.textBackgroundColor
    var stripe = NSColor.textBackgroundColor
    var headerBackground = NSColor.windowBackgroundColor
    var activeHeaderBackground = NSColor.selectedContentBackgroundColor
    var gutterBackground = NSColor.windowBackgroundColor
    var grid = NSColor.gridColor
    var selection = NSColor.selectedContentBackgroundColor
    var accent = NSColor.controlAccentColor
    var rowHeight: CGFloat = 22
    var headerHeight: CGFloat = 26
    let padding: CGFloat = 7
    private(set) var textAttributes: [NSAttributedString.Key: Any] = [:]
    private(set) var numberAttributes: [NSAttributedString.Key: Any] = [:]
    private(set) var lineAttributes: [NSAttributedString.Key: Any] = [:]
    private(set) var activeLineAttributes: [NSAttributedString.Key: Any] = [:]
    private(set) var headerPlaceholderAttributes: [NSAttributedString.Key: Any] = [:]
    private var headerColors: [NSColor] = []
    private var headerParagraph = NSParagraphStyle()

    init() {}

    init(theme: Theme, fontSize: Double) {
        let size = CGFloat(max(9, fontSize - 0.5))
        font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        headerFont = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let bg = theme.background
        background = bg.nsColor
        stripe = theme.foreground.withAlpha(theme.isDark ? 0.035 : 0.03).flattened(over: bg).nsColor
        headerBackground = theme.chromeBackground.nsColor
        gutterBackground = theme.chromeBackground.mixed(with: bg, 0.35).nsColor
        activeHeaderBackground = theme.accent.withAlpha(theme.isDark ? 0.22 : 0.16).flattened(over: theme.chromeBackground).nsColor
        grid = theme.foreground.withAlpha(theme.isDark ? 0.11 : 0.10).nsColor
        selection = theme.selection.withAlpha(1).mixed(with: bg, theme.isDark ? 0.45 : 0.5).nsColor
        accent = theme.accent.nsColor
        let line = ceil(font.ascender - font.descender + font.leading)
        rowHeight = line + 8
        headerHeight = line + 10

        let left = NSMutableParagraphStyle()
        left.lineBreakMode = .byTruncatingTail
        let right = NSMutableParagraphStyle()
        right.lineBreakMode = .byTruncatingTail
        right.alignment = .right
        headerParagraph = left
        textAttributes = [.font: font, .foregroundColor: theme.foreground.nsColor, .paragraphStyle: left]
        numberAttributes = [.font: font, .foregroundColor: theme.foreground.nsColor, .paragraphStyle: right]
        lineAttributes = [.font: font, .foregroundColor: theme.gutterForeground.nsColor, .paragraphStyle: right]
        activeLineAttributes = [.font: font, .foregroundColor: theme.gutterActiveForeground.nsColor, .paragraphStyle: right]
        headerPlaceholderAttributes = [.font: font, .foregroundColor: theme.mutedForeground.nsColor, .paragraphStyle: left]
        // Titles in the colors the editor gives their columns.
        headerColors = TokenKind.rainbow.map { (theme.style(for: $0)?.color ?? theme.foreground).nsColor }
    }

    func headerAttributes(column: Int) -> [NSAttributedString.Key: Any] {
        let color = headerColors.isEmpty ? NSColor.labelColor : headerColors[column % headerColors.count]
        return [.font: headerFont, .foregroundColor: color, .paragraphStyle: headerParagraph]
    }
}
