// TEMPORARY: replaced by VibeCore's MarkdownRenderer once it lands. Delete this file then.
import Foundation

nonisolated struct MarkdownRenderOptions: Sendable {
    var codeHighlighter: (@Sendable (String, String?) -> String?)?
    var sourceLineAttributes: Bool
    var allowRawHTML: Bool
    init(codeHighlighter: (@Sendable (String, String?) -> String?)? = nil, sourceLineAttributes: Bool = true, allowRawHTML: Bool = true) {
        self.codeHighlighter = codeHighlighter
        self.sourceLineAttributes = sourceLineAttributes
        self.allowRawHTML = allowRawHTML
    }
}

nonisolated enum MarkdownRenderer {
    static func renderHTML(_ markdown: String, options: MarkdownRenderOptions = .init()) -> String {
        "<pre>" + markdown.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") + "</pre>"
    }
}
