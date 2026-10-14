import AppKit
import Observation

/// Shows an image document: zoom (pinch, ⌘+ / ⌘−, actual size, fit to the pane), scrolling and
/// dragging the picture around, and what the status bar and info panel say about it. Images open
/// read-only; the file is reloaded when another app changes it. SVG previews use it too, fed vector
/// pictures by `SVGPreviewController` instead of reading the file.
@Observable
final class ImageViewerController {
    enum State: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// Zoom In / Zoom Out step through these (1 is actual size).
    static let zoomSteps: [CGFloat] = [0.02, 0.05, 0.1, 0.125, 0.25, 1 / 3, 0.5, 2 / 3, 0.75, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32]
    static let maximumZoom: CGFloat = 32
    /// From this zoom on, pixels show as sharp squares instead of being smoothed.
    static let pixelatedZoom: CGFloat = 2

    @ObservationIgnored weak var document: EditorDocument?
    @ObservationIgnored let scrollView: ImageScrollView
    @ObservationIgnored let canvas: ImageCanvasView
    /// Shows the document's file (an image), rather than what it's handed (an SVG preview).
    @ObservationIgnored private let loadsFile: Bool
    private(set) var state: State = .loading
    private(set) var details: ImageDetails?
    /// A vector picture (an SVG preview): sharp at any zoom, and fitting the pane may enlarge it.
    private(set) var isVector = false
    /// Why the latest version couldn't be shown (an SVG with a mistake); the last good one stays.
    private(set) var renderError: String?
    /// Screen points per image point (1 is actual size).
    private(set) var zoom: CGFloat = 1
    /// The whole picture shows and follows the pane's size (never enlarged past actual size).
    private(set) var fitsPane = true
    @ObservationIgnored private(set) var image: NSImage?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var boundsObserver: NSObjectProtocol?

    init(document: EditorDocument, loadsFile: Bool = true) {
        self.document = document
        self.loadsFile = loadsFile
        let scroll = ImageScrollView()
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = Self.zoomSteps[0]
        scroll.maxMagnification = Self.maximumZoom
        scroll.borderType = .noBorder
        let canvas = ImageCanvasView()
        scroll.documentView = canvas
        scrollView = scroll
        self.canvas = canvas
        canvas.controller = self
        scroll.controller = self
        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.magnificationDidChange() }
        }
        applyTheme()
        load()
    }

    // MARK: Loading

    /// Reads and decodes the file off the main thread, then shows it. Called again when the file
    /// changes on disk: the zoom stays, unless the picture follows the pane's size.
    func load() {
        guard loadsFile, let url = document?.fileURL else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<LoadedImage, ImageLoadError> in
                do {
                    let data = try Data(contentsOf: url.resolvingSymlinksInPath())
                    let details = ImageDetails.read(data: data, url: url)
                    // Animations play from the file's frames (see `ImageCanvasView`).
                    let decoded = details?.isAnimated == true ? nil : ImageFile.decode(data)
                    return .success(LoadedImage(data: data, details: details, decoded: decoded))
                } catch {
                    return .failure(ImageLoadError(message: error.localizedDescription))
                }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.show(result)
        }
    }

    private func show(_ result: Result<LoadedImage, ImageLoadError>) {
        switch result {
        case .failure(let error):
            state = .failed(error.message)
        case .success(let loaded):
            let details = loaded.details
            let animated = details?.isAnimated ?? false
            // The NSImage gives the size at 100% (pixels at the file's resolution, upright) and plays
            // animations; the decoded picture is what shows.
            guard let image = NSImage(data: loaded.data), image.isValid, image.size.width > 0, image.size.height > 0,
                  let picture = loaded.decoded ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.details = details
                state = .failed("macOS can’t display this kind of image.")
                return
            }
            self.image = image
            self.details = details
            canvas.show(picture, size: image.size, animation: animated ? image : nil, hasAlpha: details?.hasAlpha ?? true)
            state = .loaded
            if fitsPane { fitToPane() } else { magnificationDidChange() }
        }
    }

    /// Shows a vector picture (an SVG preview's latest render). The zoom stays, unless the picture
    /// follows the pane's size.
    func showVector(_ picture: NSImage, details: ImageDetails) {
        image = picture
        self.details = details
        isVector = true
        renderError = nil
        canvas.showVector(picture)
        state = .loaded
        if fitsPane { fitToPane() } else { magnificationDidChange() }
    }

    /// The latest version can't be shown: says why, over the last good one (if any).
    func showRenderError(_ message: String) {
        renderError = message
        if image == nil { state = .failed(message) }
    }

    // MARK: Zoom

    func zoomIn() {
        setZoom(Self.zoomSteps.first { $0 > zoom * 1.01 } ?? Self.maximumZoom)
    }

    func zoomOut() {
        setZoom(Self.zoomSteps.last { $0 < zoom / 1.01 } ?? scrollView.minMagnification)
    }

    func actualSize() {
        setZoom(1)
    }

    func zoomToFit() {
        fitsPane = true
        fitToPane()
    }

    /// Sets the zoom, keeping `point` (in the picture's coordinates; the middle of what shows by
    /// default) where it is.
    func setZoom(_ value: CGFloat, centeredAt point: NSPoint? = nil) {
        guard image != nil else { return }
        fitsPane = false
        let clip = scrollView.contentView
        let center = point ?? NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        scrollView.setMagnification(min(Self.maximumZoom, max(scrollView.minMagnification, value)), centeredAt: center)
        magnificationDidChange()
    }

    /// Double-click: zooms in around the click (to actual size, or 200% for a picture that already
    /// shows at actual size), or back to fitting the pane.
    func toggleZoom(at point: NSPoint) {
        if fitsPane {
            setZoom(zoom < 0.999 ? 1 : 2, centeredAt: point)
        } else {
            zoomToFit()
        }
    }

    /// The user pinched or double-tapped the trackpad: the zoom is theirs now.
    func userWillMagnify() {
        fitsPane = false
    }

    /// Shows the whole picture: at actual size at most, unless it's a vector one.
    func fitToPane() {
        guard fitsPane, let image else { return }
        let viewport = scrollView.contentSize
        guard viewport.width > 1, viewport.height > 1 else { return }
        let fit = min(isVector ? Self.maximumZoom : 1, viewport.width / image.size.width, viewport.height / image.size.height)
        scrollView.minMagnification = min(Self.zoomSteps[0], fit)
        if abs(scrollView.magnification - fit) > 0.0001 { scrollView.magnification = fit }
        magnificationDidChange()
    }

    private func magnificationDidChange() {
        let magnification = scrollView.magnification
        if abs(magnification - zoom) > 0.0001 { zoom = magnification }
        canvas.zoomDidChange(magnification)
    }

    // MARK: Other

    /// Follows the theme and the image background setting.
    func applyTheme() {
        let settings = AppSettings.shared
        let theme = settings.theme
        scrollView.backgroundColor = theme.background.nsColor
        scrollView.drawsBackground = true
        scrollView.scrollerKnobStyle = theme.isDark ? .light : .dark
        scrollView.appearance = theme.appearance
        canvas.setBackdrop(settings.imageBackground, isDark: theme.isDark)
    }

    func focus() {
        guard let window = canvas.window, window.firstResponder !== canvas else { return }
        window.makeFirstResponder(canvas)
    }

    /// Puts the picture on the clipboard.
    func copyImage() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        Workspace.shared.toast("Copied image", symbol: "photo.on.rectangle")
    }

    func tearDown() {
        loadTask?.cancel()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        scrollView.removeFromSuperview()
    }
}

nonisolated struct ImageLoadError: Error, Sendable {
    let message: String
}

/// A file read and decoded off the main thread.
nonisolated struct LoadedImage: Sendable {
    let data: Data
    let details: ImageDetails?
    /// Nil for animations, and when ImageIO can't decode the file (AppKit may still).
    let decoded: CGImage?
}

/// Tells its controller about resizes (to keep fitting the pane) and pinches.
final class ImageScrollView: NSScrollView {
    weak var controller: ImageViewerController?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller?.fitToPane()
    }

    override func magnify(with event: NSEvent) {
        controller?.userWillMagnify()
        super.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        controller?.userWillMagnify()
        super.smartMagnify(with: event)
    }
}

/// Keeps a picture smaller than the pane in its middle.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let frame = documentView.frame
        if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}

/// The picture at its actual size (the scroll view zooms it), on a checkerboard (or the background
/// picked) where it's transparent. Drag it to move around; double-click to zoom in, and again to fit
/// the pane. With the editor split, only the focused pane's picture accepts the keyboard (see
/// `EditorHost.isInFocusedPane`).
final class ImageCanvasView: NSView {
    weak var controller: ImageViewerController?
    private let backdrop = BackdropView()
    private let pictureView = PictureView()
    /// Draws vector pictures (SVG previews) instead of `pictureView`, so they stay sharp.
    private let vectorView = VectorView()
    /// Plays animated pictures (GIF, APNG…) instead of `pictureView`.
    private var animationView: AnimationView?
    private var hasAlpha = false
    private var dragStart: (point: NSPoint, origin: NSPoint)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        backdrop.isHidden = true
        vectorView.isHidden = true
        for view in [backdrop, pictureView, vectorView] as [NSView] {
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        registerForDraggedTypes([Workspace.tabPasteboardType, .fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Shows `picture` at `size` points (or plays `animation`).
    func show(_ picture: CGImage, size: NSSize, animation: NSImage?, hasAlpha: Bool) {
        setFrameSize(size)
        layOut(hasAlpha: hasAlpha)
        vectorView.isHidden = true
        vectorView.picture = nil
        pictureView.isHidden = false
        pictureView.picture = animation == nil ? picture : nil
        if let animation {
            let view = animationView ?? AnimationView()
            view.imageScaling = .scaleAxesIndependently
            view.isEditable = false
            view.animates = true
            view.unregisterDraggedTypes()
            view.autoresizingMask = [.width, .height]
            view.frame = bounds
            view.image = animation
            if view.superview == nil { addSubview(view) }
            animationView = view
        } else {
            animationView?.removeFromSuperview()
            animationView = nil
        }
    }

    /// Shows a vector picture at its size in points.
    func showVector(_ picture: NSImage) {
        setFrameSize(picture.size)
        layOut(hasAlpha: true)
        pictureView.isHidden = true
        pictureView.picture = nil
        animationView?.removeFromSuperview()
        animationView = nil
        vectorView.isHidden = false
        vectorView.picture = picture
    }

    private func layOut(hasAlpha: Bool) {
        self.hasAlpha = hasAlpha
        for view in subviews { view.frame = bounds }
        backdrop.isHidden = !hasAlpha || backdrop.background == .none
        backdrop.needsDisplay = true
    }

    func setBackdrop(_ background: ImageBackground, isDark: Bool) {
        backdrop.background = background
        backdrop.isDark = isDark
        backdrop.isHidden = !hasAlpha || background == .none
    }

    func zoomDidChange(_ zoom: CGFloat) {
        pictureView.zoom = zoom
        backdrop.zoom = zoom
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Moving around

    /// Whether the picture is larger than the pane (so dragging it moves it).
    private var canPan: Bool {
        guard let clip = enclosingScrollView?.contentView else { return false }
        return clip.bounds.width < bounds.width - 0.5 || clip.bounds.height < bounds.height - 0.5
    }

    override func resetCursorRects() {
        if canPan { addCursorRect(visibleRect, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            controller?.toggleZoom(at: point)
            return
        }
        guard canPan, let clip = enclosingScrollView?.contentView else { return }
        dragStart = (event.locationInWindow, clip.bounds.origin)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let scrollView = enclosingScrollView else { return }
        let zoom = max(scrollView.magnification, 0.001)
        // Window coordinates go up; the picture's go down.
        let dx = (event.locationInWindow.x - start.point.x) / zoom
        let dy = (event.locationInWindow.y - start.point.y) / zoom
        let clip = scrollView.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: start.origin.x - dx, y: start.origin.y + dy), size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        NSCursor.pop()
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool {
        guard let document = controller?.document else { return true }
        return Workspace.shared.acceptsKeyboardFocus(document)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let document = controller?.document { Workspace.shared.documentDidTakeFocus(document) }
        return became
    }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func doCommand(by selector: Selector) {
        let clip = enclosingScrollView?.contentView
        let page = (clip?.bounds.height ?? 0) * 0.9
        switch selector {
        case #selector(moveUp(_:)): scroll(by: NSPoint(x: 0, y: -40))
        case #selector(moveDown(_:)): scroll(by: NSPoint(x: 0, y: 40))
        case #selector(moveLeft(_:)): scroll(by: NSPoint(x: -40, y: 0))
        case #selector(moveRight(_:)): scroll(by: NSPoint(x: 40, y: 0))
        case #selector(pageUp(_:)), #selector(scrollPageUp(_:)): scroll(by: NSPoint(x: 0, y: -page))
        case #selector(pageDown(_:)), #selector(scrollPageDown(_:)): scroll(by: NSPoint(x: 0, y: page))
        case #selector(scrollToBeginningOfDocument(_:)), #selector(moveToBeginningOfDocument(_:)): scroll(by: NSPoint(x: 0, y: -bounds.height))
        case #selector(scrollToEndOfDocument(_:)), #selector(moveToEndOfDocument(_:)): scroll(by: NSPoint(x: 0, y: bounds.height))
        default: super.doCommand(by: selector)
        }
    }

    override func insertText(_ insertString: Any) {
        // Space pages down, like in a browser; other keys do nothing.
        if (insertString as? String) == " " { doCommand(by: #selector(scrollPageDown(_:))) } else { NSSound.beep() }
    }

    /// Scrolls by `delta` points on screen.
    private func scroll(by delta: NSPoint) {
        guard let scrollView = enclosingScrollView else { return }
        let zoom = max(scrollView.magnification, 0.001)
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin.x += delta.x / zoom
        bounds.origin.y += delta.y / zoom
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    @objc func copy(_ sender: Any?) {
        controller?.copyImage()
    }

    // MARK: Drops

    // A tab dragged over the picture goes to the pane (see `Workspace.tabDragMoved`); files dropped
    // on it open.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let document = controller?.document else { return [] }
        if Workspace.shared.isTabDrag(sender) { return Workspace.shared.tabDragMoved(sender, over: document) }
        return droppedFiles(sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard let sender, let document = controller?.document, Workspace.shared.isTabDrag(sender) else { return }
        Workspace.shared.tabDragLeft(document)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let document = controller?.document else { return false }
        if Workspace.shared.isTabDrag(sender) { return Workspace.shared.tabDropped(sender, on: document) }
        let urls = droppedFiles(sender)
        guard !urls.isEmpty else { return false }
        Workspace.shared.open(urls: urls)
        return true
    }

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}

/// The picture, as its layer's contents: the GPU scales it, smoothly when zoomed out and as sharp
/// squares from `pixelatedZoom` on.
private final class PictureView: NSView {
    var picture: CGImage? {
        didSet { needsDisplay = true }
    }
    var zoom: CGFloat = 1 {
        didSet {
            if (oldValue >= ImageViewerController.pixelatedZoom) != (zoom >= ImageViewerController.pixelatedZoom) { needsDisplay = true }
        }
    }
    private var isPixelated: Bool { zoom >= ImageViewerController.pixelatedZoom }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = picture
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = isPixelated ? .nearest : .linear
    }

    /// Only for renderings outside the window (snapshots): the window uses `updateLayer`.
    override func draw(_ dirtyRect: NSRect) {
        guard let picture, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.interpolationQuality = isPixelated ? .none : .high
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(picture, in: bounds)
        context.restoreGState()
    }
}

/// A vector picture, drawn: the scroll view redraws it at every zoom, so it stays sharp.
private final class VectorView: NSView {
    var picture: NSImage? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        picture?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// What shows behind a transparent picture: gray squares (the same size on screen at any zoom),
/// white or black.
private final class BackdropView: NSView {
    var background = ImageBackground.checkerboard {
        didSet { if oldValue != background { needsDisplay = true } }
    }
    var isDark = false {
        didSet { if oldValue != isDark, background == .checkerboard { needsDisplay = true } }
    }
    var zoom: CGFloat = 1 {
        didSet { if oldValue != zoom, !isHidden, background == .checkerboard { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = dirtyRect.intersection(bounds)
        guard !rect.isEmpty else { return }
        switch background {
        case .white, .none:
            NSColor.white.setFill()
            rect.fill()
        case .black:
            NSColor.black.setFill()
            rect.fill()
        case .checkerboard:
            drawCheckerboard(in: rect)
        }
    }

    private func drawCheckerboard(in rect: NSRect) {
        let square = 8 / max(zoom, 0.001)
        let (light, dark): (NSColor, NSColor) = isDark
            ? (NSColor(white: 0.24, alpha: 1), NSColor(white: 0.19, alpha: 1))
            : (NSColor(white: 1, alpha: 1), NSColor(white: 0.9, alpha: 1))
        light.setFill()
        rect.fill()
        dark.setFill()
        let firstColumn = Int((rect.minX / square).rounded(.down)), lastColumn = Int((rect.maxX / square).rounded(.up))
        let firstRow = Int((rect.minY / square).rounded(.down)), lastRow = Int((rect.maxY / square).rounded(.up))
        guard (lastColumn - firstColumn) * (lastRow - firstRow) < 400_000 else { return }
        for row in firstRow..<lastRow {
            var column = firstColumn + ((firstColumn + row) & 1 == 0 ? 1 : 0)
            while column < lastColumn {
                NSRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square).intersection(bounds).fill()
                column += 2
            }
        }
    }
}

/// Plays an animated picture; clicks, keys and drags go to the canvas behind it.
private final class AnimationView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
