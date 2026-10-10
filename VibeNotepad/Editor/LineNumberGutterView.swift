import AppKit
import VibeCore

/// Hosts the line-number gutter next to the editor's scroll view.
///
/// The gutter is a sibling of the scroll view rather than an `NSRulerView`: on macOS 26 rulers
/// overlay the clip view, which shifted the text under the gutter.
final class EditorRootView: NSView {
    let scrollView: NSScrollView
    let gutter: LineNumberGutterView

    var showsGutter = true {
        didSet {
            guard oldValue != showsGutter else { return }
            gutter.isHidden = !showsGutter
            needsLayout = true
        }
    }

    init(scrollView: NSScrollView, gutter: LineNumberGutterView) {
        self.scrollView = scrollView
        self.gutter = gutter
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        addSubview(scrollView)
        addSubview(gutter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = showsGutter ? gutter.thickness : 0
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
    }
}

/// Line numbers for the editor. Lookups use the syntax engine's line index (binary search),
/// so drawing stays cheap even for very large files.
final class LineNumberGutterView: NSView {
    weak var textView: CodeTextView?
    weak var engine: SyntaxEngine?
    weak var controller: EditorController?

    /// Adds a column of fold chevrons for languages that support folding.
    var showsFoldMarkers = false {
        didSet { if oldValue != showsFoldMarkers { updateThickness(force: true) } }
    }
    var accentColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    private let foldColumnWidth: CGFloat = 13

    var font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular) { didSet { updateThickness(force: true) } }
    var textColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var activeTextColor: NSColor = .labelColor { didSet { needsDisplay = true } }
    var backgroundColor: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }

    private(set) var thickness: CGFloat = 44
    private var digitCount = 0
    private var dragAnchor: Int?

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    /// Grows the gutter when the line count gains a digit.
    func updateThickness(force: Bool = false) {
        let lines = max(engine?.lineCount ?? 1, 1)
        let digits = max(3, String(lines).count)
        guard force || digits != digitCount else { return }
        digitCount = digits
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let newThickness = ceil(CGFloat(digits) * digitWidth + 26 + (showsFoldMarkers ? foldColumnWidth - 4 : 0))
        if abs(newThickness - thickness) > 0.5 {
            thickness = newThickness
            superview?.needsLayout = true
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let area = bounds.intersection(dirtyRect)
        backgroundColor.setFill()
        area.fill()
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, let storage = textView.textStorage, let engine else { return }

        let containerOrigin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -containerOrigin.x, dy: -containerOrigin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let length = storage.length
        let selection = textView.selectedRange()
        let caretLine = engine.lineIndex(containing: selection.location)
        let activeLines = selection.length > 0
            ? engine.lines(intersecting: NSRange(location: selection.location, length: max(0, selection.length - 1)))
            : caretLine..<(caretLine + 1)

        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let active: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: activeTextColor]
        let foldColumn = showsFoldMarkers ? foldColumnWidth : 0
        let rightPadding: CGFloat = 12 + (showsFoldMarkers ? foldColumnWidth - 6 : 0)
        let origin = textView.textContainerOrigin
        let editorLayout = layoutManager as? EditorLayoutManager

        var line = engine.lineIndex(containing: charRange.location)
        let lastCharacter = NSMaxRange(charRange)
        while line < engine.lineCount {
            let start = engine.lineStart(line)
            if start > lastCharacter { break }
            // Lines inside a fold have no visual line of their own: jump past the fold.
            if let span = editorLayout?.hiddenSpan(at: start) {
                let next = engine.lineIndex(containing: NSMaxRange(span.hidden))
                if span.hidesToEnd || next <= line { break }
                line = next
                continue
            }
            var fragment: NSRect
            if start >= length {
                fragment = layoutManager.extraLineFragmentRect
                if fragment.isEmpty { break }
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            }
            let y = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
            if y > bounds.maxY { break }
            if y + fragment.height >= area.minY {
                let label = "\(line + 1)" as NSString
                let attributes = activeLines.contains(line) ? active : normal
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: thickness - rightPadding - size.width, y: y + (fragment.height - size.height) / 2),
                           withAttributes: attributes)
                if foldColumn > 0, let controller, let region = controller.foldRegion(startingOnLine: line) {
                    drawChevron(folded: controller.isFolded(region),
                                center: NSPoint(x: thickness - foldColumn / 2 - 3, y: y + fragment.height / 2))
                }
            }
            line += 1
            if start >= length { break }
        }
    }

    private func drawChevron(folded: Bool, center: NSPoint) {
        let size: CGFloat = 4
        let path = NSBezierPath()
        if folded {
            path.move(to: NSPoint(x: center.x - size / 2, y: center.y - size))
            path.line(to: NSPoint(x: center.x + size / 2 + 0.5, y: center.y))
            path.line(to: NSPoint(x: center.x - size / 2, y: center.y + size))
        } else {
            path.move(to: NSPoint(x: center.x - size, y: center.y - size / 2))
            path.line(to: NSPoint(x: center.x, y: center.y + size / 2 + 0.5))
            path.line(to: NSPoint(x: center.x + size, y: center.y - size / 2))
        }
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (folded ? accentColor : textColor.withAlphaComponent(0.75)).setStroke()
        path.stroke()
    }

    // MARK: Selecting lines from the gutter

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if showsFoldMarkers, local.x >= thickness - foldColumnWidth - 8, let controller, let textView,
           let index = characterIndex(at: event) {
            let line = controller.engine.lineIndex(containing: index)
            if controller.foldRegion(startingOnLine: line) != nil {
                controller.toggleFold(atLine: line)
                textView.window?.makeFirstResponder(textView)
                return
            }
        }
        guard let textView, let range = lineRange(at: event) else { return }
        if event.modifierFlags.contains(.shift) {
            let union = NSUnionRange(textView.selectedRange(), range)
            textView.setSelectedRange(union)
            dragAnchor = union.location
        } else {
            textView.setSelectedRange(range)
            dragAnchor = range.location
        }
        textView.window?.makeFirstResponder(textView)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor, let range = lineRange(at: event), let textView, let storage = textView.textStorage else { return }
        let anchorLine = storage.mutableString.lineRange(for: NSRange(location: anchor, length: 0))
        textView.setSelectedRange(NSUnionRange(anchorLine, range))
        textView.autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
    }

    private func characterIndex(at event: NSEvent) -> Int? {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, let storage = textView.textStorage else { return nil }
        let point = textView.convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(x: 0, y: point.y - textView.textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: container)
        return min(layoutManager.characterIndexForGlyph(at: glyph), storage.length)
    }

    private func lineRange(at event: NSEvent) -> NSRange? {
        guard let character = characterIndex(at: event), let storage = textView?.textStorage else { return nil }
        return storage.mutableString.lineRange(for: NSRange(location: character, length: 0))
    }
}
