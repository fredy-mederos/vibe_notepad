import AppKit
import WebKit

/// Live preview of an SVG document. WebKit renders the text (as an `<img>`, so scripts never run and
/// nothing is fetched) into a PDF, which an image viewer shows as a vector picture: sharp at any zoom,
/// with the same zoom, panning and backgrounds as images. Mistakes in the XML show over the last good
/// render, so typing doesn't make the picture flicker away.
final class SVGPreviewController: NSObject, WKNavigationDelegate {
    unowned let document: EditorDocument
    let viewer: ImageViewerController
    /// Off screen: it only turns the SVG into a PDF.
    private let renderer: WKWebView
    private var renderTask: Task<Void, Never>?
    private var isRendering = false
    private var needsRender = false
    /// The version being rendered.
    private var pending: SVGSource.Info?

    init(document: EditorDocument) {
        self.document = document
        viewer = ImageViewerController(document: document, loadsFile: false)
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        configuration.websiteDataStore = .nonPersistent()
        renderer = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 150), configuration: configuration)
        super.init()
        // Transparent parts stay transparent in the PDF.
        renderer.setValue(false, forKey: "drawsBackground")
        renderer.navigationDelegate = self
        render()
    }

    /// Called after every edit: renders again once typing pauses.
    func textDidChange() {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.render()
        }
    }

    func render() {
        guard !isRendering else {
            needsRender = true
            return
        }
        isRendering = true
        let text = document.text
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { SVGSource.inspect(text) }.value
            guard let self else { return }
            switch result {
            case .failure(let problem):
                self.viewer.showRenderError(problem.message)
                self.finishRender()
            case .success(let info):
                self.pending = info
                self.renderer.frame = NSRect(origin: .zero, size: info.size)
                self.renderer.loadHTMLString(Self.page(info), baseURL: nil)
            }
        }
    }

    private func finishRender() {
        isRendering = false
        pending = nil
        if needsRender {
            needsRender = false
            render()
        }
    }

    /// Only the picture, at its size, on nothing; the page may load nothing but it.
    private static func page(_ info: SVGSource.Info) -> String {
        let width = info.size.width, height = info.size.height
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html, body { margin: 0; padding: 0; background: transparent; overflow: hidden }
        img { display: block; width: \(width)px; height: \(height)px }</style>
        </head><body><img src="data:image/svg+xml;base64,\(info.base64)"></body></html>
        """
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let info = pending else { return finishRender() }
        Task {
            // Well-formed XML can still be an SVG WebKit can't draw.
            let script = "try { await document.images[0].decode(); return true } catch (error) { return false }"
            let decoded = (try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient)) as? Bool ?? false
            if decoded {
                let configuration = WKPDFConfiguration()
                configuration.rect = CGRect(origin: .zero, size: info.size)
                do {
                    let pdf = try await webView.pdf(configuration: configuration)
                    if let picture = NSImage(data: pdf) {
                        picture.size = info.size
                        viewer.showVector(picture, details: info.details)
                    } else {
                        viewer.showRenderError("The SVG couldn’t be drawn.")
                    }
                } catch {
                    viewer.showRenderError(error.localizedDescription)
                }
            } else {
                viewer.showRenderError("WebKit can’t draw this SVG.")
            }
            finishRender()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        viewer.showRenderError(error.localizedDescription)
        finishRender()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        viewer.showRenderError(error.localizedDescription)
        finishRender()
    }

    func tearDown() {
        renderTask?.cancel()
        renderer.stopLoading()
        renderer.navigationDelegate = nil
        viewer.tearDown()
    }
}

/// What the preview needs from an SVG's text: that it's well-formed XML with an `<svg>` root, and its
/// size in points (its width and height, else its viewBox's, else 300 × 150, like browsers).
nonisolated enum SVGSource {
    struct Info: Sendable {
        var size: CGSize
        /// The text to draw, base64-encoded (with the SVG namespace added when it was left out, as
        /// browsers need it).
        var base64: String
        var details: ImageDetails
    }

    struct Problem: Error, Sendable {
        let message: String
    }

    static let namespace = "http://www.w3.org/2000/svg"

    static func inspect(_ text: String) -> Result<Info, Problem> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(Problem(message: "The SVG is empty.")) }
        let xml: XMLDocument
        do {
            // External DTDs (the SVG 1.1 doctype) are never fetched.
            xml = try XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever])
        } catch {
            // libxml2's messages: "Line 3: Opening and ending tag mismatch: rect line 2 and svg".
            let message = error.localizedDescription.split(separator: "\n").first.map(String.init) ?? error.localizedDescription
            return .failure(Problem(message: message))
        }
        guard let root = xml.rootElement(), root.localName == "svg" else {
            return .failure(Problem(message: "The root element isn’t <svg>."))
        }

        // Browsers ignore an SVG without its namespace (and an xlink: prefix nobody declared).
        let declared = Set(root.namespaces?.compactMap(\.name) ?? [])
        var additions = ""
        if root.uri == nil, !declared.contains("") { additions += " xmlns=\"\(namespace)\"" }
        if !declared.contains("xlink"), text.contains("xlink:") { additions += " xmlns:xlink=\"http://www.w3.org/1999/xlink\"" }
        var markup = text
        if !additions.isEmpty, let start = markup.range(of: #"<svg(?=[\s>/])"#, options: .regularExpression) {
            markup.insert(contentsOf: additions, at: start.upperBound)
        }

        let size = intrinsicSize(width: root.attribute(forName: "width")?.stringValue,
                                 height: root.attribute(forName: "height")?.stringValue,
                                 viewBox: root.attribute(forName: "viewBox")?.stringValue)
        var details = ImageDetails()
        details.pixelWidth = Int(size.width.rounded())
        details.pixelHeight = Int(size.height.rounded())
        details.format = "SVG image"
        details.shortFormat = "SVG"
        details.hasAlpha = true
        details.fileSize = text.utf8.count
        return .success(Info(size: size, base64: Data(markup.utf8).base64EncodedString(), details: details))
    }

    static func intrinsicSize(width: String?, height: String?, viewBox: String?) -> CGSize {
        let width = length(width), height = length(height)
        let box = viewBox.flatMap { value -> CGSize? in
            let numbers = value.split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline || $0 == "\t" }).compactMap { Double($0) }
            guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
            return CGSize(width: numbers[2], height: numbers[3])
        }
        let size: CGSize = switch (width, height, box) {
        case (let width?, let height?, _): CGSize(width: width, height: height)
        case (let width?, nil, let box?): CGSize(width: width, height: width * box.height / box.width)
        case (nil, let height?, let box?): CGSize(width: height * box.width / box.height, height: height)
        case (nil, nil, let box?): box
        default: CGSize(width: width ?? 300, height: height ?? 150)
        }
        let limit = CGFloat(ImageFile.maximumPixelSize)
        return CGSize(width: min(limit, max(1, size.width)), height: min(limit, max(1, size.height)))
    }

    /// A length in CSS pixels ("24", "24px", "18pt", "2in"…); nil for percentages and nonsense.
    static func length(_ value: String?) -> CGFloat? {
        guard var text = value?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty, !text.hasSuffix("%") else { return nil }
        let units: [(String, CGFloat)] = [("px", 1), ("pt", 4 / 3), ("pc", 16), ("mm", 96 / 25.4), ("cm", 96 / 2.54), ("in", 96), ("em", 16), ("ex", 8)]
        var factor: CGFloat = 1
        if let unit = units.first(where: { text.hasSuffix($0.0) }) {
            text.removeLast(unit.0.count)
            factor = unit.1
        }
        guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number > 0 else { return nil }
        return CGFloat(number) * factor
    }
}
