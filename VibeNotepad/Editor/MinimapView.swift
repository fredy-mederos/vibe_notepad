import AppKit
import VibeCore

/// A zoomed-out view of the document beside the editor, Sublime-style: every character is a
/// small block in its syntax color, one row per line. The shaded slider marks what's on screen;
/// click or drag to scroll. Only the rows in view are rendered (and kept, in tiles, while
/// scrolling), so any file size costs the same.
final class MinimapView: NSView {
    weak var controller: EditorController?

    /// Distance between rows; each row's blocks are `blockHeight` tall.
    static let rowPitch: CGFloat = 3
    static let blockHeight: CGFloat = 2
    static let columnWidth: CGFloat = 1
    /// Characters past this column aren't drawn.
    static let columns = 100
    static let padding: CGFloat = 8
    static let width = CGFloat(columns) * columnWidth + padding * 2
    /// Longer lines are drawn without syntax colors (lexing them isn't worth it here).
    private static let maxColoredLineLength = 2_000

    var backgroundColor: NSColor = .textBackgroundColor { didSet { if oldValue != backgroundColor { invalidateAll() } } }
    /// Opaque block colors, indexed by `TokenKind.rawValue`.
    var palette: [NSColor] = [] { didSet { if oldValue != palette { invalidateAll() } } }
    var sliderColor: NSColor = .labelColor { didSet { needsDisplay = true } }
    var addedColor: NSColor = .systemGreen
    var modifiedColor: NSColor = .systemBlue
    var deletedColor: NSColor = .systemRed
    var tabWidth = 4 { didSet { if oldValue != tabWidth { invalidateAll() } } }

    private var isHovering = false { didSet { if oldValue != isHovering { needsDisplay = true } } }
    /// Where the slider was grabbed (from its top) while dragging.
    private var dragGrab: CGFloat?
    private var characters = [UInt16](repeating: 0, count: 512)
    private var kinds = [UInt8](repeating: 0, count: 512)

    /// Rows are rendered in tiles of this many lines and reused while scrolling.
    private static let tileRows = 64
    private var tiles: [Int: NSImage] = [:]
    private var tileScale: CGFloat = 0

    init() {
        super.init(frame: .zero)
        // Views don't clip by default: the background fill must not paint over the editor.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    private struct Geometry {
        /// How far the minimap itself is scrolled (when the document is taller than the view).
        var offset: CGFloat
        var sliderTop: CGFloat
        var sliderHeight: CGFloat
        /// The height the slider moves in.
        var track: CGFloat
        var lineCount: Int
        var visibleLineCount: Int
    }

    /// Rows are lines, so everything is measured in lines: the slider covers the lines on screen,
    /// and the minimap scrolls with them (word wrap and lazy layout make pixel heights unreliable).
    private func geometry(_ controller: EditorController) -> Geometry {
        let lineCount = controller.engine.lineCount
        let visible = controller.visibleLines()
        let contentHeight = CGFloat(lineCount) * Self.rowPitch
        let fraction = min(1, CGFloat(visible.lowerBound) / CGFloat(max(1, lineCount - visible.count)))
        // Whole points keep the blocks crisp.
        let offset = contentHeight > bounds.height ? (fraction * (contentHeight - bounds.height)).rounded() : 0
        return Geometry(offset: offset, sliderTop: CGFloat(visible.lowerBound) * Self.rowPitch - offset,
                        sliderHeight: max(Self.rowPitch * 4, CGFloat(visible.count) * Self.rowPitch),
                        track: min(bounds.height, contentHeight), lineCount: lineCount, visibleLineCount: visible.count)
    }

    // MARK: Tiles

    /// Lines whose text or colors changed; `lineCountChanged` means every later line moved too.
    func invalidate(lines: Range<Int>, lineCountChanged: Bool) {
        needsDisplay = true
        guard !tiles.isEmpty else { return }
        let firstTile = lines.lowerBound / Self.tileRows
        if lineCountChanged {
            tiles = tiles.filter { $0.key < firstTile }
        } else {
            let lastTile = max(lines.lowerBound, lines.upperBound - 1) / Self.tileRows
            for tile in firstTile...lastTile { tiles[tile] = nil }
        }
    }

    func invalidateAll() {
        tiles.removeAll()
        needsDisplay = true
    }

    /// Renders one tile's rows into an image (background included).
    private func renderTile(_ tile: Int, engine: SyntaxEngine, text: NSString, scale: CGFloat) -> NSImage? {
        let size = NSSize(width: Self.width, height: CGFloat(Self.tileRows) * Self.rowPitch)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        backgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        let first = tile * Self.tileRows
        let rows = first..<min(engine.lineCount, first + Self.tileRows)
        if !rows.isEmpty { drawRows(rows, engine: engine, text: text, top: -CGFloat(first) * Self.rowPitch) }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: size)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dirtyRect = dirtyRect.intersection(bounds)
        backgroundColor.setFill()
        dirtyRect.fill()
        guard let controller, !palette.isEmpty else { return }
        let engine = controller.engine
        let text = controller.nsText
        // Mid-edit, the engine may not have caught up with the text yet.
        guard engine.textLength == text.length else { return }
        let geometry = geometry(controller)
        let first = max(0, Int((dirtyRect.minY + geometry.offset) / Self.rowPitch))
        let last = min(engine.lineCount, Int(((dirtyRect.maxY + geometry.offset) / Self.rowPitch).rounded(.up)))
        if first < last {
            let scale = window?.backingScaleFactor ?? 2
            if scale != tileScale {
                tiles.removeAll()
                tileScale = scale
            }
            let visibleTiles = (first / Self.tileRows)...((last - 1) / Self.tileRows)
            for tile in visibleTiles {
                guard let image = tiles[tile] ?? renderTile(tile, engine: engine, text: text, scale: scale) else { continue }
                tiles[tile] = image
                let rect = NSRect(x: 0, y: CGFloat(tile * Self.tileRows) * Self.rowPitch - geometry.offset,
                                  width: Self.width, height: CGFloat(Self.tileRows) * Self.rowPitch)
                image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            }
            // Keep the tiles around the view; far-away ones are cheap to render again.
            if tiles.count > 24 {
                tiles = tiles.filter { abs($0.key - visibleTiles.lowerBound) <= 12 }
            }
            drawChanges(controller.gitChanges, rows: first..<last, offset: geometry.offset)
        }
        let slider = NSRect(x: 0, y: geometry.sliderTop, width: bounds.width, height: geometry.sliderHeight)
        sliderColor.withAlphaComponent(dragGrab != nil ? 0.2 : isHovering ? 0.15 : 0.1).setFill()
        slider.fill(using: .sourceOver)
    }

    /// Draws `rows` as blocks, with line `n` at `top + n * rowPitch`.
    private func drawRows(_ rows: Range<Int>, engine: SyntaxEngine, text: NSString, top: CGFloat) {
        var rects = [[NSRect]](repeating: [], count: palette.count)
        let capacity = characters.count
        for line in rows {
            let start = engine.lineStart(line)
            let fullLength = engine.lineContentEnd(line) - start
            let length = min(fullLength, capacity)
            guard length > 0 else { continue }
            characters.withUnsafeMutableBufferPointer { buffer in
                text.getCharacters(buffer.baseAddress!, range: NSRange(location: start, length: length))
            }
            for i in 0..<length { kinds[i] = 0 }
            if fullLength <= Self.maxColoredLineLength {
                engine.enumerateTokens(lines: line..<(line + 1), text: text) { range, kind in
                    let lo = max(0, range.location - start), hi = min(length, NSMaxRange(range) - start)
                    if lo < hi { for i in lo..<hi { kinds[i] = kind.rawValue } }
                }
            }

            let y = top + CGFloat(line) * Self.rowPitch
            var column = 0
            var runStart = -1
            var runKind = 0
            func flush() {
                guard runStart >= 0 else { return }
                rects[runKind].append(NSRect(x: Self.padding + CGFloat(runStart) * Self.columnWidth, y: y,
                                             width: CGFloat(column - runStart) * Self.columnWidth, height: Self.blockHeight))
                runStart = -1
            }
            for i in 0..<length {
                let unit = characters[i]
                switch unit {
                case 0x09:
                    flush()
                    column = (column / tabWidth + 1) * tabWidth
                case 0x20, 0x0D, 0xA0:
                    flush()
                    column += 1
                case 0xDC00...0xDFFF:
                    continue // the second half of a surrogate pair shares its first half's block
                default:
                    let kind = Int(kinds[i]) < rects.count ? Int(kinds[i]) : 0
                    if runStart >= 0, kind != runKind { flush() }
                    if runStart < 0 {
                        runStart = column
                        runKind = kind
                    }
                    column += 1
                }
                if column >= Self.columns { break }
            }
            column = min(column, Self.columns)
            flush()
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for (index, list) in rects.enumerated() where !list.isEmpty {
            context.setFillColor(palette[index].cgColor)
            context.fill(list)
        }
    }

    /// Git markers along the left edge, like the gutter's.
    private func drawChanges(_ changes: [LineChange], rows: Range<Int>, offset: CGFloat) {
        for change in changes where change.lines.upperBound >= rows.lowerBound && change.lines.lowerBound <= rows.upperBound {
            let y = CGFloat(change.lines.lowerBound) * Self.rowPitch - offset
            switch change.kind {
            case .added, .modified:
                (change.kind == .added ? addedColor : modifiedColor).setFill()
                NSRect(x: 0, y: y, width: 2, height: CGFloat(change.lines.count) * Self.rowPitch).fill()
            case .deleted:
                deletedColor.setFill()
                NSRect(x: 0, y: y - 1, width: 4, height: 2).fill()
            }
        }
    }

    // MARK: Scrolling

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        let y = convert(event.locationInWindow, from: nil).y
        let geometry = geometry(controller)
        // Grabbing the slider keeps it under the pointer; clicking elsewhere centers it there.
        let onSlider = y >= geometry.sliderTop && y <= geometry.sliderTop + geometry.sliderHeight
        dragGrab = onSlider ? y - geometry.sliderTop : geometry.sliderHeight / 2
        scroll(toPointerAt: y, geometry: geometry)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, dragGrab != nil else { return }
        scroll(toPointerAt: convert(event.locationInWindow, from: nil).y, geometry: geometry(controller))
    }

    override func mouseUp(with event: NSEvent) {
        dragGrab = nil
        needsDisplay = true
    }

    private func scroll(toPointerAt y: CGFloat, geometry: Geometry) {
        guard let controller, let grab = dragGrab else { return }
        let range = geometry.track - geometry.sliderHeight
        guard range > 0 else { return }
        let fraction = min(1, max(0, (y - grab) / range))
        let clip = controller.scrollView.contentView
        if fraction >= 1 {
            controller.scrollToEnd()
            return
        }
        let line = Int((fraction * CGFloat(geometry.lineCount - geometry.visibleLineCount)).rounded())
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: topOffset(ofLine: line, in: controller)))
        controller.scrollView.reflectScrolledClipView(clip)
    }

    /// The scroll position that puts `line` at the top of the editor.
    private func topOffset(ofLine line: Int, in controller: EditorController) -> CGFloat {
        let engine = controller.engine
        let location = engine.lineStart(min(max(0, line), engine.lineCount - 1))
        guard line > 0, location < controller.textStorage.length else { return 0 }
        let layoutManager = controller.layoutManager
        // Lays out just around the line (layout is non-contiguous), so jumping far stays quick.
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: location, length: 1))
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        let top = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true).minY
        let maxY = max(0, controller.textView.frame.height - controller.scrollView.contentView.bounds.height)
        return min(top, maxY)
    }

    override func scrollWheel(with event: NSEvent) {
        controller?.scrollView.scrollWheel(with: event)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }

    override func mouseExited(with event: NSEvent) { isHovering = false }
}
