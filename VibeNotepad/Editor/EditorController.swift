import AppKit
import VibeCore

/// Owns the AppKit text stack for one document: scroll view, text view, gutter, syntax
/// styling, find highlights and undo. The views live as long as the document, so switching
/// tabs keeps scroll position, selection and undo history.
final class EditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    unowned let document: EditorDocument

    let rootView: EditorRootView
    let scrollView: NSScrollView
    let textView: CodeTextView
    let textStorage: NSTextStorage
    let layoutManager: EditorLayoutManager
    let textContainer: NSTextContainer
    let gutter: LineNumberGutterView
    let minimap: MinimapView
    let styler: SyntaxStyler
    let undoManager = UndoManager()

    var engine: SyntaxEngine { styler.engine }
    private(set) var lineHeight: CGFloat = 19

    private var isLoading = false
    private var changeCount = 0 {
        didSet { updateDirtyState() }
    }
    /// Unsaved changes outside the undo history: line endings, encoding, restored hot-exit text.
    private var hasChangesWithoutUndo = false {
        didSet { updateDirtyState() }
    }
    private var styleSignature = ""
    private var appliedThemeID: String?
    private var wraps: Bool?
    private var theme: Theme = Themes.vibeNight

    // Find state
    private(set) var findMatches: [NSRange] = []
    private(set) var currentMatchIndex: Int?
    private var findAnchor: Int?
    private var findRefreshTask: Task<Void, Never>?
    private var bracketRanges: [NSRange] = []
    private var lastSelection = NSRange(location: 0, length: 0)
    private var isAdjustingSelection = false

    // Folding
    private(set) var foldState = FoldState()
    private(set) var foldRegions: [FoldRegion] = []
    private var foldAnalysisTask: Task<Void, Never>?
    private var textVersion = 0
    /// `textVersion` that `foldRegions` were computed for.
    private var foldRegionsVersion = -1
    private var foldsToRelayout: [NSRange] = []

    // Git changes
    /// Lines that differ from the file's version staged in git, marked next to the line numbers.
    private(set) var gitChanges: [LineChange] = []
    /// Line hashes of the staged version; nil when the file isn't tracked (or markers are off).
    private var gitBase: [UInt64]?
    /// When `gitBase` was last read from git (nil: never, or known to be out of date).
    private var gitBaseDate: Date?
    private var gitBaseTask: Task<Void, Never>?
    private var gitDiffTask: Task<Void, Never>?
    private var showsGitChanges: Bool?

    /// Called after every edit (debouncing is up to the receiver).
    var onTextChange: (() -> Void)?
    /// Called when the visible region scrolls.
    var onScroll: (() -> Void)?

    // MARK: Setup

    init(document: EditorDocument, text: String) {
        self.document = document
        let storage = NSTextStorage()
        let layout = EditorLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 6
        layout.addTextContainer(container)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.wantsLayer = true
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 4, height: 12)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFindBar = false
        view.isIncrementalSearchingEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.usesFontPanel = false
        view.usesRuler = false
        view.allowsImageEditing = false
        view.displaysLinkToolTips = false
        view.allowsCharacterPickerTouchBarItem = false
        view.writingToolsBehavior = .none
        scroll.documentView = view

        let lineNumbers = LineNumberGutterView()
        lineNumbers.textView = view
        let overview = MinimapView()
        rootView = EditorRootView(scrollView: scroll, gutter: lineNumbers, minimap: overview)
        rootView.wantsLayer = true

        scrollView = scroll
        textView = view
        textStorage = storage
        layoutManager = layout
        textContainer = container
        gutter = lineNumbers
        minimap = overview
        styler = SyntaxStyler(language: document.language, textStorage: storage)
        super.init()

        lineNumbers.engine = styler.engine
        lineNumbers.controller = self
        overview.controller = self
        view.controller = self
        view.delegate = self
        storage.delegate = self
        view.language = document.language
        view.indentation = document.indentation

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clipViewDidScroll(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        center.addObserver(self, selector: #selector(textViewFrameDidChange(_:)), name: NSView.frameDidChangeNotification, object: view)
        center.addObserver(self, selector: #selector(undoGroupDidClose(_:)), name: .NSUndoManagerDidCloseUndoGroup, object: undoManager)
        center.addObserver(self, selector: #selector(didUndo(_:)), name: .NSUndoManagerDidUndoChange, object: undoManager)
        center.addObserver(self, selector: #selector(didRedo(_:)), name: .NSUndoManagerDidRedoChange, object: undoManager)

        applySettings(AppSettings.shared, theme: AppSettings.shared.theme)
        load(text: text)
        refreshGitBase()
    }

    // MARK: Content

    var text: String { textStorage.string }
    var nsText: NSString { textStorage.mutableString }

    /// Replaces the whole content without undo (initial load).
    private func load(text: String) {
        isLoading = true
        textStorage.beginEditing()
        textStorage.setAttributedString(NSAttributedString(string: text, attributes: styler.baseAttributes))
        textStorage.endEditing()
        isLoading = false
        if engine.textLength != textStorage.length { engine.reset(text: nsText, language: document.language) }
        restyleAfterReset()
        gutter.showsFoldMarkers = supportsFolding
        gutter.updateThickness(force: true)
        textView.typingAttributes = styler.baseAttributes
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scheduleFoldAnalysis(immediate: true)
    }

    /// Replaces the content (reload from disk, revert), keeping selection and scroll position.
    func replaceAllText(_ newText: String, markClean: Bool = true) {
        let selection = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin
        foldState.unfoldAll()
        foldRegions = []
        layoutManager.foldSpans = []
        textVersion += 1
        isLoading = true
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: newText)
        textStorage.setAttributes(styler.baseAttributes, range: NSRange(location: 0, length: textStorage.length))
        textStorage.endEditing()
        isLoading = false
        if engine.textLength != textStorage.length { engine.reset(text: nsText, language: document.language) }
        restyleAfterReset()
        undoManager.removeAllActions()
        if markClean {
            changeCount = 0
            hasChangesWithoutUndo = false
        }
        textView.setSelectedRange(clamp(selection))
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        contentDidChange()
        scheduleFoldAnalysis(immediate: true)
        // Reloads often follow git operations (checkout, pull), which can change the staged version too.
        refreshGitBase()
        // Matches found in the old text point at the wrong places now.
        if !findMatches.isEmpty || Workspace.shared.findBarVisible {
            findMatches = []
            currentMatchIndex = nil
            scheduleFindRefresh()
        }
    }

    func setLanguage(_ language: LanguageID) {
        textView.language = language
        if !foldState.isEmpty { unfoldAll() }
        foldRegions = []
        foldRegionsVersion = -1
        gutter.showsFoldMarkers = FoldingAnalyzer.supportsFolding(language)
        gutter.updateThickness(force: true)
        scheduleFoldAnalysis(immediate: true)
        engine.setLanguage(language, text: nsText)
        minimap.invalidateAll()
        styler.resetAttributes()
        restyleAfterReset()
        updateSpellChecking()
        contentDidChange()
    }

    func markSaved() {
        changeCount = 0
        hasChangesWithoutUndo = false
        textView.breakUndoCoalescing()
    }

    /// For changes undo can't take back (hot-exit restores, line endings, encoding): the
    /// document stays dirty until it's saved or reverted.
    func markDirtyWithoutUndo() {
        hasChangesWithoutUndo = true
    }

    private func updateDirtyState() {
        let dirty = changeCount != 0 || hasChangesWithoutUndo
        if document.isDirty != dirty { document.isDirty = dirty }
    }

    // MARK: Appearance & settings

    func applySettings(_ settings: AppSettings, theme: Theme) {
        let font = settings.editorFont
        let natural = ceil(font.ascender - font.descender + font.leading)
        let height = max(natural, round(natural * CGFloat(settings.lineHeight)))
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = spaceWidth * CGFloat(document.indentation.width)
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height

        let signature = "\(theme.id)|\(font.fontName)|\(font.pointSize)|\(height)|\(document.indentation.width)"
        let themeChanged = appliedThemeID != nil && appliedThemeID != theme.id
        if themeChanged {
            // Crossfade the old rendering into the new theme.
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.28
            rootView.layer?.add(transition, forKey: "themeFade")
        }
        self.theme = theme
        appliedThemeID = theme.id
        lineHeight = height
        layoutManager.font = font
        layoutManager.lineHeight = height
        layoutManager.showsInvisibles = settings.showInvisibles
        layoutManager.invisiblesColor = theme.invisibles.nsColor
        layoutManager.foldPillFill = theme.accent.withAlpha(theme.isDark ? 0.28 : 0.16).nsColor
        layoutManager.foldPillText = theme.accent.mixed(with: theme.foreground, 0.35).nsColor
        gutter.accentColor = theme.accent.nsColor

        textView.appearance = theme.appearance
        textView.backgroundColor = theme.background.nsColor
        textView.insertionPointColor = theme.cursor.nsColor
        textView.selectedTextAttributes = [.backgroundColor: theme.selection.nsColor]
        textView.lineHighlightColor = theme.lineHighlight.nsColor
        textView.highlightsCurrentLine = settings.highlightCurrentLine
        textView.autoCloseBrackets = settings.autoCloseBrackets
        textView.indentation = document.indentation
        scrollView.backgroundColor = theme.background.nsColor
        scrollView.scrollerKnobStyle = theme.isDark ? .light : .dark
        scrollView.appearance = theme.appearance

        gutter.backgroundColor = theme.background.nsColor
        gutter.textColor = theme.gutterForeground.nsColor
        gutter.activeTextColor = theme.gutterActiveForeground.nsColor
        let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 1.5), weight: .regular)
        if gutter.font != gutterFont { gutter.font = gutterFont }
        rootView.showsGutter = settings.showLineNumbers
        rootView.showsMinimap = settings.showMinimap && settings.showsSidebar
        minimap.backgroundColor = theme.background.nsColor
        minimap.sliderColor = theme.foreground.nsColor
        minimap.tabWidth = document.indentation.width
        // Opaque colors, softened toward the background, so each color is a single fill.
        minimap.palette = TokenKind.allCases.map { kind in
            let color = kind == .plain ? theme.foreground : theme.style(for: kind)?.color ?? theme.foreground
            return color.mixed(with: theme.background, 0.3).nsColor
        }
        if showsGitChanges != nil, showsGitChanges != settings.showGitChanges {
            showsGitChanges = settings.showGitChanges
            refreshGitBase()
        }
        showsGitChanges = settings.showGitChanges

        setWrap(document.wrapLines ?? settings.wrapLines)
        updateSpellChecking()

        if signature != styleSignature {
            styleSignature = signature
            styler.configure(theme: theme, font: font, paragraphStyle: paragraph)
            textView.typingAttributes = styler.baseAttributes
            if !isLoading, textStorage.length > 0 {
                styler.resetAttributes()
                restyleAfterReset()
            }
        }
        textView.needsDisplay = true
        gutter.needsDisplay = true
        if !findMatches.isEmpty { repaintFindHighlights() }
    }

    func setWrap(_ wrap: Bool) {
        guard wraps != wrap else { return }
        wraps = wrap
        if wrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textContainer.widthTracksTextView = true
            let width = scrollView.contentSize.width
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        styleVisible()
    }

    private func updateSpellChecking() {
        let enable = AppSettings.shared.spellCheckProse && document.language.info.isProse
        if textView.isContinuousSpellCheckingEnabled != enable { textView.isContinuousSpellCheckingEnabled = enable }
    }

    // MARK: Styling

    private func restyleAfterReset() {
        if engine.lineCount <= 3000 {
            styler.style(lines: 0..<engine.lineCount)
        } else {
            styleVisible()
        }
    }

    private var isStylingVisible = false
    private var styleVisibleScheduled = false

    /// Paints the visible lines (plus a margin) that still need styling.
    func styleVisible() {
        guard !textView.hasMarkedText(), !isLoading, engine.textLength == textStorage.length else { return }
        // Styling can trigger layout that scrolls or resizes the view, which calls back here.
        guard !isStylingVisible else {
            scheduleStyleVisible()
            return
        }
        isStylingVisible = true
        defer { isStylingVisible = false }
        let lines = visibleLines(margin: 80)
        guard !layoutManager.foldSpans.isEmpty else {
            styler.styleUnstyled(in: lines)
            return
        }
        // Skip folded lines, except each fold's closing line: its text is drawn after the pill.
        var line = lines.lowerBound
        while line < lines.upperBound {
            let start = engine.lineStart(line)
            if let span = layoutManager.hiddenSpan(at: start) {
                let closing = engine.lineIndex(containing: span.previewIndex)
                styler.styleUnstyled(in: closing..<(closing + 1))
                let next = engine.lineIndex(containing: NSMaxRange(span.hidden))
                if span.hidesToEnd || next <= line { break }
                line = next
                continue
            }
            var end = lines.upperBound
            if let span = layoutManager.nextSpan(from: start) {
                end = min(end, engine.lineIndex(containing: span.lineEnd) + 1)
            }
            styler.styleUnstyled(in: line..<end)
            line = max(end, line + 1)
        }
    }

    /// Runs `styleVisible()` once the current layout pass is over.
    private func scheduleStyleVisible() {
        guard !styleVisibleScheduled else { return }
        styleVisibleScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.styleVisibleScheduled = false
            self.styleVisible()
        }
    }

    /// Whether the view shows the end of the document (log files keep following it on reload).
    var isScrolledToEnd: Bool {
        let clip = scrollView.contentView
        return clip.bounds.maxY >= textView.frame.height - lineHeight
    }

    func scrollToEnd() {
        textView.scrollToEndOfDocument(nil)
    }

    func visibleLines(margin: Int = 0) -> Range<Int> {
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        guard visible.height > 1 else { return 0..<min(engine.lineCount, 300) }
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let first = engine.lineIndex(containing: characters.location)
        let last = engine.lineIndex(containing: NSMaxRange(characters))
        return max(0, first - margin)..<min(engine.lineCount, last + margin + 1)
    }

    // MARK: NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Whole-text loads re-lex from scratch, before layout (and any scroll or styling it
        // triggers) can see line offsets from the old text.
        guard !isLoading else {
            engine.reset(text: textStorage.mutableString, language: document.language)
            minimap.invalidateAll()
            return
        }
        let lineCount = engine.lineCount
        let changedLines = engine.applyEdit(text: textStorage.mutableString, editedRange: editedRange, changeInLength: delta)
        minimap.invalidate(lines: changedLines, lineCountChanged: engine.lineCount != lineCount)
        textVersion += 1
        foldRegions.applyEdit(editedRange: editedRange, changeInLength: delta)
        if !foldState.isEmpty {
            let removed = foldState.applyEdit(editedRange: editedRange, changeInLength: delta)
            if removed.isEmpty, let shifted = layoutManager.foldSpans.shifted(editedRange: editedRange, changeInLength: delta) {
                layoutManager.foldSpans = shifted
            } else {
                let previous = layoutManager.foldSpans
                layoutManager.foldSpans = makeFoldSpans()
                // Text that was hidden must be laid out again once the edit settles.
                let editStart = editedRange.location, oldEditEnd = NSMaxRange(editedRange) - delta
                foldsToRelayout += previous.compactMap { span in
                    let extent = span.extent
                    if NSMaxRange(extent) <= editStart { return extent }
                    if extent.location >= oldEditEnd { return NSRange(location: extent.location + delta, length: extent.length) }
                    return NSRange(location: min(extent.location, editStart), length: max(0, NSMaxRange(extent) + delta - min(extent.location, editStart)))
                }
            }
        }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        if !foldsToRelayout.isEmpty {
            invalidateFoldLayout(foldsToRelayout)
            foldsToRelayout = []
        }
        scheduleFoldAnalysis()
        if gitBase != nil { scheduleGitDiff() }
        styleVisible()
        contentDidChange()
        if !findMatches.isEmpty || Workspace.shared.findBarVisible { scheduleFindRefresh() }
    }

    private func contentDidChange() {
        gutter.updateThickness()
        gutter.needsDisplay = true
        if rootView.isMinimapVisible { minimap.needsDisplay = true }
        updateStatus()
        document.contentDidChange()
        onTextChange?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // Extending the selection with ⇧-arrows bypasses `setSelectedRanges`: move its ends out of folds here.
        if !layoutManager.foldSpans.isEmpty, !isAdjustingSelection {
            let selection = textView.selectedRange()
            let adjusted = textView.outsideFolds(selection, from: lastSelection, layout: layoutManager)
            if adjusted != selection {
                isAdjustingSelection = true
                textView.setSelectedRange(adjusted)
                isAdjustingSelection = false
                return
            }
        }
        lastSelection = textView.selectedRange()
        updateStatus()
        gutter.needsDisplay = true
        updateBracketHighlight()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), Workspace.shared.findBarVisible {
            Workspace.shared.hideFindBar()
            return true
        }
        return false
    }

    func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        // Trim AppKit's rich-text items that make no sense in a code editor.
        let unwanted: Set<String> = ["Font", "Spelling and Grammar", "Substitutions", "Transformations", "Speech", "Layout Orientation", "Share", "Services"]
        for item in menu.items where unwanted.contains(item.title) { menu.removeItem(item) }
        return menu
    }

    // MARK: Dirty tracking (mirrors NSDocument's change counting)

    @objc private func undoGroupDidClose(_ notification: Notification) {
        guard !undoManager.isUndoing, !undoManager.isRedoing else { return }
        changeCount += 1
    }

    @objc private func didUndo(_ notification: Notification) { changeCount -= 1 }
    @objc private func didRedo(_ notification: Notification) { changeCount += 1 }

    // MARK: Scrolling

    @objc private func clipViewDidScroll(_ notification: Notification) {
        styleVisible()
        gutter.needsDisplay = true
        if rootView.isMinimapVisible { minimap.needsDisplay = true }
        document.loadedPreview?.syncScroll()
        onScroll?()
    }

    @objc private func textViewFrameDidChange(_ notification: Notification) {
        // Frame changes arrive in the middle of layout; styling now would edit the text storage
        // and start another layout pass from inside this one.
        scheduleStyleVisible()
        gutter.needsDisplay = true
        if rootView.isMinimapVisible { minimap.needsDisplay = true }
    }

    /// The first visible line and how far (0…1) it is scrolled past.
    func topVisibleLine() -> (line: Int, fraction: Double, atEnd: Bool) {
        let visible = textView.visibleRect
        let clip = scrollView.contentView
        let atEnd = clip.bounds.maxY >= (scrollView.documentView?.frame.height ?? 0) - 2
        let point = NSPoint(x: 0, y: max(0, visible.minY - textView.textContainerOrigin.y))
        guard textStorage.length > 0 else { return (0, 0, atEnd) }
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        let character = min(layoutManager.characterIndexForGlyph(at: glyph), textStorage.length - 1)
        let line = engine.lineIndex(containing: character)
        let startGlyph = layoutManager.glyphIndexForCharacter(at: engine.lineStart(line))
        let endCharacter = max(engine.lineStart(line), min(engine.lineContentEnd(line), textStorage.length - 1))
        let endGlyph = layoutManager.glyphIndexForCharacter(at: endCharacter)
        let top = layoutManager.lineFragmentRect(forGlyphAt: startGlyph, effectiveRange: nil, withoutAdditionalLayout: true).minY
        let bottom = layoutManager.lineFragmentRect(forGlyphAt: endGlyph, effectiveRange: nil, withoutAdditionalLayout: true).maxY
        let fraction = bottom > top ? Double((point.y - top) / (bottom - top)) : 0
        return (line, min(max(fraction, 0), 1), atEnd)
    }

    // MARK: Status

    func updateStatus() {
        let selection = textView.selectedRange()
        let line = engine.lineIndex(containing: selection.location)
        var status = EditorDocument.Cursor()
        status.line = line + 1
        status.column = textView.visualColumn(at: selection.location) + 1
        status.selectionLength = selection.length
        if selection.length > 0 {
            status.selectedLines = engine.lines(intersecting: NSRange(location: selection.location, length: max(0, selection.length - 1))).count
        }
        status.lineCount = engine.lineCount
        if document.cursor != status { document.cursor = status }
    }

    // MARK: Editing

    func focus() {
        guard let window = textView.window else { return }
        if window.firstResponder !== textView { window.makeFirstResponder(textView) }
    }

    /// Applies an edit through the text view so it is undoable.
    func apply(_ edit: TextEdit, actionName: String? = nil, scroll: Bool = true) {
        let range = clamp(edit.range)
        guard textView.shouldChangeText(in: range, replacementString: edit.replacement) else { return }
        textStorage.replaceCharacters(in: range, with: edit.replacement)
        textView.didChangeText()
        let selection = clamp(edit.selection)
        textView.setSelectedRange(selection)
        if scroll { textView.scrollRangeToVisible(selection) }
        if let actionName { undoManager.setActionName(actionName) }
    }

    /// Applies several replacements (in the original text's coordinates) as one undo step.
    @discardableResult
    func applyReplacements(_ edits: [(NSRange, String)], actionName: String) -> Bool {
        guard !edits.isEmpty else { return false }
        let ranges = edits.map { NSValue(range: $0.0) }
        guard textView.shouldChangeText(inRanges: ranges, replacementStrings: edits.map(\.1)) else { return false }
        textStorage.beginEditing()
        for (range, replacement) in edits.reversed() { textStorage.replaceCharacters(in: range, with: replacement) }
        textStorage.endEditing()
        textView.didChangeText()
        undoManager.setActionName(actionName)
        return true
    }

    func clamp(_ range: NSRange) -> NSRange {
        let length = textStorage.length
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    func indent() {
        apply(TextTransforms.indent(nsText, selection: textView.selectedRange(), unit: document.indentation.unit), actionName: "Indent")
    }

    func outdent() {
        if let edit = TextTransforms.outdent(nsText, selection: textView.selectedRange(), tabWidth: document.indentation.width) {
            apply(edit, actionName: "Outdent")
        }
    }

    func toggleComment() {
        let info = document.language.info
        let line = info.lineComment ?? (info.blockComment == nil ? "#" : nil)
        if let edit = TextTransforms.toggleComment(nsText, selection: textView.selectedRange(), lineComment: line, blockComment: info.blockComment) {
            apply(edit, actionName: "Toggle Comment")
        }
    }

    func moveLines(up: Bool) {
        if let edit = TextTransforms.moveLines(nsText, selection: textView.selectedRange(), up: up) {
            apply(edit, actionName: up ? "Move Line Up" : "Move Line Down")
        }
    }

    func duplicate() {
        apply(TextTransforms.duplicate(nsText, selection: textView.selectedRange()), actionName: "Duplicate")
    }

    func deleteLines() {
        apply(TextTransforms.deleteLines(nsText, selection: textView.selectedRange()), actionName: "Delete Line")
    }

    func joinLines() {
        if let edit = TextTransforms.joinLines(nsText, selection: textView.selectedRange()) {
            apply(edit, actionName: "Join Lines")
        }
    }

    func sortLines(descending: Bool = false, unique: Bool = false) {
        if let edit = TextTransforms.sortLines(nsText, selection: textView.selectedRange(), descending: descending, unique: unique) {
            apply(edit, actionName: "Sort Lines")
        }
    }

    func transformSelection(_ name: String, _ transform: (String) -> String) {
        if let edit = TextTransforms.transform(nsText, selection: textView.selectedRange(), transform) {
            apply(edit, actionName: name)
        }
    }

    func trimTrailingWhitespace() -> Bool {
        guard let edit = TextTransforms.trimTrailingWhitespace(nsText, selection: textView.selectedRange()) else { return false }
        apply(edit, actionName: "Trim Trailing Whitespace")
        return true
    }

    func selectLine() {
        let range = TextTransforms.lineRange(nsText, textView.selectedRange())
        let selection = textView.selectedRange()
        // Repeating ⌘L extends the selection one line at a time (like Sublime).
        if selection == range, NSMaxRange(range) < textStorage.length {
            let next = nsText.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
            textView.setSelectedRange(NSUnionRange(range, next))
        } else {
            textView.setSelectedRange(range)
        }
    }

    /// Reformats the selection (or the whole document) as JSON.
    func reformatJSON(minify: Bool) throws {
        let selection = textView.selectedRange()
        let target = selection.length > 0 ? selection : NSRange(location: 0, length: textStorage.length)
        let source = nsText.substring(with: target)
        let indent = document.indentation.usesTabs ? "\t" : String(repeating: " ", count: document.indentation.width)
        let formatted = minify ? try TextTransforms.minifyJSON(source) : try TextTransforms.formatJSON(source, indent: indent)
        let trailing = selection.length == 0 && source.hasSuffix("\n") && !minify ? "\n" : ""
        let replacement = formatted + trailing
        apply(TextEdit(range: target, replacement: replacement,
                       selection: selection.length > 0 ? NSRange(location: target.location, length: (replacement as NSString).length) : NSRange(location: 0, length: 0)),
              actionName: minify ? "Minify JSON" : "Format JSON")
    }

    // MARK: Navigation

    func goTo(line: Int, column: Int? = nil) {
        // Clamp before doing arithmetic: links and the command line can pass any number.
        let index = max(1, min(line, engine.lineCount)) - 1
        let start = engine.lineStart(index)
        let end = max(start, engine.lineContentEnd(index))
        unfoldIfNeeded(NSRange(location: start, length: end - start))
        let location = column.map { start + max(0, min($0, end - start + 1) - 1) } ?? start
        textView.setSelectedRange(NSRange(location: location, length: 0))
        scrollToCenter(NSRange(location: start, length: end - start))
        if end > start { textView.showFindIndicator(for: NSRange(location: start, length: end - start)) }
        focus()
    }

    func reveal(range: NSRange, select: Bool = true, indicator: Bool = true) {
        let range = clamp(range)
        unfoldIfNeeded(range)
        if select { textView.setSelectedRange(range) }
        scrollToCenter(range)
        if indicator, range.length > 0 { textView.showFindIndicator(for: range) }
    }

    /// Scrolls so that `range` sits in the middle of the viewport (when it isn't already visible).
    func scrollToCenter(_ range: NSRange) {
        // Non-contiguous layout positions the target without laying out everything above it.
        let location = min(range.location, textStorage.length)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: location, length: min(textStorage.length - location, max(range.length, 1))))
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        if range.length == 0, rect.height == 0 { rect.size.height = lineHeight }
        rect.origin.y += textView.textContainerOrigin.y
        let clip = scrollView.contentView
        if clip.documentVisibleRect.insetBy(dx: 0, dy: lineHeight * 2).contains(NSPoint(x: clip.documentVisibleRect.midX, y: rect.midY)) { return }
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        let y = min(max(0, rect.midY - clip.bounds.height / 2), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Find

    var hasFindMatches: Bool { !findMatches.isEmpty }

    /// Highlights every match of `query`; when `reveal` is set, selects the match nearest the
    /// caret (incremental search). Returns the number of matches.
    @discardableResult
    func find(_ query: String, options: FindOptions, reveal: Bool) throws -> Int {
        clearFindHighlights()
        guard !query.isEmpty else {
            findMatches = []
            currentMatchIndex = nil
            return 0
        }
        if findAnchor == nil { findAnchor = textView.selectedRange().location }
        findMatches = try FindEngine.matches(of: query, in: nsText, options: options)
        if findMatches.isEmpty {
            currentMatchIndex = nil
        } else if reveal {
            let anchor = findAnchor ?? 0
            currentMatchIndex = findMatches.firstIndex { $0.location >= anchor } ?? 0
        } else {
            let selection = textView.selectedRange()
            currentMatchIndex = findMatches.firstIndex { $0 == selection } ?? findMatches.firstIndex { $0.location >= selection.location }
        }
        repaintFindHighlights()
        if reveal, let index = currentMatchIndex { revealMatch(index) }
        return findMatches.count
    }

    func findNext(forward: Bool) {
        guard !findMatches.isEmpty else { return }
        let selection = textView.selectedRange()
        let index: Int
        if let current = currentMatchIndex, current < findMatches.count, findMatches[current] == selection {
            index = forward ? (current + 1) % findMatches.count : (current - 1 + findMatches.count) % findMatches.count
        } else if forward {
            index = findMatches.firstIndex { $0.location >= NSMaxRange(selection) } ?? 0
        } else {
            index = findMatches.lastIndex { NSMaxRange($0) <= selection.location } ?? findMatches.count - 1
        }
        currentMatchIndex = index
        findAnchor = findMatches[index].location
        repaintFindHighlights()
        revealMatch(index)
    }

    private func revealMatch(_ index: Int) {
        let range = findMatches[index]
        unfoldIfNeeded(range)
        textView.setSelectedRange(range)
        scrollToCenter(range)
        textView.showFindIndicator(for: range)
    }

    func replaceCurrent(query: String, template: String, options: FindOptions) throws {
        if currentMatchIndex == nil || findMatches.isEmpty { try find(query, options: options, reveal: true) }
        guard let index = currentMatchIndex, index < findMatches.count else { return }
        let range = findMatches[index]
        guard let replacement = FindEngine.replacement(for: range, in: nsText, pattern: query, template: template, options: options) else {
            // The text changed since the search: search again and let the next click replace.
            findAnchor = range.location
            try find(query, options: options, reveal: true)
            return
        }
        apply(TextEdit(range: range, replacement: replacement, selection: NSRange(location: range.location + (replacement as NSString).length, length: 0)), actionName: "Replace")
        findAnchor = range.location + (replacement as NSString).length
        try find(query, options: options, reveal: true)
    }

    func replaceAll(query: String, template: String, options: FindOptions) throws -> Int {
        let edits = try FindEngine.replaceAll(in: nsText, pattern: query, template: template, options: options)
        guard applyReplacements(edits, actionName: "Replace All") else { return 0 }
        try find(query, options: options, reveal: false)
        return edits.count
    }

    func endFind() {
        findRefreshTask?.cancel()
        clearFindHighlights()
        findMatches = []
        currentMatchIndex = nil
        findAnchor = nil
    }

    private func scheduleFindRefresh() {
        findRefreshTask?.cancel()
        findRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            let workspace = Workspace.shared
            guard workspace.findBarVisible, workspace.selectedDocument === self.document else {
                self.endFind()
                return
            }
            _ = try? self.find(workspace.findQuery, options: workspace.findOptions, reveal: false)
            workspace.findMatchCount = self.findMatches.count
            workspace.findCurrentIndex = self.currentMatchIndex
        }
    }

    private func clearFindHighlights() {
        let full = NSRange(location: 0, length: textStorage.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        bracketRanges = []
    }

    private func repaintFindHighlights() {
        let full = NSRange(location: 0, length: textStorage.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        let matchColor = theme.findMatch.nsColor
        for range in findMatches.prefix(50_000) where NSMaxRange(range) <= textStorage.length {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: matchColor, forCharacterRange: range)
        }
        if let index = currentMatchIndex, index < findMatches.count, NSMaxRange(findMatches[index]) <= textStorage.length {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: theme.findCurrent.nsColor, forCharacterRange: findMatches[index])
        }
        bracketRanges = []
        updateBracketHighlight()
    }

    /// The minimap is part of the chrome: collapsing the sidebar ("just the text") hides it too.
    func updateMinimapVisibility() {
        let settings = AppSettings.shared
        rootView.showsMinimap = settings.showMinimap && settings.showsSidebar
    }

    // MARK: Git changes

    /// Reads the file's staged version from git again, then refreshes the change markers. Called
    /// when the file is opened, saved or reloaded, and when git's state may have changed.
    func refreshGitBase() {
        gitBaseTask?.cancel()
        guard AppSettings.shared.showGitChanges, let url = document.fileURL, !document.isBinary,
              textStorage.length < 4_000_000 else {
            gitBase = nil
            gitBaseDate = nil
            gitDiffTask?.cancel()
            setGitChanges([])
            return
        }
        let encoding = document.encoding
        gitBaseDate = .now
        gitBaseTask = Task { [weak self] in
            let base = await Task.detached(priority: .utility) { () -> [UInt64]? in
                guard let data = Git.indexVersion(of: url), data.count < 8_000_000,
                      let decoded = try? TextFileCodec.decode(data, forced: encoding) else { return nil }
                return LineDiff.lineHashes(decoded.text)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.gitBase = base
            self.scheduleGitDiff(immediate: true)
        }
    }

    /// Refreshes the staged version unless it was read in the last `seconds`.
    func refreshGitBase(ifOlderThan seconds: TimeInterval) {
        if let date = gitBaseDate, Date.now.timeIntervalSince(date) < seconds { return }
        refreshGitBase()
    }

    /// Forgets when the staged version was read, so the next `refreshGitBase(ifOlderThan:)` reads it.
    func markGitBaseStale() {
        gitBaseDate = nil
    }

    private func scheduleGitDiff(immediate: Bool = false) {
        gitDiffTask?.cancel()
        guard let base = gitBase else {
            setGitChanges([])
            return
        }
        gitDiffTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(300)) }
            guard let self, !Task.isCancelled else { return }
            let snapshot = self.textStorage.string
            let version = self.textVersion
            let changes = await Task.detached(priority: .utility) {
                LineDiff.changes(from: base, to: LineDiff.lineHashes(snapshot))
            }.value
            guard !Task.isCancelled, version == self.textVersion else { return }
            self.setGitChanges(changes)
        }
    }

    private func setGitChanges(_ changes: [LineChange]) {
        guard changes != gitChanges else { return }
        gitChanges = changes
        gutter.needsDisplay = true
        if rootView.isMinimapVisible { minimap.needsDisplay = true }
    }

    // MARK: Folding

    var supportsFolding: Bool { FoldingAnalyzer.supportsFolding(document.language) }

    /// Recomputes foldable regions (in the background for large files).
    func scheduleFoldAnalysis(immediate: Bool = false) {
        foldAnalysisTask?.cancel()
        guard supportsFolding else {
            if !foldRegions.isEmpty { foldRegions = [] }
            return
        }
        if immediate, textStorage.length < 300_000 {
            foldRegions = FoldingAnalyzer.regions(in: nsText, language: document.language)
            foldRegionsVersion = textVersion
            gutter.needsDisplay = true
            return
        }
        foldAnalysisTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(immediate ? 10 : 350))
            guard let self, !Task.isCancelled else { return }
            let snapshot = self.textStorage.string
            let version = self.textVersion
            let language = self.document.language
            let regions = await Task.detached(priority: .utility) {
                FoldingAnalyzer.regions(in: snapshot as NSString, language: language)
            }.value
            guard !Task.isCancelled, version == self.textVersion else { return }
            self.foldRegions = regions
            self.foldRegionsVersion = version
            self.gutter.needsDisplay = true
        }
    }

    private func refreshFoldRegionsNow() {
        guard supportsFolding, foldRegionsVersion != textVersion else { return }
        foldAnalysisTask?.cancel()
        foldRegions = FoldingAnalyzer.regions(in: nsText, language: document.language)
        foldRegionsVersion = textVersion
    }

    func foldRegion(startingOnLine line: Int) -> FoldRegion? {
        guard line >= 0, line < engine.lineCount else { return nil }
        return foldRegions.region(startingAtLineEnd: engine.lineContentEnd(line))
    }

    func isFolded(_ region: FoldRegion) -> Bool { foldState.isFolded(region.hiddenRange) }

    func toggleFold(atLine line: Int) {
        guard let region = foldRegion(startingOnLine: line) else { return }
        let previous = layoutManager.foldSpans
        if foldState.isFolded(region.hiddenRange) {
            foldState.unfold(region.hiddenRange)
        } else {
            foldState.fold(region.hiddenRange)
        }
        applyFoldChange(from: previous)
    }

    /// Folds the region starting on the caret's line, or the innermost one around the caret.
    func foldAtCaret() {
        refreshFoldRegionsNow()
        let caret = textView.selectedRange().location
        let line = engine.lineIndex(containing: caret)
        var target = foldRegion(startingOnLine: line).flatMap { isFolded($0) ? nil : $0 }
        if target == nil {
            target = foldRegions
                .filter { $0.hiddenStart < caret && caret <= $0.hiddenEnd && !isFolded($0) }
                .max { $0.hiddenStart < $1.hiddenStart }
        }
        guard let target else { NSSound.beep(); return }
        let previous = layoutManager.foldSpans
        foldState.fold(target.hiddenRange)
        applyFoldChange(from: previous)
    }

    func unfoldAtCaret() {
        let caret = textView.selectedRange().location
        let lineEnd = engine.lineContentEnd(engine.lineIndex(containing: caret))
        let targets = foldState.folded.filter { $0.location == lineEnd || ($0.location < caret && caret <= NSMaxRange($0)) }
        guard !targets.isEmpty else { NSSound.beep(); return }
        let previous = layoutManager.foldSpans
        for target in targets { foldState.unfold(target) }
        applyFoldChange(from: previous)
    }

    /// Folds every region at `level` (1 = outermost) and deeper. Without a level, keeps the
    /// outermost region open when there are deeper ones (a JSON file shows its top-level keys).
    func foldAll(level: Int? = nil) {
        refreshFoldRegionsNow()
        guard !foldRegions.isEmpty else { NSSound.beep(); return }
        let minDepth = level.map { max(0, $0 - 1) } ?? (foldRegions.contains { $0.depth >= 1 } ? 1 : 0)
        let previous = layoutManager.foldSpans
        foldState.fold(contentsOf: foldRegions.filter { $0.depth >= minDepth }.map(\.hiddenRange))
        applyFoldChange(from: previous)
    }

    func unfoldAll() {
        guard !foldState.isEmpty else { return }
        let previous = layoutManager.foldSpans
        foldState.unfoldAll()
        applyFoldChange(from: previous)
    }

    func unfold(range: NSRange) {
        let previous = layoutManager.foldSpans
        foldState.unfold(range)
        applyFoldChange(from: previous)
    }

    /// Unfolds whatever hides part of `range` (outer folds first, then nested ones they revealed).
    func unfoldIfNeeded(_ range: NSRange) {
        guard !foldState.isEmpty else { return }
        let previous = layoutManager.foldSpans
        var spans = previous
        var changed = false
        for _ in 0..<64 {
            let hiding = spans.filter { span in
                NSLocationInRange(range.location, span.hidden)
                    || (span.hidesToEnd && range.location == NSMaxRange(span.hidden))
                    || NSIntersectionRange(span.hidden, range).length > 0
            }
            guard !hiding.isEmpty else { break }
            for span in hiding { foldState.unfold(span.fold) }
            spans = makeFoldSpans()
            changed = true
        }
        if changed { applyFoldChange(from: previous, current: spans) }
    }

    /// Layout spans for the effective folds: each hides the lines after the fold's first line
    /// through its closing line, whose text (`},`) is drawn after the `⋯` pill instead.
    private func makeFoldSpans() -> [FoldSpan] {
        let folds = foldState.effective
        guard !folds.isEmpty else { return [] }
        let text = nsText
        let length = text.length
        var spans: [FoldSpan] = []
        spans.reserveCapacity(folds.count)
        for (index, fold) in folds.enumerated() {
            let lineEnd = fold.location
            guard lineEnd < length, text.character(at: lineEnd) == 0x0A else { continue }
            let closingStart = min(NSMaxRange(fold), length)
            let closingLine = engine.lineIndex(containing: closingStart)
            let closingEnd = engine.lineContentEnd(closingLine)
            var hiddenEnd = closingEnd < length ? closingEnd + 1 : length
            var hidesToEnd = closingEnd >= length
            var preview = text.substring(with: NSRange(location: closingStart, length: max(0, closingEnd - closingStart)))
                .trimmingCharacters(in: .whitespaces)
            // The next fold starts on this one's closing line: keep that line visible.
            if index + 1 < folds.count, folds[index + 1].location < hiddenEnd {
                hiddenEnd = engine.lineStart(closingLine)
                hidesToEnd = false
                preview = ""
            }
            if let last = spans.last, lineEnd < NSMaxRange(last.hidden) { continue }
            spans.append(FoldSpan(lineEnd: lineEnd, hidden: NSRange(location: lineEnd + 1, length: max(0, hiddenEnd - lineEnd - 1)),
                                  fold: fold, preview: preview, previewIndex: closingStart, hidesToEnd: hidesToEnd))
        }
        return spans
    }

    private func applyFoldChange(from previous: [FoldSpan], current: [FoldSpan]? = nil) {
        let anchor = scrollAnchor()
        let current = current ?? makeFoldSpans()
        // Bring the line that will anchor the view on screen while the old layout is still valid:
        // NSTextView keeps its visible text in view when it resizes, and locating text deep inside
        // a fold that was just collapsed is slow.
        var target = anchor
        if let anchor {
            let line = anchorLine(anchor.line, in: current)
            if line != anchor.line {
                // The anchor line gets folded away: show the fold's first line in full instead.
                target = (line, max(0, anchor.offset))
                scroll(toLine: line, offset: max(0, anchor.offset))
            }
        }
        layoutManager.foldSpans = current
        let changed = Set(previous.map(\.extent)).symmetricDifference(current.map(\.extent))
        invalidateFoldLayout(Array(changed))
        // Keep the caret out of hidden text.
        let selection = textView.selectedRange()
        if let span = layoutManager.spanHidingCaret(at: selection.location) {
            textView.setSelectedRange(NSRange(location: span.lineEnd, length: 0))
        }
        if let target { scroll(toLine: target.line, offset: target.offset) }
        gutter.needsDisplay = true
        textView.needsDisplay = true
        styleVisible()
    }

    /// The first visible line and its distance from the top of the viewport.
    private func scrollAnchor() -> (line: Int, offset: CGFloat)? {
        guard textStorage.length > 0 else { return nil }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: max(0, visible.minY - origin.y)), in: textContainer)
        var character = layoutManager.characterIndexForGlyph(at: glyph)
        if let span = layoutManager.hiddenSpan(at: character) { character = span.lineEnd }
        let line = engine.lineIndex(containing: character)
        let rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: engine.lineStart(line)),
                                                  effectiveRange: nil, withoutAdditionalLayout: true)
        return (line, rect.minY + origin.y - visible.minY)
    }

    /// `line`, or the first line of the fold in `spans` that hides it.
    private func anchorLine(_ line: Int, in spans: [FoldSpan]) -> Int {
        guard line < engine.lineCount, !spans.isEmpty else { return line }
        let start = engine.lineStart(line)
        var lo = 0, hi = spans.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let span = spans[mid]
            if start < span.hidden.location { hi = mid - 1 } else if start >= NSMaxRange(span.hidden), !span.hidesToEnd { lo = mid + 1 } else {
                return engine.lineIndex(containing: span.lineEnd)
            }
        }
        return line
    }

    /// Scrolls so `line` starts `offset` points below the top of the viewport, laying out only
    /// around that line.
    private func scroll(toLine line: Int, offset: CGFloat) {
        guard line < engine.lineCount else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: engine.lineStart(line))
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: glyph, length: 1))
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard rect.height > 0 else { return }
        let clip = scrollView.contentView
        let y = max(0, rect.minY + textView.textContainerOrigin.y - offset)
        guard abs(y - clip.bounds.minY) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func invalidateFoldLayout(_ ranges: [NSRange]) {
        guard !ranges.isEmpty else { return }
        let length = textStorage.length
        var lower = length, upper = 0
        for range in ranges {
            lower = min(lower, range.location)
            upper = max(upper, NSMaxRange(range) + 1)
        }
        lower = min(lower, length)
        upper = min(max(upper, lower), length)
        let affected = nsText.lineRange(for: NSRange(location: lower, length: upper - lower))
        layoutManager.invalidateLayout(forCharacterRange: affected, actualCharacterRange: nil)
        textView.needsDisplay = true
    }

    // MARK: Bracket matching

    private func updateBracketHighlight() {
        for range in bracketRanges where NSMaxRange(range) <= textStorage.length {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            if findMatches.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: theme.findMatch.nsColor, forCharacterRange: range)
            }
        }
        bracketRanges = []
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return }
        let text = nsText
        for candidate in [selection.location - 1, selection.location] where candidate >= 0 && candidate < text.length {
            if let match = Self.matchingBracket(in: text, at: candidate) {
                bracketRanges = [NSRange(location: candidate, length: 1), NSRange(location: match, length: 1)]
                break
            }
        }
        let color = theme.accent.withAlpha(theme.isDark ? 0.32 : 0.22).nsColor
        for range in bracketRanges {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
        }
    }

    private static func matchingBracket(in text: NSString, at index: Int) -> Int? {
        let c = text.character(at: index)
        let pairs: [unichar: (unichar, Bool)] = [0x28: (0x29, true), 0x29: (0x28, false), 0x5B: (0x5D, true), 0x5D: (0x5B, false), 0x7B: (0x7D, true), 0x7D: (0x7B, false)]
        guard let (other, forward) = pairs[c] else { return nil }
        var depth = 0
        var i = index
        var steps = 0
        while i >= 0, i < text.length, steps < 100_000 {
            let d = text.character(at: i)
            if d == c { depth += 1 } else if d == other {
                depth -= 1
                if depth == 0 { return i }
            }
            i += forward ? 1 : -1
            steps += 1
        }
        return nil
    }
}
