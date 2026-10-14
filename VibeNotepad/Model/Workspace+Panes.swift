import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeCore

/// Where a dragged tab lands on a pane: in it, or in a new pane on one of its sides.
enum PaneDropZone: Equatable {
    case center, left, right, top, bottom
}

/// The pane (and the part of it) a tab being dragged would land on, highlighted while it's over it.
struct PaneDropTarget: Equatable {
    let pane: UUID
    let zone: PaneDropZone
}

/// The editor area split into up to four panes, each showing a different document (a document has
/// a single editor view). The focused pane follows the tab selection: picking a tab shows it there,
/// or moves the focus to the pane already showing it.
extension Workspace {
    static let maxPanes = 4

    var paneCount: Int { paneLayout.paneCount }
    var isSplit: Bool { paneLayout.paneCount > 1 }

    func document(inPane pane: UUID) -> EditorDocument? {
        guard let id = paneDocuments[pane] else { return nil }
        return documents.first { $0.id == id }
    }

    func pane(showing document: UUID) -> UUID? {
        paneDocuments.first { $0.value == document }?.key
    }

    func isShownInPane(_ document: EditorDocument) -> Bool {
        paneDocuments.values.contains(document.id)
    }

    /// Called whenever the selected tab changes.
    func showSelectionInPanes() {
        guard let id = selectedID else { return }
        if let pane = pane(showing: id) {
            if pane != focusedPaneID { focusedPaneID = pane }
        } else {
            paneDocuments[focusedPaneID] = id
        }
        documentHistory.removeAll { $0 == id }
        documentHistory.insert(id, at: 0)
    }

    // MARK: Focus

    /// Moves the focus to `pane`, and the tab selection to what it shows. With `focusEditor`, the
    /// keyboard goes to its editor too (a click in the pane puts it in the right place itself).
    func focusPane(_ pane: UUID, focusEditor: Bool = false) {
        guard paneLayout.contains(pane) else { return }
        // Before the selection changes, so the selected document is found in the focused pane.
        if focusedPaneID != pane { focusedPaneID = pane }
        let document = paneDocuments[pane]
        if selectedID != document { selectedID = document }
        guard focusEditor, palette == nil else { return }
        if let editor = selectedDocument?.loadedEditor, !findBarVisible {
            editor.focus()
        } else if let viewer = selectedDocument?.loadedImageViewer {
            viewer.focus()
        } else if selectedDocument == nil {
            // An empty pane: typing must not go on in the pane that had the focus.
            mainWindow?.makeFirstResponder(nil)
        }
    }

    func focusPane(toward direction: PaneDirection) {
        guard let pane = paneLayout.neighbor(of: focusedPaneID, toward: direction) else {
            NSSound.beep()
            return
        }
        focusPane(pane, focusEditor: true)
    }

    /// Focuses the next pane in reading order (back to the first after the last).
    func focusNextPane(forward: Bool = true) {
        let panes = paneLayout.paneIDs
        guard panes.count > 1, let index = panes.firstIndex(of: focusedPaneID) else { return }
        focusPane(panes[(index + (forward ? 1 : -1) + panes.count) % panes.count], focusEditor: true)
    }

    /// Whether `document`'s editor or preview may take the keyboard: when it's in the focused pane (or
    /// the editor isn't split, or it isn't in a pane).
    func acceptsKeyboardFocus(_ document: EditorDocument) -> Bool {
        !isSplit || paneDocuments[focusedPaneID] == document.id || pane(showing: document.id) == nil
    }

    /// The document's editor took the keyboard (clicked, or tabbed into): its pane gets the focus.
    func documentDidTakeFocus(_ document: EditorDocument) {
        guard let pane = pane(showing: document.id), pane != focusedPaneID else { return }
        focusPane(pane)
    }

    /// Clicking anywhere in a pane (the text, its gutter or minimap, a preview, its header) focuses it.
    func installPaneFocus(on window: NSWindow) {
        guard paneClickMonitor == nil else { return }
        paneClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            Workspace.shared.paneClicked(event)
            return event
        }
    }

    func paneClicked(_ event: NSEvent) {
        guard isSplit, let window = windowReference, event.window === window, window.attachedSheet == nil,
              let content = window.contentView else { return }
        var point = content.convert(event.locationInWindow, from: nil)
        if !content.isFlipped { point.y = content.bounds.height - point.y }
        guard let pane = paneLayout.paneIDs.first(where: { paneFrames[$0]?.contains(point) == true }), pane != focusedPaneID else { return }
        focusPane(pane)
    }

    // MARK: Splitting

    /// Splits `pane` (the focused one by default) along `axis`; the new pane goes after it (right or
    /// below) or `before` it, and takes the focus. It shows `document` (taken from the pane showing it,
    /// if any), or the most recently shown document that isn't on screen.
    func splitPane(_ axis: SplitAxis, pane: UUID? = nil, showing document: EditorDocument? = nil, before: Bool = false) {
        let target = pane ?? focusedPaneID
        guard paneLayout.contains(target) else { return }
        guard paneCount < Self.maxPanes else {
            toast("Up to \(Self.maxPanes) panes", symbol: "rectangle.split.2x2", tint: .orange)
            return
        }
        let newPane = UUID()
        paneLayout = paneLayout.splitting(target, axis: axis, newPane: newPane, before: before)
        if let document {
            if let other = self.pane(showing: document.id) {
                paneDocuments[other] = hiddenDocument(excluding: document.id)?.id
            }
            paneDocuments[newPane] = document.id
        } else {
            paneDocuments[newPane] = hiddenDocument()?.id
        }
        focusPane(newPane, focusEditor: true)
        scheduleSessionSave()
    }

    /// Closes `pane` (the focused one by default). What it showed stays open in its tab.
    func closePane(_ pane: UUID? = nil) {
        let target = pane ?? focusedPaneID
        guard let layout = paneLayout.removing(target) else { return }
        let heir = paneLayout.sibling(of: target)
        paneLayout = layout
        paneDocuments[target] = nil
        paneFrames[target] = nil
        if focusedPaneID == target, let heir { focusPane(heir, focusEditor: true) }
        fillLonePane()
        scheduleSessionSave()
    }

    /// Back to a single pane, keeping the focused one.
    func closeOtherPanes() {
        guard isSplit else { return }
        paneLayout = .pane(focusedPaneID)
        paneDocuments = paneDocuments.filter { $0.key == focusedPaneID }
        paneFrames = paneFrames.filter { $0.key == focusedPaneID }
        fillLonePane()
        scheduleSessionSave()
    }

    /// Rearranges the panes as `preset`. They show what's on screen now (the focused pane's document
    /// first), then recently shown documents.
    func applyLayout(_ preset: PaneLayout.Preset) {
        guard preset != .single else {
            closeOtherPanes()
            return
        }
        var order: [UUID] = []
        func add(_ id: UUID?) {
            guard let id, !order.contains(id), documents.contains(where: { $0.id == id }) else { return }
            order.append(id)
        }
        add(paneDocuments[focusedPaneID])
        paneLayout.paneIDs.forEach { add(paneDocuments[$0]) }
        documentHistory.forEach(add)
        documents.forEach { add($0.id) }
        // The focused pane stays (and stays first), so its editor isn't rebuilt.
        let panes = [focusedPaneID] + (1..<preset.paneCount).map { _ in UUID() }
        paneLayout = .preset(preset, panes: panes)
        paneDocuments = [:]
        for (pane, document) in zip(panes, order) { paneDocuments[pane] = document }
        paneFrames = paneFrames.filter { $0.key == focusedPaneID }
        focusPane(focusedPaneID, focusEditor: true)
        scheduleSessionSave()
    }

    /// Sets the share of the space a split gives its first part (dragging its divider).
    func setPaneRatio(_ ratio: Double, of split: UUID) {
        let layout = paneLayout.settingRatio(ratio, of: split)
        if layout != paneLayout { paneLayout = layout }
    }

    /// Gives every pane along the split the same room (double-clicking its divider).
    func equalizeSplit(_ split: UUID) {
        guard let ratio = paneLayout.equalRatio(of: split) else { return }
        withAnimation(.snappy(duration: 0.25)) { setPaneRatio(ratio, of: split) }
        scheduleSessionSave()
    }

    // MARK: Moving documents

    /// Shows `document` in `pane`. When another pane shows it, that pane gets what `pane` showed
    /// (the two swap), or another document that isn't on screen.
    func show(_ document: EditorDocument, inPane pane: UUID) {
        guard paneLayout.contains(pane) else { return }
        let previous = paneDocuments[pane]
        if let other = self.pane(showing: document.id) {
            guard other != pane else {
                focusPane(pane, focusEditor: true)
                return
            }
            paneDocuments[other] = previous ?? hiddenDocument(excluding: document.id)?.id
        }
        paneDocuments[pane] = document.id
        focusPane(pane, focusEditor: true)
        scheduleSessionSave()
    }

    /// A tab dropped on a pane: shown in it, or in a new pane on the side it was dropped on.
    func dropTab(_ id: UUID, on pane: UUID, zone: PaneDropZone) {
        lastTabDrop = Date()
        setPaneDropTarget(nil)
        guard let document = documents.first(where: { $0.id == id }) else { return }
        switch zone {
        case .center: show(document, inPane: pane)
        case .left: splitPane(.horizontal, pane: pane, showing: document, before: true)
        case .right: splitPane(.horizontal, pane: pane, showing: document)
        case .top: splitPane(.vertical, pane: pane, showing: document, before: true)
        case .bottom: splitPane(.vertical, pane: pane, showing: document)
        }
    }

    /// Where a tab dropped at `point` in a pane of `size` goes: a side within a quarter of the pane's
    /// width (or height) of it (while there's room for another pane), otherwise the pane itself.
    func dropZone(at point: CGPoint, in size: CGSize) -> PaneDropZone {
        guard paneCount < Self.maxPanes, size.width > 0, size.height > 0 else { return .center }
        let distances: [(PaneDropZone, CGFloat)] = [
            (.left, point.x / size.width), (.right, 1 - point.x / size.width),
            (.top, point.y / size.height), (.bottom, 1 - point.y / size.height),
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < 0.25 else { return .center }
        return nearest.0
    }

    func setPaneDropTarget(_ target: PaneDropTarget?) {
        guard paneDropTarget != target else { return }
        withAnimation(.snappy(duration: 0.18)) { paneDropTarget = target }
    }

    // MARK: Tabs dragged over editors and previews

    // AppKit hands a drag to the view under the pointer that takes one of its types. A dragged tab also
    // carries file promises, which the editors and previews take, so they pass tab drags on to these.

    static let tabPasteboardType = NSPasteboard.PasteboardType(UTType.vibeNotepadTab.identifier)

    func isTabDrag(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.types?.contains(Self.tabPasteboardType) == true
    }

    /// A tab dragged over `document`'s editor or preview: highlights where it would land.
    func tabDragMoved(_ info: NSDraggingInfo, over document: EditorDocument) -> NSDragOperation {
        guard let target = dropTarget(info, over: document) else { return [] }
        setPaneDropTarget(target)
        return .move
    }

    func tabDragLeft(_ document: EditorDocument) {
        if let target = paneDropTarget, target.pane == pane(showing: document.id) { setPaneDropTarget(nil) }
    }

    func tabDropped(_ info: NSDraggingInfo, on document: EditorDocument) -> Bool {
        defer { setPaneDropTarget(nil) }
        guard let target = dropTarget(info, over: document), let data = info.draggingPasteboard.data(forType: Self.tabPasteboardType),
              let item = try? JSONDecoder().decode(TabDragItem.self, from: data) else { return false }
        dropTab(item.id, on: target.pane, zone: target.zone)
        return true
    }

    /// Where a tab dragged over `document`'s editor or preview would land.
    private func dropTarget(_ info: NSDraggingInfo, over document: EditorDocument) -> PaneDropTarget? {
        guard let pane = pane(showing: document.id), let frame = paneFrames[pane], let content = windowReference?.contentView else { return nil }
        var point = content.convert(info.draggingLocation, from: nil)
        if !content.isFlipped { point.y = content.bounds.height - point.y }
        return PaneDropTarget(pane: pane, zone: dropZone(at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY), in: frame.size))
    }

    /// Opens the file at `url` in a new pane beside the focused one.
    func openInNewPane(_ url: URL, axis: SplitAxis) {
        guard paneCount < Self.maxPanes else {
            open(url: url)
            return
        }
        guard let document = open(url: url, select: false) else { return }
        splitPane(axis, showing: document)
    }

    /// The document `pane` showed was closed: it shows the nearest tab that isn't on screen. When
    /// there's none it closes, or shows nothing as the only pane.
    func paneLostDocument(_ pane: UUID, near index: Int) {
        paneDocuments[pane] = nil
        let hidden = documents.indices.filter { !isShownInPane(documents[$0]) }
        // The tab that took the closed one's place, then the one before it, and outwards.
        let nearest = hidden.min { a, b in
            let da = a >= index ? 2 * (a - index) : 2 * (index - a) - 1
            let db = b >= index ? 2 * (b - index) : 2 * (index - b) - 1
            return da < db
        }
        if let nearest {
            if pane == focusedPaneID { selectedID = documents[nearest].id } else { paneDocuments[pane] = documents[nearest].id }
        } else if isSplit {
            closePane(pane)
        } else if pane == focusedPaneID {
            selectedID = nil
        }
    }

    /// The most recently shown document that no pane shows.
    func hiddenDocument(excluding excluded: UUID? = nil) -> EditorDocument? {
        let shown = Set(paneDocuments.values)
        for id in documentHistory where id != excluded && !shown.contains(id) {
            if let document = documents.first(where: { $0.id == id }) { return document }
        }
        return documents.first { $0.id != excluded && !shown.contains($0.id) }
    }

    /// A single pane left without a document shows one, when there is one.
    private func fillLonePane() {
        guard !isSplit, paneDocuments[focusedPaneID] == nil, let document = hiddenDocument() else { return }
        selectedID = document.id
    }
}

extension PaneLayout.Preset {
    var symbol: String {
        switch self {
        case .single: "rectangle"
        case .twoColumns: "rectangle.split.2x1"
        case .twoRows: "rectangle.split.1x2"
        case .threeColumns: "rectangle.split.3x1"
        case .mainAndTwo: "rectangle.leadinghalf.inset.filled"
        case .grid: "rectangle.split.2x2"
        }
    }
}
