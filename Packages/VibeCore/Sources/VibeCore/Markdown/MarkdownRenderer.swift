import Foundation

// Public entry points of the GitHub-Flavored-Markdown renderer used by the live preview.
//
// Pipeline:
//   1. `MDSource`        – UTF-8 bytes + line table (\n, \r\n, \r), BOM/NUL cleanup.
//   2. `MDBlockParser`   – CommonMark block structure (+ GFM tables, footnotes, front matter).
//   3. `MDInlineParser`  – inline syntax with the CommonMark delimiter-stack algorithm.
//   4. `MDHTMLRenderer`  – HTML fragment with `data-line` attributes for scroll sync.

// MARK: - Options

/// Options controlling how Markdown is converted to HTML.
public struct MarkdownRenderOptions: Sendable {
    /// Returns highlighted HTML for a fenced/indented code block's contents (already HTML-escaped and span-wrapped),
    /// or nil to fall back to plain escaped text. `language` is the raw first word of the info string (nil if none).
    public var codeHighlighter: (@Sendable (_ code: String, _ language: String?) -> String?)?
    /// Emit data-line="N" (0-based source line index where the block starts) on block-level elements.
    public var sourceLineAttributes: Bool
    /// Pass raw HTML blocks and inline HTML through unchanged; when false, escape them as text.
    public var allowRawHTML: Bool

    /// Creates render options. The defaults emit `data-line` attributes and pass raw HTML through.
    public init(
        codeHighlighter: (@Sendable (String, String?) -> String?)? = nil,
        sourceLineAttributes: Bool = true,
        allowRawHTML: Bool = true
    ) {
        self.codeHighlighter = codeHighlighter
        self.sourceLineAttributes = sourceLineAttributes
        self.allowRawHTML = allowRawHTML
    }
}

// MARK: - Headings

/// A heading of a Markdown document, e.g. for an outline or a table of contents.
public struct MarkdownHeading: Sendable, Equatable {
    /// Heading level, 1...6.
    public let level: Int
    /// Plain heading text with inline markup stripped.
    public let text: String
    /// 0-based source line where the heading starts.
    public let line: Int
    /// The `id` used for the heading in the rendered HTML (GitHub-style slug, de-duplicated).
    public let anchor: String
}

// MARK: - Renderer

/// Converts GitHub-Flavored Markdown into an HTML fragment for the live preview.
public enum MarkdownRenderer {
    /// Renders `markdown` to an HTML fragment (no `<html>`/`<body>` wrapper).
    ///
    /// Never traps and runs in linear time for realistic input; pathological nesting is capped.
    public static func renderHTML(_ markdown: String, options: MarkdownRenderOptions = .init()) -> String {
        let document = MDDocument(markdown)
        var renderer = MDHTMLRenderer(document: document, options: options)
        return renderer.render()
    }

    /// Returns all headings of `markdown` in document order, with the same anchors `renderHTML` emits.
    public static func headings(_ markdown: String) -> [MarkdownHeading] {
        let document = MDDocument(markdown)
        return document.headings.map { block in
            MarkdownHeading(level: block.level, text: block.headingText, line: block.startLine, anchor: block.anchor)
        }
    }
}

// MARK: - Parsed document

/// A fully block-parsed document with resolved link references, footnotes and heading anchors.
struct MDDocument {
    let source: MDSource
    let root: MDBlock
    let references: [String: MDLinkReference]
    let footnotes: [String: MDBlock]
    let frontMatter: MDFrontMatter?
    /// Heading blocks in source order; `anchor` and `headingText` are filled in.
    let headings: [MDBlock]

    init(_ markdown: String) {
        let source = MDSource(markdown)
        var parser = MDBlockParser(source: source)
        parser.parse()
        self.source = source
        self.root = parser.root
        self.references = parser.references
        self.footnotes = parser.footnotes
        self.frontMatter = parser.frontMatter

        var collected: [MDBlock] = []
        MDDocument.collectHeadings(root, into: &collected)
        var inline = MDInlineParser(references: parser.references, footnotes: parser.footnotes)
        var slugger = MDSlugger()
        for heading in collected {
            let root = inline.parse(heading.content, 0, heading.content.count)
            let text = inline.plainText(root)
            heading.headingText = text
            heading.anchor = slugger.slug(for: text)
        }
        self.headings = collected
    }

    private static func collectHeadings(_ block: MDBlock, into result: inout [MDBlock]) {
        for child in block.children {
            if child.kind == .heading {
                result.append(child)
            } else if !child.children.isEmpty {
                collectHeadings(child, into: &result)
            }
        }
    }
}
