import AppKit
import UniformTypeIdentifiers
import VibeCore
import WebKit

/// Live Markdown preview for one document, rendered by `MarkdownRenderer` into a WKWebView.
/// Page scripts are disabled; the app talks to the page through an isolated content world.
final class MarkdownPreviewController: NSObject, WKNavigationDelegate {
    unowned let document: EditorDocument
    let webView: WKWebView

    private var isPageLoaded = false
    private var renderTask: Task<Void, Never>?
    private var renderGeneration = 0
    /// Bumped on every edit; the page echoes the version it was rendered from with task clicks.
    private var textVersion = 0
    /// A task was toggled from the page: keep the preview where the reader is.
    private var keepsScrollOnNextRender = false
    private var templateURL: URL
    private var lastSync: (line: Int, fraction: Double, atEnd: Bool)?

    init(document: EditorDocument) {
        self.document = document
        self.templateURL = AppPaths.previewDirectory.appendingPathComponent("\(document.id.uuidString).html")

        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: PreviewTemplate.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController = content
        webView = PreviewWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        super.init()
        (webView as? PreviewWebView)?.document = document

        content.add(WeakMessageHandler(self), contentWorld: .defaultClient, name: "vibe")
        webView.navigationDelegate = self
        webView.alphaValue = 0
        applyChrome()
        reloadTemplate()
    }

    // MARK: Rendering

    func reloadTemplate() {
        isPageLoaded = false
        let settings = AppSettings.shared
        let base = document.fileURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        let html = PreviewTemplate.page(baseURL: base, theme: settings.theme, fontFamily: settings.previewFont.css, fontSize: settings.previewFontSize)
        do {
            try html.write(to: templateURL, atomically: true, encoding: .utf8)
            webView.loadFileURL(templateURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        } catch {
            webView.loadHTMLString(html, baseURL: base)
        }
    }

    /// Called after every edit.
    func textDidChange() {
        textVersion += 1
        setNeedsRender()
    }

    /// Debounced re-render.
    func setNeedsRender() {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            await self?.render()
        }
    }

    func render() async {
        guard isPageLoaded else { return }
        renderGeneration += 1
        let generation = renderGeneration
        let version = textVersion
        let markdown = document.text
        let html: String
        if markdown.utf16.count > 250_000 {
            html = await Task.detached(priority: .userInitiated) { Self.renderHTML(markdown) }.value
        } else {
            html = Self.renderHTML(markdown)
        }
        guard generation == renderGeneration else { return }
        webView.callAsyncJavaScript("window.vibe && window.vibe.update(html, version)", arguments: ["html": html, "version": version], in: nil, in: .defaultClient) { [weak self] _ in
            guard let self else { return }
            if self.webView.alphaValue < 1 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    self.webView.animator().alphaValue = 1
                }
            }
            if self.keepsScrollOnNextRender {
                self.keepsScrollOnNextRender = false
            } else {
                self.syncScroll(force: true)
            }
        }
    }

    nonisolated static func renderHTML(_ markdown: String) -> String {
        let options = MarkdownRenderOptions(codeHighlighter: { code, language in
            guard let language, let id = LanguageRegistry.language(forFenceInfo: language) else { return nil }
            return SyntaxHighlighter.html(code, language: id)
        }, sourceLineAttributes: true, allowRawHTML: true)
        return MarkdownRenderer.renderHTML(markdown, options: options)
    }

    func applyTheme() {
        applyChrome()
        guard isPageLoaded else { return }
        let settings = AppSettings.shared
        let css = PreviewTemplate.themeCSS(theme: settings.theme, fontFamily: settings.previewFont.css, fontSize: settings.previewFontSize)
        webView.callAsyncJavaScript("window.vibe && window.vibe.setTheme(css)", arguments: ["css": css], in: nil, in: .defaultClient, completionHandler: nil)
    }

    private func applyChrome() {
        let theme = AppSettings.shared.theme
        webView.underPageBackgroundColor = theme.background.nsColor
        webView.appearance = theme.appearance
    }

    // MARK: Find

    /// Finds text in the rendered page (used when only the preview is visible).
    func find(_ query: String, forward: Bool, caseSensitive: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        guard !query.isEmpty else { return completion(false) }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = caseSensitive
        configuration.wraps = true
        webView.find(query, configuration: configuration) { result in
            completion(result.matchFound)
        }
    }

    // MARK: Scroll sync

    /// Mirrors the editor's scroll position (split mode).
    func syncScroll(force: Bool = false) {
        guard isPageLoaded, AppSettings.shared.syncScroll, document.markdownMode == .split,
              let editor = document.loadedEditor else { return }
        let position = editor.topVisibleLine()
        if !force, let last = lastSync, last.line == position.line, abs(last.fraction - position.fraction) < 0.02, last.atEnd == position.atEnd { return }
        lastSync = position
        webView.callAsyncJavaScript("window.vibe && window.vibe.scrollToLine(line, fraction, atEnd)",
                                    arguments: ["line": position.line, "fraction": position.fraction, "atEnd": position.atEnd],
                                    in: nil, in: .defaultClient, completionHandler: nil)
    }

    // MARK: Messages from the page

    fileprivate func handle(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "toggleTask":
            guard let line = message["line"] as? Int else { return }
            // The page was rendered from older text (lines may have moved): just re-render.
            guard (message["version"] as? Int) == textVersion else {
                Task { await render() }
                return
            }
            toggleTask(atLine: line, checked: message["checked"] as? Bool)
        default:
            break
        }
    }

    /// Clicking a checkbox in the preview sets `[ ]` / `[x]` in the source.
    private func toggleTask(atLine line: Int, checked: Bool?) {
        let editor = document.editor
        guard line >= 0, line < editor.engine.lineCount else { return }
        let start = editor.engine.lineStart(line)
        let end = editor.engine.lineContentEnd(line)
        let text = editor.nsText.substring(with: NSRange(location: start, length: end - start))
        guard let regex = try? NSRegularExpression(pattern: #"^(\s*(?:>\s*)*(?:[-*+]|\d{1,9}[.)])\s+\[)([ xX])(\])"#),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return }
        let markRange = match.range(at: 2)
        let current = (text as NSString).substring(with: markRange)
        let replacement = (checked ?? (current == " ")) ? "x" : " "
        guard replacement != current.lowercased() else { return }
        let range = NSRange(location: start + markRange.location, length: 1)
        let selection = editor.textView.selectedRange()
        keepsScrollOnNextRender = true
        editor.apply(TextEdit(range: range, replacement: replacement, selection: selection), actionName: "Toggle Task", scroll: false)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("Vibe Notepad: preview failed to load: %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageLoaded = true
        applyTheme()
        Task { await render() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if url.standardizedFileURL == templateURL.standardizedFileURL, navigationAction.navigationType != .linkActivated {
            return decisionHandler(.allow)
        }
        guard navigationAction.navigationType == .linkActivated else {
            return decisionHandler(url.isFileURL && url.standardizedFileURL == templateURL.standardizedFileURL ? .allow : .cancel)
        }
        decisionHandler(.cancel)
        openLink(url)
    }

    private func openLink(_ url: URL) {
        // In-page anchors resolve against <base>, so they look like links to the folder.
        if let fragment = url.fragment, !fragment.isEmpty {
            let base = (document.fileURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL.path
            var withoutFragment = URLComponents(url: url, resolvingAgainstBaseURL: false)
            withoutFragment?.fragment = nil
            let target = withoutFragment?.url?.standardizedFileURL.path ?? ""
            if !url.isFileURL || target == base || target == base + "/" || target == document.fileURL?.path {
                let id = fragment.removingPercentEncoding ?? fragment
                webView.callAsyncJavaScript("window.vibe && window.vibe.scrollToAnchor(id)", arguments: ["id": id], in: nil, in: .defaultClient, completionHandler: nil)
                if url.isFileURL { return }
            }
        }
        guard url.isFileURL else {
            NSWorkspace.shared.open(url)
            return
        }
        let fileURL = URL(fileURLWithPath: url.path)
        let isText = UTType(filenameExtension: fileURL.pathExtension)?.conforms(to: .text) ?? true
        if isText || ImageFile.isImage(fileURL) || LanguageRegistry.detect(path: fileURL.path) != .plainText || fileURL.pathExtension.isEmpty {
            Workspace.shared.open(url: fileURL)
        } else {
            NSWorkspace.shared.open(fileURL)
        }
    }

    // MARK: Export

    func exportHTML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = ((document.fileURL?.deletingPathExtension().lastPathComponent) ?? "Untitled") + ".html"
        panel.directoryURL = document.fileURL?.deletingLastPathComponent()
        let markdown = document.text
        let document = self.document
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let settings = AppSettings.shared
                let body = Self.renderHTML(markdown)
                let base = document.fileURL?.deletingLastPathComponent() ?? url.deletingLastPathComponent()
                let html = PreviewTemplate.page(baseURL: base, theme: settings.theme, fontFamily: settings.previewFont.css, fontSize: settings.previewFontSize, body: body, standalone: true)
                do {
                    try html.write(to: url, atomically: true, encoding: .utf8)
                    Workspace.shared.toast("Exported \(url.lastPathComponent)", symbol: "square.and.arrow.up.fill")
                } catch {
                    Workspace.shared.presentError(error, title: "Couldn’t export HTML")
                }
            }
        }
        if let window = Workspace.shared.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    func tearDown() {
        renderTask?.cancel()
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.removeFromSuperview()
        try? FileManager.default.removeItem(at: templateURL)
    }
}

/// Breaks the retain cycle between WKUserContentController and the controller.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: MarkdownPreviewController?

    init(_ target: MarkdownPreviewController) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handle(message.body)
    }
}

/// The preview's web view. With the editor split, only the focused pane's preview accepts the keyboard
/// (see `EditorHost.isInFocusedPane`).
final class PreviewWebView: WKWebView {
    weak var document: EditorDocument?

    override var acceptsFirstResponder: Bool {
        guard super.acceptsFirstResponder else { return false }
        guard let document else { return true }
        return Workspace.shared.acceptsKeyboardFocus(document)
    }

    // A tab dragged over the preview goes to the pane (see `Workspace.tabDragMoved`).

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let document, Workspace.shared.isTabDrag(sender) else { return super.draggingEntered(sender) }
        return Workspace.shared.tabDragMoved(sender, over: document)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let document, Workspace.shared.isTabDrag(sender) else { return super.draggingUpdated(sender) }
        return Workspace.shared.tabDragMoved(sender, over: document)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard let sender, let document, Workspace.shared.isTabDrag(sender) else { return super.draggingExited(sender) }
        Workspace.shared.tabDragLeft(document)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Workspace.shared.isTabDrag(sender) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let document, Workspace.shared.isTabDrag(sender) else { return super.performDragOperation(sender) }
        return Workspace.shared.tabDropped(sender, on: document)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let sender, Workspace.shared.isTabDrag(sender) { return }
        super.concludeDragOperation(sender)
    }
}
