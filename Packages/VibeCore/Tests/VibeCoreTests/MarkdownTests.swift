import Foundation
import Testing
@testable import VibeCore

// MARK: - Helpers

/// Renders without `data-line` attributes so structural expectations stay readable.
private func mdHTML(_ markdown: String, lines: Bool = false, rawHTML: Bool = true) -> String {
    MarkdownRenderer.renderHTML(markdown, options: .init(sourceLineAttributes: lines, allowRawHTML: rawHTML))
}

/// Deterministic pseudo-random generator (MDSplitMix64) so fuzz failures are reproducible.
private struct MDSplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func mdMeasure(_ body: () -> Void) -> Duration {
    let clock = ContinuousClock()
    let start = clock.now
    body()
    return clock.now - start
}

// MARK: - Basics

@Suite("Markdown basics")
struct MarkdownBasicsTests {
    @Test func emptyAndWhitespaceOnlyDocuments() {
        #expect(mdHTML("") == "")
        #expect(mdHTML("   \n\t\n  ") == "")
        #expect(mdHTML("\n\n\n") == "")
        #expect(MarkdownRenderer.headings("").isEmpty)
    }

    @Test func paragraphsAndLazyContinuation() {
        #expect(mdHTML("aaa\nbbb\n\nccc") == "<p>aaa\nbbb</p>\n<p>ccc</p>\n")
        #expect(mdHTML("  aaa\n bbb") == "<p>aaa\nbbb</p>\n")
        #expect(mdHTML("> foo\nbar") == "<blockquote>\n<p>foo\nbar</p>\n</blockquote>\n")
        #expect(mdHTML("- foo\nbar") == "<ul>\n<li>foo\nbar</li>\n</ul>\n")
    }

    @Test func lineEndingsAreNormalized() {
        let expected = "<h1 id=\"title\">Title</h1>\n<p>one\ntwo</p>\n"
        #expect(mdHTML("# Title\none\ntwo") == expected)
        #expect(mdHTML("# Title\r\none\r\ntwo\r\n") == expected)
        #expect(mdHTML("# Title\rone\rtwo\r") == expected)
    }

    @Test func tabsExpandForBlockStructure() {
        #expect(mdHTML("\tfoo\tbaz") == "<pre><code>foo\tbaz</code></pre>\n")
        #expect(mdHTML("- foo\n\n\tbar") == "<ul>\n<li>\n<p>foo</p>\n<p>bar</p>\n</li>\n</ul>\n")
        #expect(mdHTML(">\t\tfoo") == "<blockquote>\n<pre><code>  foo</code></pre>\n</blockquote>\n")
        #expect(mdHTML("#\tFoo") == "<h1 id=\"foo\">Foo</h1>\n")
    }

    @Test func nulAndBOMAreHandled() {
        #expect(mdHTML("\u{FEFF}# Hi") == "<h1 id=\"hi\">Hi</h1>\n")
        #expect(mdHTML("a\u{0}b") == "<p>a\u{FFFD}b</p>\n")
    }

    @Test func textIsEscaped() {
        #expect(mdHTML("a < b > c & \"d\"") == "<p>a &lt; b &gt; c &amp; &quot;d&quot;</p>\n")
        #expect(mdHTML("AT&T") == "<p>AT&amp;T</p>\n")
    }
}

// MARK: - Headings

@Suite("Markdown headings")
struct MarkdownHeadingTests {
    @Test func atxHeadings() {
        #expect(mdHTML("# foo\n###### six\n####### seven") ==
            "<h1 id=\"foo\">foo</h1>\n<h6 id=\"six\">six</h6>\n<p>####### seven</p>\n")
        #expect(mdHTML("## foo ##\n### bar ###   ") == "<h2 id=\"foo\">foo</h2>\n<h3 id=\"bar\">bar</h3>\n")
        #expect(mdHTML("# foo#") == "<h1 id=\"foo\">foo#</h1>\n")
        #expect(mdHTML("#hashtag") == "<p>#hashtag</p>\n")
        #expect(mdHTML("    # code") == "<pre><code># code</code></pre>\n")
    }

    @Test func setextHeadings() {
        #expect(mdHTML("Foo *bar*\n===") == "<h1 id=\"foo-bar\">Foo <em>bar</em></h1>\n")
        #expect(mdHTML("Foo\nBar\n---") == "<h2 id=\"foo-bar\">Foo\nBar</h2>\n")
        #expect(mdHTML("Foo\n= =") == "<p>Foo\n= =</p>\n")
    }

    @Test func setextVersusThematicBreak() {
        #expect(mdHTML("Foo\n---\nbar") == "<h2 id=\"foo\">Foo</h2>\n<p>bar</p>\n")
        #expect(mdHTML("Foo\n\n---\n\nbar") == "<p>Foo</p>\n<hr />\n<p>bar</p>\n")
        #expect(mdHTML("- Foo\n---") == "<ul>\n<li>Foo</li>\n</ul>\n<hr />\n")
        #expect(mdHTML("> Foo\n---") == "<blockquote>\n<p>Foo</p>\n</blockquote>\n<hr />\n")
        #expect(mdHTML("***\n___\n- - -") == "<hr />\n<hr />\n<hr />\n")
        #expect(mdHTML("Foo\n***\nbar") == "<p>Foo</p>\n<hr />\n<p>bar</p>\n")
        #expect(mdHTML("_ _ _ _ a") == "<p>_ _ _ _ a</p>\n")
    }

    @Test func slugsFollowGitHubRules() {
        #expect(MDSlugger.slugify("Hello, World!") == "hello-world")
        #expect(MDSlugger.slugify("API v2.0 — Überblick") == "api-v20--überblick")
        #expect(MDSlugger.slugify("snake_case and-dash") == "snake_case-and-dash")
        #expect(MDSlugger.slugify("  spaced  ") == "--spaced--")
    }

    @Test func duplicateSlugsAreSuffixed() {
        let source = "# Intro\n## Intro\n## Intro!\n## Intro-1\n# ` code ` & *em*"
        let output = mdHTML(source)
        #expect(output.contains("<h1 id=\"intro\">Intro</h1>"))
        #expect(output.contains("<h2 id=\"intro-1\">Intro</h2>"))
        #expect(output.contains("<h2 id=\"intro-2\">Intro!</h2>"))
        #expect(output.contains("<h2 id=\"intro-1-1\">Intro-1</h2>"))
        #expect(output.contains("<h1 id=\"code--em\"><code>code</code> &amp; <em>em</em></h1>"))
    }

    @Test func headingsAPIMatchesRenderedAnchors() {
        let source = "---\ntitle: x\n---\n# Title\n\nText\n\nSub *one*\n---\n\n> ## Quoted [link](u)\n\n# Title\n"
        let headings = MarkdownRenderer.headings(source)
        #expect(headings == [
            MarkdownHeading(level: 1, text: "Title", line: 3, anchor: "title"),
            MarkdownHeading(level: 2, text: "Sub one", line: 7, anchor: "sub-one"),
            MarkdownHeading(level: 2, text: "Quoted link", line: 10, anchor: "quoted-link"),
            MarkdownHeading(level: 1, text: "Title", line: 12, anchor: "title-1"),
        ])
        let output = MarkdownRenderer.renderHTML(source)
        for heading in headings {
            #expect(output.contains("<h\(heading.level) id=\"\(heading.anchor)\" data-line=\"\(heading.line)\">"))
        }
    }
}

// MARK: - Containers

@Suite("Markdown containers")
struct MarkdownContainerTests {
    @Test func blockQuotes() {
        #expect(mdHTML("> # Foo\n> bar\nbaz") == "<blockquote>\n<h1 id=\"foo\">Foo</h1>\n<p>bar\nbaz</p>\n</blockquote>\n")
        #expect(mdHTML("> > > deep\nlazy") ==
            "<blockquote>\n<blockquote>\n<blockquote>\n<p>deep\nlazy</p>\n</blockquote>\n</blockquote>\n</blockquote>\n")
        #expect(mdHTML("> a\n\n> b") == "<blockquote>\n<p>a</p>\n</blockquote>\n<blockquote>\n<p>b</p>\n</blockquote>\n")
        #expect(mdHTML(">") == "<blockquote>\n</blockquote>\n")
    }

    @Test func listInsideBlockQuote() {
        #expect(mdHTML("> - one\n> - two\n>\n> after") ==
            "<blockquote>\n<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n<p>after</p>\n</blockquote>\n")
        #expect(mdHTML("> 1. a\n>    > nested quote") ==
            "<blockquote>\n<ol>\n<li>a\n<blockquote>\n<p>nested quote</p>\n</blockquote>\n</li>\n</ol>\n</blockquote>\n")
    }

    @Test func threeLevelNestedLists() {
        let source = "- one\n  - two\n    - three\n  - two b\n- one b"
        #expect(mdHTML(source) ==
            "<ul>\n<li>one\n<ul>\n<li>two\n<ul>\n<li>three</li>\n</ul>\n</li>\n<li>two b</li>\n</ul>\n</li>\n<li>one b</li>\n</ul>\n")
        #expect(mdHTML("1. a\n   1. b\n      - c") ==
            "<ol>\n<li>a\n<ol>\n<li>b\n<ul>\n<li>c</li>\n</ul>\n</li>\n</ol>\n</li>\n</ol>\n")
    }

    @Test func orderedListsAndStartAttribute() {
        #expect(mdHTML("1. a\n2. b") == "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n")
        #expect(mdHTML("3) a\n4) b") == "<ol start=\"3\">\n<li>a</li>\n<li>b</li>\n</ol>\n")
        #expect(mdHTML("0. zero") == "<ol start=\"0\">\n<li>zero</li>\n</ol>\n")
        #expect(mdHTML("1234567890. not a list") == "<p>1234567890. not a list</p>\n")
        // Only "1." may interrupt a paragraph.
        #expect(mdHTML("text\n2. two") == "<p>text\n2. two</p>\n")
        #expect(mdHTML("text\n1. one") == "<p>text</p>\n<ol>\n<li>one</li>\n</ol>\n")
    }

    @Test func changingMarkerStartsNewList() {
        #expect(mdHTML("- a\n- b\n+ c") == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n<ul>\n<li>c</li>\n</ul>\n")
        #expect(mdHTML("1. a\n2) b") == "<ol>\n<li>a</li>\n</ol>\n<ol start=\"2\">\n<li>b</li>\n</ol>\n")
    }

    @Test func tightVersusLooseLists() {
        #expect(mdHTML("- a\n- b") == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n")
        #expect(mdHTML("- a\n\n- b") == "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n")
        #expect(mdHTML("- a\n\n  more\n- b") ==
            "<ul>\n<li>\n<p>a</p>\n<p>more</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n")
        // Blank lines inside a nested list only loosen that nested list.
        #expect(mdHTML("- a\n  - b\n\n    c\n- d") ==
            "<ul>\n<li>a\n<ul>\n<li>\n<p>b</p>\n<p>c</p>\n</li>\n</ul>\n</li>\n<li>d</li>\n</ul>\n")
        // A trailing blank line does not make a list loose.
        #expect(mdHTML("- a\n- b\n\nafter") == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n<p>after</p>\n")
    }

    @Test func listItemContentColumns() {
        #expect(mdHTML("- one\n\n two") == "<ul>\n<li>one</li>\n</ul>\n<p>two</p>\n")
        #expect(mdHTML("- one\n\n  two") == "<ul>\n<li>\n<p>one</p>\n<p>two</p>\n</li>\n</ul>\n")
        #expect(mdHTML(" -    one\n\n     two") == "<ul>\n<li>one</li>\n</ul>\n<pre><code> two</code></pre>\n")
        #expect(mdHTML("-    one\n\n     two") == "<ul>\n<li>\n<p>one</p>\n<p>two</p>\n</li>\n</ul>\n")
        #expect(mdHTML("- foo\n\n      bar") == "<ul>\n<li>\n<p>foo</p>\n<pre><code>bar</code></pre>\n</li>\n</ul>\n")
        #expect(mdHTML("-\n  foo") == "<ul>\n<li>foo</li>\n</ul>\n")
        #expect(mdHTML("- a\n-\n- c") == "<ul>\n<li>a</li>\n<li></li>\n<li>c</li>\n</ul>\n")
    }

    @Test func fencedCodeInsideListItem() {
        let source = "1. Step:\n\n   ```swift\n   let x = 1\n     indented\n   ```\n\n2. Next"
        #expect(mdHTML(source) ==
            "<ol>\n<li>\n<p>Step:</p>\n<pre><code class=\"language-swift\">let x = 1\n  indented</code></pre>\n</li>\n<li>\n<p>Next</p>\n</li>\n</ol>\n")
        // An unclosed fence ends with its list item.
        #expect(mdHTML("- a\n  ```\n  code\n- b") ==
            "<ul>\n<li>a\n<pre><code>code</code></pre>\n</li>\n<li>b</li>\n</ul>\n")
    }

    @Test func fencedCodeInsideBlockQuote() {
        #expect(mdHTML("> ```\n> code\n> ```\n> text") ==
            "<blockquote>\n<pre><code>code</code></pre>\n<p>text</p>\n</blockquote>\n")
        #expect(mdHTML("> ```\n> aaa\n\nbbb") == "<blockquote>\n<pre><code>aaa</code></pre>\n</blockquote>\n<p>bbb</p>\n")
    }

    @Test func taskLists() {
        #expect(mdHTML("- [ ] todo\n- [x] done\n- [X] also\n- plain") ==
            "<ul class=\"contains-task-list\">\n"
            + "<li class=\"task-list-item\"><input type=\"checkbox\" class=\"task-list-item-checkbox\"> todo</li>\n"
            + "<li class=\"task-list-item\"><input type=\"checkbox\" class=\"task-list-item-checkbox\" checked> done</li>\n"
            + "<li class=\"task-list-item\"><input type=\"checkbox\" class=\"task-list-item-checkbox\" checked> also</li>\n"
            + "<li>plain</li>\n</ul>\n")
        #expect(mdHTML("- [ ] todo", lines: true) ==
            "<ul class=\"contains-task-list\" data-line=\"0\">\n<li class=\"task-list-item\" data-line=\"0\">"
            + "<input type=\"checkbox\" class=\"task-list-item-checkbox\" data-line=\"0\"> todo</li>\n</ul>\n")
        #expect(mdHTML("- [ ] a\n\n- [x] b").contains("<p><input type=\"checkbox\" class=\"task-list-item-checkbox\" checked> b</p>"))
        #expect(!mdHTML("- [ ]x\n- [y] z").contains("checkbox"))
        #expect(!mdHTML("- [ ] task").contains("disabled"))
    }
}

// MARK: - Leaf blocks

@Suite("Markdown leaf blocks")
struct MarkdownLeafBlockTests {
    @Test func fencedCodeBlocks() {
        #expect(mdHTML("```\n<a> & b\n```") == "<pre><code>&lt;a&gt; &amp; b</code></pre>\n")
        #expect(mdHTML("~~~ ruby startline=3\ndef x\n~~~") == "<pre><code class=\"language-ruby\">def x</code></pre>\n")
        #expect(mdHTML("````\naaa\n```\n``````") == "<pre><code>aaa\n```</code></pre>\n")
        #expect(mdHTML("~~~\naaa\n```\n~~~") == "<pre><code>aaa\n```</code></pre>\n")
        #expect(mdHTML("``` ```\naaa") == "<p><code> </code>\naaa</p>\n")
        #expect(mdHTML("```\n```") == "<pre><code></code></pre>\n")
        #expect(mdHTML("```c\"><script>\nx\n```") == "<pre><code class=\"language-c&quot;&gt;&lt;script&gt;\">x</code></pre>\n")
    }

    @Test func unclosedFenceRunsToEndOfDocument() {
        #expect(mdHTML("```js\nlet a = 1\n\n# not a heading") ==
            "<pre><code class=\"language-js\">let a = 1\n\n# not a heading</code></pre>\n")
        #expect(mdHTML("```") == "<pre><code></code></pre>\n")
    }

    @Test func indentedCodeBlocks() {
        #expect(mdHTML("    a\n      b\n\n    c\n\n") == "<pre><code>a\n  b\n\nc</code></pre>\n")
        #expect(mdHTML("Foo\n    bar") == "<p>Foo\nbar</p>\n")
        #expect(mdHTML("    foo\nbar") == "<pre><code>foo</code></pre>\n<p>bar</p>\n")
    }

    @Test func codeHighlighterIsUsed() {
        let options = MarkdownRenderOptions(codeHighlighter: { code, language in
            "<span class=\"hl\">[\(language ?? "nil")]\(code.count)</span>"
        }, sourceLineAttributes: false)
        #expect(MarkdownRenderer.renderHTML("```swift\nlet x\n```", options: options) ==
            "<pre><code class=\"language-swift\"><span class=\"hl\">[swift]5</span></code></pre>\n")
        #expect(MarkdownRenderer.renderHTML("    plain", options: options) ==
            "<pre><code><span class=\"hl\">[nil]5</span></code></pre>\n")
        let fallback = MarkdownRenderOptions(codeHighlighter: { _, _ in nil }, sourceLineAttributes: false)
        #expect(MarkdownRenderer.renderHTML("```\n<b>\n```", options: fallback) == "<pre><code>&lt;b&gt;</code></pre>\n")
    }

    @Test func htmlBlocks() {
        #expect(mdHTML("<div>\n*not md*\n</div>\n\n*md*") == "<div>\n*not md*\n</div>\n<p><em>md</em></p>\n")
        #expect(mdHTML("<details>\n<summary>More</summary>\n\nBody *text*\n\n</details>") ==
            "<details>\n<summary>More</summary>\n<p>Body <em>text</em></p>\n</details>\n")
        #expect(mdHTML("<!-- comment\n\nstill comment -->\nafter") == "<!-- comment\n\nstill comment -->\n<p>after</p>\n")
        #expect(mdHTML("<script>\nlet a = 1;\n\nlet b = 2;\n</script>\nok") ==
            "<script>\nlet a = 1;\n\nlet b = 2;\n</script>\n<p>ok</p>\n")
        #expect(mdHTML("<?php\necho 1;\n?>") == "<?php\necho 1;\n?>\n")
        #expect(mdHTML("<!DOCTYPE html>") == "<!DOCTYPE html>\n")
        #expect(mdHTML("<custom-tag>\n*x*\n</custom-tag>") == "<custom-tag>\n*x*\n</custom-tag>\n")
        // Type 7 cannot interrupt a paragraph.
        #expect(mdHTML("Foo\n<a href=\"bar\">\nbaz") == "<p>Foo\n<a href=\"bar\">\nbaz</p>\n")
    }

    @Test func rawHTMLCanBeDisabled() {
        #expect(mdHTML("<div onclick=\"x()\">hi</div>", rawHTML: false) ==
            "<p>&lt;div onclick=&quot;x()&quot;&gt;hi&lt;/div&gt;</p>\n")
        #expect(mdHTML("a <b>bold</b> <!-- c -->", rawHTML: false) ==
            "<p>a &lt;b&gt;bold&lt;/b&gt; &lt;!-- c --&gt;</p>\n")
        #expect(mdHTML("a <b>bold</b>") == "<p>a <b>bold</b></p>\n")
    }

    @Test func tables() {
        let source = "| Left | Center | Right | None |\n|:-----|:------:|------:|------|\n| a | b | c | d |\n| e | f | g | h |"
        #expect(mdHTML(source) ==
            "<table><thead><tr><th style=\"text-align: left\">Left</th><th style=\"text-align: center\">Center</th>"
            + "<th style=\"text-align: right\">Right</th><th>None</th></tr></thead><tbody>"
            + "<tr><td style=\"text-align: left\">a</td><td style=\"text-align: center\">b</td><td style=\"text-align: right\">c</td><td>d</td></tr>"
            + "<tr><td style=\"text-align: left\">e</td><td style=\"text-align: center\">f</td><td style=\"text-align: right\">g</td><td>h</td></tr>"
            + "</tbody></table>\n")
        #expect(mdHTML("a | b\n--|--") == "<table><thead><tr><th>a</th><th>b</th></tr></thead></table>\n")
        #expect(mdHTML("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |") ==
            "<table><thead><tr><th>a</th><th>b</th></tr></thead><tbody>"
            + "<tr><td>1</td><td></td></tr><tr><td>1</td><td>2</td></tr></tbody></table>\n")
        // Header and delimiter cell counts must match.
        #expect(mdHTML("| a | b |\n|---|\n| c |") == "<p>| a | b |\n|---|\n| c |</p>\n")
        // Tables end at a blank line or another block start.
        #expect(mdHTML("| a |\n|---|\n| b |\n> quote") ==
            "<table><thead><tr><th>a</th></tr></thead><tbody><tr><td>b</td></tr></tbody></table>\n"
            + "<blockquote>\n<p>quote</p>\n</blockquote>\n")
        #expect(mdHTML("Intro text\n| a |\n| - |\n| b |\n\nafter") ==
            "<p>Intro text</p>\n<table><thead><tr><th>a</th></tr></thead><tbody><tr><td>b</td></tr></tbody></table>\n<p>after</p>\n")
    }

    @Test func tableWithEscapedPipes() {
        let source = "| Code | Text |\n| --- | --- |\n| `a \\| b` | x \\| y |\n| **\\|** | `\\\\|` |"
        #expect(mdHTML(source) ==
            "<table><thead><tr><th>Code</th><th>Text</th></tr></thead><tbody>"
            + "<tr><td><code>a | b</code></td><td>x | y</td></tr>"
            + "<tr><td><strong>|</strong></td><td><code>\\|</code></td></tr></tbody></table>\n")
    }

    @Test func linkReferenceDefinitions() {
        #expect(mdHTML("[foo]: /url \"title\"\n\n[foo] and [FOO][] and [text][Foo]") ==
            "<p><a href=\"/url\" title=\"title\">foo</a> and <a href=\"/url\" title=\"title\">FOO</a> and <a href=\"/url\" title=\"title\">text</a></p>\n")
        #expect(mdHTML("[Foo   bar]:\n<my url>\n'title'\n\n[foo bar]") ==
            "<p><a href=\"my%20url\" title=\"title\">foo bar</a></p>\n")
        #expect(mdHTML("[a]: first\n[a]: second\n\n[a]") == "<p><a href=\"first\">a</a></p>\n")
        #expect(mdHTML("[foo]: /url \"title\" ok") == "<p>[foo]: /url &quot;title&quot; ok</p>\n")
        #expect(mdHTML("[undefined] [x][undefined]") == "<p>[undefined] [x][undefined]</p>\n")
        #expect(mdHTML("[foo]: /url") == "")
    }

    @Test func frontMatter() {
        let source = "---\ntitle: \"Hi\"\ntags: [a, b]\n---\n# Doc\n"
        #expect(mdHTML(source, lines: true) ==
            "<details class=\"front-matter\" data-line=\"0\"><summary>Front matter</summary>"
            + "<pre><code class=\"language-yaml\">title: &quot;Hi&quot;\ntags: [a, b]</code></pre></details>\n"
            + "<h1 id=\"doc\" data-line=\"4\">Doc</h1>\n")
        #expect(mdHTML("---\na: 1\n...\ntext").hasPrefix("<details class=\"front-matter\">"))
        // Never closed: normal Markdown.
        #expect(mdHTML("---\nnot: closed\n\ntext") == "<hr />\n<p>not: closed</p>\n<p>text</p>\n")
        // Only at the very start of the document.
        #expect(mdHTML("text\n\n---\na: b\n---") == "<p>text</p>\n<hr />\n<h2 id=\"a-b\">a: b</h2>\n")
        let highlighted = MarkdownRenderer.renderHTML("---\nk: v\n---", options: .init(codeHighlighter: { code, language in
            language == "yaml" ? "<i>\(code)</i>" : nil
        }, sourceLineAttributes: false))
        #expect(highlighted.contains("<code class=\"language-yaml\"><i>k: v</i></code>"))
    }

    @Test func githubAlerts() {
        #expect(mdHTML("> [!NOTE]\n> Useful *info*.\n>\n> More.", lines: true) ==
            "<div class=\"markdown-alert markdown-alert-note\" data-line=\"0\"><p class=\"markdown-alert-title\">Note</p>\n"
            + "<p data-line=\"1\">Useful <em>info</em>.</p>\n<p data-line=\"3\">More.</p>\n</div>\n")
        for (marker, title) in [("TIP", "Tip"), ("important", "Important"), ("Warning", "Warning"), ("CAUTION", "Caution")] {
            let output = mdHTML("> [!\(marker)]\n> body")
            #expect(output.hasPrefix("<div class=\"markdown-alert markdown-alert-\(title.lowercased())\"><p class=\"markdown-alert-title\">\(title)</p>"))
            #expect(output.contains("<p>body</p>"))
        }
        #expect(mdHTML("> [!NOTE] same line") == "<blockquote>\n<p>[!NOTE] same line</p>\n</blockquote>\n")
        #expect(mdHTML("> [!UNKNOWN]\n> x").hasPrefix("<blockquote>"))
    }

    @Test func footnotes() {
        let source = "Text[^1] and[^note] again[^1].\n\n[^1]: First *note*.\n[^note]: Second\n    continued.\n\n[^unused]: Never shown."
        let output = mdHTML(source)
        #expect(output.contains("Text<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup>"))
        #expect(output.contains("and<sup class=\"footnote-ref\"><a href=\"#fn-note\" id=\"fnref-note\">2</a></sup>"))
        #expect(output.contains("again<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1-2\">1</a></sup>"))
        #expect(output.contains("<section class=\"footnotes\"><ol><li id=\"fn-1\">First <em>note</em>. "
            + "<a href=\"#fnref-1\" class=\"footnote-backref\">↩</a> <a href=\"#fnref-1-2\" class=\"footnote-backref\">↩<sup>2</sup></a></li>"))
        #expect(output.contains("<li id=\"fn-note\">Second\ncontinued. <a href=\"#fnref-note\" class=\"footnote-backref\">↩</a></li></ol></section>"))
        #expect(!output.contains("Never shown"))
        #expect(mdHTML("Missing[^nope].") == "<p>Missing[^nope].</p>\n")
    }
}

// MARK: - Inlines

@Suite("Markdown inlines")
struct MarkdownInlineTests {
    @Test func backslashEscapesAndEntities() {
        #expect(mdHTML("\\*not em\\* \\[x] \\` \\\\") == "<p>*not em* [x] ` \\</p>\n")
        #expect(mdHTML("\\a \\φ") == "<p>\\a \\φ</p>\n")
        #expect(mdHTML("&amp; &copy; &#123; &#x1F600; &nbsp;") == "<p>&amp; &copy; &#123; &#x1F600; &nbsp;</p>\n")
        #expect(mdHTML("& &x; &#; &copy") == "<p>&amp; &amp;x; &amp;#; &amp;copy</p>\n")
    }

    @Test func codeSpans() {
        #expect(mdHTML("`code`") == "<p><code>code</code></p>\n")
        #expect(mdHTML("`` a ` b ``") == "<p><code>a ` b</code></p>\n")
        #expect(mdHTML("` `` `") == "<p><code>``</code></p>\n")
        #expect(mdHTML("`  `") == "<p><code>  </code></p>\n")
        #expect(mdHTML("`foo\nbar`") == "<p><code>foo bar</code></p>\n")
        #expect(mdHTML("`<b>&`") == "<p><code>&lt;b&gt;&amp;</code></p>\n")
        #expect(mdHTML("`unclosed") == "<p>`unclosed</p>\n")
        #expect(mdHTML("```foo``") == "<p>```foo``</p>\n")
        #expect(mdHTML("*a `*`*") == "<p><em>a <code>*</code></em></p>\n")
    }

    @Test func emphasisEdgeCases() {
        #expect(mdHTML("**bold *nested* bold**") == "<p><strong>bold <em>nested</em> bold</strong></p>\n")
        #expect(mdHTML("*a **b** c*") == "<p><em>a <strong>b</strong> c</em></p>\n")
        #expect(mdHTML("***both***") == "<p><em><strong>both</strong></em></p>\n")
        #expect(mdHTML("snake_case_word") == "<p>snake_case_word</p>\n")
        #expect(mdHTML("2*3*4") == "<p>2<em>3</em>4</p>\n")
        #expect(mdHTML("_foo_bar_baz_") == "<p><em>foo_bar_baz</em></p>\n")
        #expect(mdHTML("*foo**bar*") == "<p><em>foo**bar</em></p>\n")
        #expect(mdHTML("foo******bar*********baz") ==
            "<p>foo<strong><strong><strong>bar</strong></strong></strong>***baz</p>\n")
        #expect(mdHTML("**foo*") == "<p>*<em>foo</em></p>\n")
        #expect(mdHTML("a * b *") == "<p>a * b *</p>\n")
        #expect(mdHTML("_(bar)_.") == "<p><em>(bar)</em>.</p>\n")
        #expect(mdHTML("пристаням_стремятся_") == "<p>пристаням_стремятся_</p>\n")
        #expect(mdHTML("*$*alpha") == "<p>*$*alpha</p>\n")
    }

    @Test func strikethrough() {
        #expect(mdHTML("~~Hi~~ Hello, ~there~ world!") == "<p><del>Hi</del> Hello, <del>there</del> world!</p>\n")
        #expect(mdHTML("This will ~~~not~~~ strike.") == "<p>This will ~~~not~~~ strike.</p>\n")
        #expect(mdHTML("~~a~ b~") == "<p>~~a~ b~</p>\n")
        #expect(mdHTML("~~**x**~~") == "<p><del><strong>x</strong></del></p>\n")
    }

    @Test func links() {
        #expect(mdHTML("[link](/uri \"title\")") == "<p><a href=\"/uri\" title=\"title\">link</a></p>\n")
        #expect(mdHTML("[a](/u 'single') [b](/u (paren))") ==
            "<p><a href=\"/u\" title=\"single\">a</a> <a href=\"/u\" title=\"paren\">b</a></p>\n")
        #expect(mdHTML("[link [foo [bar]]](/uri)") == "<p><a href=\"/uri\">link [foo [bar]]</a></p>\n")
        #expect(mdHTML("[link](</my uri>)") == "<p><a href=\"/my%20uri\">link</a></p>\n")
        #expect(mdHTML("[link](/my uri)") == "<p>[link](/my uri)</p>\n")
        #expect(mdHTML("[link]()") == "<p><a href=\"\">link</a></p>\n")
        #expect(mdHTML("[foo [bar](/uri)](/uri)") == "<p>[foo <a href=\"/uri\">bar</a>](/uri)</p>\n")
        #expect(mdHTML("*[foo*](/uri)") == "<p>*<a href=\"/uri\">foo*</a></p>\n")
        #expect(mdHTML("[a](\"title\")") == "<p><a href=\"%22title%22\">a</a></p>\n")
        #expect(mdHTML("[a](foo%20b&auml;)") == "<p><a href=\"foo%20b%C3%A4\">a</a></p>\n")
    }

    @Test func linksWithParenthesesInURLs() {
        #expect(mdHTML("[link](foo(and(bar)))") == "<p><a href=\"foo(and(bar))\">link</a></p>\n")
        #expect(mdHTML("[wiki](https://en.wikipedia.org/wiki/Swift_(programming_language))") ==
            "<p><a href=\"https://en.wikipedia.org/wiki/Swift_(programming_language)\">wiki</a></p>\n")
        #expect(mdHTML("[link](foo(and(bar))") == "<p>[link](foo(and(bar))</p>\n")
        #expect(mdHTML("[link](foo\\(and\\(bar\\))") == "<p><a href=\"foo(and(bar)\">link</a></p>\n")
        #expect(mdHTML("[link](<foo(and(bar)>)") == "<p><a href=\"foo(and(bar)\">link</a></p>\n")
    }

    @Test func referenceLinks() {
        let defs = "\n\n[ref]: /url \"T\"\n[*em* ref]: /em"
        #expect(mdHTML("[text][ref]" + defs) == "<p><a href=\"/url\" title=\"T\">text</a></p>\n")
        #expect(mdHTML("[Ref][]" + defs) == "<p><a href=\"/url\" title=\"T\">Ref</a></p>\n")
        #expect(mdHTML("[ref]" + defs) == "<p><a href=\"/url\" title=\"T\">ref</a></p>\n")
        #expect(mdHTML("[*em* ref]" + defs) == "<p><a href=\"/em\"><em>em</em> ref</a></p>\n")
        #expect(mdHTML("[foo][bar][ref]" + defs) == "<p>[foo]<a href=\"/url\" title=\"T\">bar</a></p>\n")
    }

    @Test func images() {
        #expect(mdHTML("![alt *text*](/img.png \"Title\")") ==
            "<p><img src=\"/img.png\" alt=\"alt text\" title=\"Title\" /></p>\n")
        #expect(mdHTML("![foo ![bar](/a)](/b)") == "<p><img src=\"/b\" alt=\"foo bar\" /></p>\n")
        #expect(mdHTML("[![moon](moon.jpg)](/uri)") == "<p><a href=\"/uri\"><img src=\"moon.jpg\" alt=\"moon\" /></a></p>\n")
        #expect(mdHTML("![\"q\" & <b>](x)") == "<p><img src=\"x\" alt=\"&quot;q&quot; &amp; \" /></p>\n")
        #expect(mdHTML("![img][r]\n\n[r]: /r.png") == "<p><img src=\"/r.png\" alt=\"img\" /></p>\n")
    }

    @Test func autolinks() {
        #expect(mdHTML("<https://example.com/a?b=1&c=2>") ==
            "<p><a href=\"https://example.com/a?b=1&amp;c=2\">https://example.com/a?b=1&amp;c=2</a></p>\n")
        #expect(mdHTML("<mailto:me@example.com>") == "<p><a href=\"mailto:me@example.com\">mailto:me@example.com</a></p>\n")
        #expect(mdHTML("<me@example.com>") == "<p><a href=\"mailto:me@example.com\">me@example.com</a></p>\n")
        #expect(mdHTML("<https://a.b/c d>") == "<p>&lt;https://a.b/c d&gt;</p>\n")
        #expect(mdHTML("<foo.bar>") == "<p>&lt;foo.bar&gt;</p>\n")
    }

    @Test func extendedAutolinks() {
        #expect(mdHTML("Visit https://example.com today") ==
            "<p>Visit <a href=\"https://example.com\">https://example.com</a> today</p>\n")
        #expect(mdHTML("www.commonmark.org/help") ==
            "<p><a href=\"http://www.commonmark.org/help\">www.commonmark.org/help</a></p>\n")
        #expect(mdHTML("mail foo@bar.baz now") == "<p>mail <a href=\"mailto:foo@bar.baz\">foo@bar.baz</a> now</p>\n")
        #expect(mdHTML("https://example.com/a_b_c") ==
            "<p><a href=\"https://example.com/a_b_c\">https://example.com/a_b_c</a></p>\n")
        #expect(mdHTML("[http://x.org](http://y.org)") == "<p><a href=\"http://y.org\">http://x.org</a></p>\n")
        #expect(mdHTML("notalink.com www. http://") == "<p>notalink.com www. http://</p>\n")
    }

    @Test func autolinkTrailingPunctuation() {
        #expect(mdHTML("See www.example.com.") == "<p>See <a href=\"http://www.example.com\">www.example.com</a>.</p>\n")
        #expect(mdHTML("(see https://example.com/x)") ==
            "<p>(see <a href=\"https://example.com/x\">https://example.com/x</a>)</p>\n")
        #expect(mdHTML("https://en.wikipedia.org/wiki/Foo_(bar)") ==
            "<p><a href=\"https://en.wikipedia.org/wiki/Foo_(bar)\">https://en.wikipedia.org/wiki/Foo_(bar)</a></p>\n")
        #expect(mdHTML("Wow https://example.com/?q=1!?,:*_~") ==
            "<p>Wow <a href=\"https://example.com/?q=1\">https://example.com/?q=1</a>!?,:*_~</p>\n")
        #expect(mdHTML("www.google.com/search?q=commonmark&hl;") ==
            "<p><a href=\"http://www.google.com/search?q=commonmark\">www.google.com/search?q=commonmark</a>&hl;</p>\n")
        #expect(mdHTML("**https://example.com**") ==
            "<p><strong><a href=\"https://example.com\">https://example.com</a></strong></p>\n")
        #expect(mdHTML("a.b-c_d@a.b. a.b-c_d@a.b-") ==
            "<p><a href=\"mailto:a.b-c_d@a.b\">a.b-c_d@a.b</a>. a.b-c_d@a.b-</p>\n")
    }

    @Test func rawInlineHTML() {
        #expect(mdHTML("a <span class=\"x\">b</span> c") == "<p>a <span class=\"x\">b</span> c</p>\n")
        #expect(mdHTML("<a href=\"x\"/> <!-- c --> <?pi?> <!DOCTYPE x> <![CDATA[ y ]]>") ==
            "<p><a href=\"x\"/> <!-- c --> <?pi?> <!DOCTYPE x> <![CDATA[ y ]]></p>\n")
        #expect(mdHTML("<33> <a h*#ref=\"hi\">") == "<p>&lt;33&gt; &lt;a h*#ref=&quot;hi&quot;&gt;</p>\n")
        #expect(mdHTML("**<a href=\"**\">") == "<p>**<a href=\"**\"></p>\n")
    }

    @Test func lineBreaks() {
        #expect(mdHTML("foo  \nbar") == "<p>foo<br />\nbar</p>\n")
        #expect(mdHTML("foo\\\nbar") == "<p>foo<br />\nbar</p>\n")
        #expect(mdHTML("foo \n  bar") == "<p>foo\nbar</p>\n")
        #expect(mdHTML("foo  ") == "<p>foo</p>\n")
        #expect(mdHTML("foo\\") == "<p>foo\\</p>\n")
        #expect(mdHTML("*a  \nb*") == "<p><em>a<br />\nb</em></p>\n")
    }
}

// MARK: - Source lines and safety

@Suite("Markdown source lines and safety")
struct MarkdownSourceLineAndSafetyTests {
    @Test func dataLinesInNestedStructures() {
        let source = """
        # Title

        Para one
        continues

        > Quote
        >
        > - item a
        >   - item b
        >
        >     ```swift
        >     code
        >     ```

        1. first
        2. second

        | h |
        |---|
        | c |

        ***
        """
        #expect(mdHTML(source, lines: true) == """
        <h1 id="title" data-line="0">Title</h1>
        <p data-line="2">Para one
        continues</p>
        <blockquote data-line="5">
        <p data-line="5">Quote</p>
        <ul data-line="7">
        <li data-line="7">item a
        <ul data-line="8">
        <li data-line="8">
        <p data-line="8">item b</p>
        <pre data-line="10"><code class="language-swift">code</code></pre>
        </li>
        </ul>
        </li>
        </ul>
        </blockquote>
        <ol data-line="14">
        <li data-line="14">first</li>
        <li data-line="15">second</li>
        </ol>
        <table data-line="17"><thead><tr><th>h</th></tr></thead><tbody><tr><td>c</td></tr></tbody></table>
        <hr data-line="21" />

        """)
    }

    @Test func dataLinesAfterFrontMatterAndCRLF() {
        let source = "---\r\ntitle: x\r\nlist:\r\n  - a\r\n---\r\n\r\nFirst *para*\r\n\r\n- item\r\n"
        #expect(mdHTML(source, lines: true) ==
            "<details class=\"front-matter\" data-line=\"0\"><summary>Front matter</summary>"
            + "<pre><code class=\"language-yaml\">title: x\nlist:\n  - a</code></pre></details>\n"
            + "<p data-line=\"6\">First <em>para</em></p>\n<ul data-line=\"8\">\n<li data-line=\"8\">item</li>\n</ul>\n")
    }

    @Test func dataLinesSkipLinkDefinitionsAndLazyLines() {
        #expect(mdHTML("[a]: /x\n[b]: /y\ntext [a]", lines: true) == "<p data-line=\"2\">text <a href=\"/x\">a</a></p>\n")
        #expect(mdHTML("Line\n\n> quote\nlazy\n\n    code", lines: true) ==
            "<p data-line=\"0\">Line</p>\n<blockquote data-line=\"2\">\n<p data-line=\"2\">quote\nlazy</p>\n</blockquote>\n"
            + "<pre data-line=\"5\"><code>code</code></pre>\n")
    }

    @Test func sourceLineAttributesCanBeDisabled() {
        let output = MarkdownRenderer.renderHTML("# A\n\n- [ ] b\n\n> c", options: .init(sourceLineAttributes: false))
        #expect(!output.contains("data-line"))
    }

    @Test func unsafeURLsAreNeutralized() {
        let source = """
        [a](javascript:alert(1)) [b](JavaScript:alert(1)) [c](vbscript:msgbox) [d](data:text/html;base64,xx)
        [e](&#106;avascript:alert(1)) [f](java\\script:x) <javascript:alert(1)> [g][r]
        ![ok](data:image/png;base64,AAAA) ![bad](javascript:alert(1))

        [r]: javascript:alert(2)
        """
        let output = mdHTML(source)
        #expect(!output.lowercased().contains("href=\"javascript"))
        #expect(!output.lowercased().contains("src=\"javascript"))
        #expect(!output.contains("vbscript:msgbox\""))
        #expect(!output.contains("data:text/html"))
        #expect(output.contains("<a href=\"#\">a</a>"))
        #expect(output.contains("<a href=\"#\">e</a>"))
        #expect(output.contains("<a href=\"#\">javascript:alert(1)</a>"))
        #expect(output.contains("<a href=\"#\">g</a>"))
        #expect(output.contains("<img src=\"data:image/png;base64,AAAA\" alt=\"ok\" />"))
        #expect(output.contains("<img src=\"#\" alt=\"bad\" />"))
    }

    @Test func attributesAreEscaped() {
        #expect(mdHTML("[x](/a\"onmouseover=\"alert(1) \"t\\\"<>&\")") ==
            "<p><a href=\"/a%22onmouseover=%22alert(1)\" title=\"t&quot;&lt;&gt;&amp;\">x</a></p>\n")
        #expect(mdHTML("```\"><img>\n```") == "<pre><code class=\"language-&quot;&gt;&lt;img&gt;\"></code></pre>\n")
    }
}

// MARK: - Robustness and performance

@Suite("Markdown robustness")
struct MarkdownRobustnessTests {
    /// Every `<` in the output must start one of the renderer's own tags when raw HTML is disabled.
    private static let ownTags: [String] = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "em", "strong", "del", "code", "pre", "a", "img", "ul", "ol",
        "li", "input", "blockquote", "div", "hr", "br", "table", "thead", "tbody", "tr", "th", "td", "sup",
        "section", "details", "summary",
    ]

    private static func onlyOwnTags(_ output: String) -> Bool {
        var rest = Substring(output)
        while let index = rest.firstIndex(of: "<") {
            var tail = rest[rest.index(after: index)...]
            if tail.hasPrefix("/") { tail = tail.dropFirst() }
            let name = tail.prefix { $0.isLetter || $0.isNumber }
            guard ownTags.contains(String(name)) else { return false }
            rest = tail
        }
        return true
    }

    @Test func fuzzRandomMarkdownNeverCrashes() {
        let pieces = [
            "*", "_", "~", "`", "#", ">", "-", "+", "=", "|", ":", "[", "]", "(", ")", "!", "<", "&", "\\", "\"",
            "'", " ", "\t", "\n", "\r", "\r\n", "1.", "2)", "x", "é", "😀", "    ", "- ", "> ", "```", "~~~", "[^",
            "]:", "<!--", "-->", "<div>", "</div>", "http://", "www.", "@", "&amp;", "&#x41;", "[ ] ", "[x] ",
            "[!NOTE]", "---\n", "\u{0}", "\u{A0}", "<a href=\"", "![", "](", "\\|", "| --- |", ":-:", "javascript:",
        ]
        var rng = MDSplitMix64(state: 0x5EED)
        var unsafe = 0
        for _ in 0..<4000 {
            var source = ""
            for _ in 0..<Int.random(in: 0...60, using: &rng) {
                source += pieces[Int.random(in: 0..<pieces.count, using: &rng)]
            }
            let safe = MarkdownRenderer.renderHTML(source, options: .init(allowRawHTML: false))
            if !Self.onlyOwnTags(safe) || safe.lowercased().contains("href=\"javascript:") { unsafe += 1 }
            _ = MarkdownRenderer.renderHTML(source)
            _ = MarkdownRenderer.headings(source)
        }
        #expect(unsafe == 0)
    }

    @Test func fuzzLineStructuredMarkdownNeverCrashes() {
        let prefixes = ["", "> ", "- ", "1. ", "  ", "    ", "\t", "* ", ">>", "- [ ] ", "[^a]: ", "| ", "  - ",
                        "10) ", "> - ", "<div>", "```", "~~~", "# ", "---", "===", "[a]: /u ", "|-|-|"]
        let words = ["foo", "*bar*", "_baz_", "`q`", "[l](u)", "[a]", "[^a]", "www.x.com", "a@b.co", "<b>", "&copy;",
                     "\\*", "~~s~~", "| x |", "**", "__", ""]
        var rng = MDSplitMix64(state: 42)
        for _ in 0..<1500 {
            var lines: [String] = []
            for _ in 0..<Int.random(in: 0...20, using: &rng) {
                var line = ""
                for _ in 0..<Int.random(in: 0...3, using: &rng) { line += prefixes.randomElement(using: &rng) ?? "" }
                for _ in 0..<Int.random(in: 0...5, using: &rng) { line += (words.randomElement(using: &rng) ?? "") + " " }
                lines.append(line)
            }
            let source = lines.joined(separator: ["\n", "\r\n", "\r"].randomElement(using: &rng) ?? "\n")
            let output = MarkdownRenderer.renderHTML(source)
            #expect(output.utf8.count <= source.utf8.count * 50 + 1_000)
            _ = MarkdownRenderer.headings(source)
        }
    }

    @Test func pathologicalInputsFinishQuickly() {
        let n = 10_000
        let inputs: [(String, String)] = [
            ("nested quotes", String(repeating: ">", count: n) + " deep"),
            ("brackets", String(repeating: "[", count: n) + "x"),
            ("image brackets", String(repeating: "![", count: n)),
            ("closed brackets", String(repeating: "[", count: n) + String(repeating: "]", count: n) + "(u)"),
            ("asterisks", "a" + String(repeating: "*", count: n) + "b"),
            ("emphasis openers", String(repeating: "*a ", count: n) + String(repeating: "a* ", count: n)),
            ("underscores", String(repeating: "_a ", count: n) + String(repeating: " a_", count: n)),
            ("delimiter soup", String(repeating: "*_~", count: n)),
            ("nested lists", (0..<2_000).map { String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n")),
            ("nested ordered", (0..<2_000).map { String(repeating: " ", count: 3 * $0) + "1. x" }.joined(separator: "\n")),
            ("quote list mix", String(repeating: String(repeating: "> - ", count: 50) + "x\n", count: 200)),
            ("unclosed titles", String(repeating: "[a](b \"", count: n)),
            ("unclosed comments", String(repeating: "x <!--", count: n)),
            ("unclosed attributes", String(repeating: "<a title=\"", count: n)),
            ("backtick runs", (1...1_500).map { String(repeating: "`", count: $0) }.joined(separator: " ")),
            ("link chain", String(repeating: "[a](b)", count: n)),
            ("autolink parens", "www.x.com/" + String(repeating: "(", count: n) + String(repeating: ")", count: n + 3)),
            ("fences", String(repeating: "```\n", count: n)),
            ("html blocks", String(repeating: "<div>\n", count: n)),
            ("wide table", "|" + String(repeating: "a|", count: 3_000) + "\n|" + String(repeating: "-|", count: 3_000) + "\n|" + String(repeating: "b|", count: 3_000)),
        ]
        for (name, source) in inputs {
            var output = ""
            let elapsed = mdMeasure { output = MarkdownRenderer.renderHTML(source) }
            #expect(!output.isEmpty, "\(name) produced no output")
            #expect(elapsed < .seconds(5), "\(name) took \(elapsed)")
        }
        // Many unclosed `[` do not prevent later links in the same paragraph.
        #expect(mdHTML(String(repeating: "[", count: 200) + " [ok](/u)") ==
            "<p>" + String(repeating: "[", count: 200) + " <a href=\"/u\">ok</a></p>\n")
        // The container depth cap leaves the rest of a 10k `>` line as text.
        let quotes = MarkdownRenderer.renderHTML(String(repeating: ">", count: n) + " deep", options: .init(sourceLineAttributes: false))
        #expect(quotes.components(separatedBy: "<blockquote>").count - 1 == MDLimits.maxBlockDepth - 1)
        #expect(quotes.contains("&gt;&gt;&gt;"))
    }

    @Test func largeDocumentRendersFast() {
        let document = Self.makeLargeDocument(targetBytes: 1_000_000)
        #expect(document.utf8.count >= 1_000_000)
        var output = ""
        let elapsed = mdMeasure { output = MarkdownRenderer.renderHTML(document) }
        let headingsElapsed = mdMeasure { _ = MarkdownRenderer.headings(document) }
        print("Rendered \(document.utf8.count) bytes of Markdown into \(output.utf8.count) bytes of HTML in \(elapsed) (headings: \(headingsElapsed))")
        #expect(output.contains("<table"))
        #expect(output.contains("<pre"))
        #expect(elapsed < .seconds(30))
    }

    /// A deterministic, realistic mix of headings, paragraphs, lists, code, tables and quotes.
    static func makeLargeDocument(targetBytes: Int) -> String {
        let words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "*adipiscing*", "**elit**", "`code()`",
                     "[link](https://example.com/page)", "https://example.org/path", "~~old~~", "snake_case", "markdown",
                     "preview", "editor", "swift", "render"]
        var rng = MDSplitMix64(state: 7)
        func sentence() -> String {
            (0..<Int.random(in: 6...16, using: &rng)).map { _ in words.randomElement(using: &rng) ?? "" }.joined(separator: " ") + "."
        }
        var blocks: [String] = []
        var size = 0
        var index = 0
        while size < targetBytes {
            index += 1
            let block: String
            switch index % 10 {
            case 0: block = "## Section \(index)"
            case 1, 2, 3: block = (0..<3).map { _ in sentence() }.joined(separator: "\n")
            case 4: block = (0..<5).map { "- " + ($0 % 2 == 0 ? "[ ] " : "") + sentence() + ($0 == 2 ? "\n  - nested " + sentence() : "") }.joined(separator: "\n")
            case 5: block = "```swift\n" + (0..<8).map { "let value\($0) = compute(\($0)) // \(sentence())" }.joined(separator: "\n") + "\n```"
            case 6: block = "| Name | Value | Notes |\n|:-----|------:|:-----:|\n" + (0..<6).map { "| item\($0) | \($0 * 7) | \(sentence()) |" }.joined(separator: "\n")
            case 7: block = "> " + sentence() + "\n> " + sentence()
            case 8: block = "1. " + sentence() + "\n2. " + sentence() + "\n3. " + sentence()
            default: block = "> [!NOTE]\n> " + sentence()
            }
            blocks.append(block)
            size += block.utf8.count + 2
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }
}
