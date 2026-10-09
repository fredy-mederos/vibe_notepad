import Foundation
import Testing
@testable import VibeCore

// MARK: - Helpers

private struct HLSpan: Equatable, CustomStringConvertible {
    let text: String
    let kind: TokenKind

    init(_ text: String, _ kind: TokenKind) {
        self.text = text
        self.kind = kind
    }

    var description: String { "\(text.debugDescription):\(kind)" }
}

private extension Array where Element == HLSpan {
    func contains(_ span: (String, TokenKind)) -> Bool { contains(HLSpan(span.0, span.1)) }

    /// Kind of the first span whose text is exactly `text`.
    func kind(_ text: String) -> TokenKind? { first(where: { $0.text == text })?.kind }
}

private func hlLines(_ text: String) -> [[UInt16]] {
    Array(text.utf16).split(separator: Ch.newline, omittingEmptySubsequences: false).map(Array.init)
}

/// The highlighted spans of every line of `text`.
private func hlSpans(_ text: String, _ language: LanguageID) -> [[HLSpan]] {
    let tokens = SyntaxHighlighter.tokenize(text, language: language)
    return zip(hlLines(text), tokens).map { units, lineTokens in
        lineTokens.map { HLSpan(String(decoding: units[$0.start..<$0.end], as: UTF16.self), $0.kind) }
    }
}

/// The kind painted on the first character of `needle` on line `line` (later tokens win).
private func hlKind(of needle: String, in text: String, _ language: LanguageID, line: Int = 0) -> TokenKind? {
    let units = hlLines(text)[line]
    let target = Array(needle.utf16)
    guard !target.isEmpty, target.count <= units.count,
          let offset = (0...(units.count - target.count)).first(where: { Array(units[$0..<$0 + target.count]) == target }) else {
        return nil
    }
    var kind = TokenKind.plain
    for token in SyntaxHighlighter.tokenize(text, language: language)[line] where token.start <= offset && offset < token.end {
        kind = token.kind
    }
    return kind
}

/// SplitMix64, so random documents are reproducible.
private struct HLSeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let hlCommonPool = [
    " ", " ", "  ", "\t", "\r", "a", "word", "x1", "42", "3.14", "-7", "é", "😀", "\\", "\"", "'", "`", "#", ";", "=", ":",
    "(", ")", "[", "]", "{", "}", "<", ">", "$", "/", "*", "-", ",", ".", "!", "@", "%", "&", "|", "~", "?", "+",
]

/// Lexes thousands of random lines built from `pool` and checks that tokens stay in range, never
/// overlap, are deterministic, and that lexing line by line (each line in its own padded buffer)
/// with the carried state matches `SyntaxHighlighter.tokenize` of the whole text.
private func expectRobustLexing(_ language: LanguageID, pool: [String], lines: Int = 2500) {
    for seed: UInt64 in [0x5EED, 0xC0FFEE] {
        guard expectRobustLexing(language, pool: pool, lines: lines, seed: seed) else { return }
    }
}

/// Returns false after recording an issue.
private func expectRobustLexing(_ language: LanguageID, pool: [String], lines: Int, seed: UInt64) -> Bool {
    var rng = HLSeededGenerator(state: seed &+ UInt64(language.rawValue.utf8.count))
    let fragments = pool + hlCommonPool
    var documentLines: [String] = []
    documentLines.reserveCapacity(lines)
    for _ in 0..<lines {
        let count = Int.random(in: 0...14, using: &rng)
        var line = ""
        for _ in 0..<count { line += fragments.randomElement(using: &rng)! }
        documentLines.append(line)
    }
    let text = documentLines.joined(separator: "\n")
    let first = SyntaxHighlighter.tokenize(text, language: language)
    let again = SyntaxHighlighter.tokenize(text, language: language)
    #expect(first == again, "\(language) lexing is not deterministic")

    let lineUnits = hlLines(text)
    #expect(first.count == lineUnits.count)
    for (index, tokens) in first.enumerated() {
        var previousEnd = 0
        for token in tokens {
            guard token.length > 0, token.start >= previousEnd, token.end <= lineUnits[index].count else {
                Issue.record("\(language): bad token \(token) on line \(index) \(documentLines[index].debugDescription): \(tokens)")
                return false
            }
            previousEnd = token.end
        }
    }

    let lexer = language.lexer
    var state = lexer.initialState
    let pad = Array("<\"'{$#\\`".utf16)
    for (index, units) in lineUnits.enumerated() {
        let padded = pad + units + pad
        var buffer = TokenBuffer()
        padded.withUnsafeBufferPointer { ptr in
            lexer.lex(LineBuffer(base: ptr.baseAddress!, start: pad.count, end: pad.count + units.count), state: &state, tokens: &buffer)
        }
        let relative = buffer.tokens.map { Token(start: $0.start - pad.count, length: $0.length, kind: $0.kind) }
        guard relative == first[index] else {
            Issue.record("\(language): line \(index) \(documentLines[index].debugDescription) lexes differently on its own: \(relative) vs \(first[index])")
            return false
        }
    }
    return first == again
}

/// Tests for the INI, TOML, properties, conf, xcconfig, ignore-list, XML/HTML, CSS, shell,
/// Dockerfile, Makefile, diff, log and CSV lexers.
@Suite struct ConfigMarkupShellLexerTests {}

// MARK: - INI

extension ConfigMarkupShellLexerTests {
    @Suite struct INI {
        @Test func sectionsKeysAndValues() {
            let s = hlSpans("[core]\neditor = vim\n[remote \"origin\"]\n\turl: git@github.com:me/repo.git", .ini)
            #expect(s[0].contains(("core", .section)))
            #expect(s[0].contains(("[", .punctuation)) && s[0].contains(("]", .punctuation)))
            #expect(s[1].contains(("editor", .property)) && s[1].contains(("=", .operator)) && s[1].contains(("vim", .string)))
            #expect(s[2].contains(("remote", .section)) && s[2].contains(("\"origin\"", .string)))
            #expect(s[3].contains(("url", .property)) && s[3].contains((":", .operator)))
            #expect(s[3].contains(("git@github.com:me/repo.git", .string)))
        }

        @Test func valueTypes() {
            let s = hlSpans("root = true\nindent_size = 4\nmode = off\nname = \"a \\\"b\\\"\"\nlist = a, b c", .ini)
            #expect(s[0].contains(("true", .constant)))
            #expect(s[1].contains(("4", .number)))
            #expect(s[2].contains(("off", .constant)))
            #expect(s[3].contains(("\\\"", .escape)) && s[3].kind("\"a ") == .string)
            #expect(s[4].contains(("a, b c", .string)))
        }

        @Test func variablesAndComments() {
            let s = hlSpans("; comment\n# another\npath = ${HOME}/bin:%(here)s ; inline\nurl = http://x#frag", .ini)
            #expect(s[0] == [HLSpan("; comment", .comment)])
            #expect(s[1] == [HLSpan("# another", .comment)])
            #expect(s[2].contains(("${HOME}", .variable)) && s[2].contains(("%(here)s", .variable)))
            #expect(s[2].contains(("; inline", .comment)))
            #expect(s[3].contains(("http://x#frag", .string)), "`#` needs whitespace before it to start a comment")
        }

        @Test func npmrcAndBareKeys() {
            let s = hlSpans("//registry.npmjs.org/:_authToken=${NPM_TOKEN}\nskip-name-resolve", .ini)
            #expect(s[0].contains(("//registry.npmjs.org/:_authToken", .property)) && s[0].contains(("${NPM_TOKEN}", .variable)))
            #expect(s[1] == [HLSpan("skip-name-resolve", .property)])
        }

        @Test func multilineValues() {
            let s = hlSpans("install_requires =\n    requests>=2.0\n    numpy\nscripts =\n    cli = pkg.cli:main\nnext = 1", .ini)
            #expect(s[1] == [HLSpan("requests>=2.0", .string)])
            #expect(s[2] == [HLSpan("numpy", .string)])
            #expect(s[4].contains(("cli", .property)))
            #expect(s[5].contains(("next", .property)) && s[5].contains(("1", .number)))
        }

        @Test func carriageReturns() {
            let s = hlSpans("[core]\r\neditor = vim\r\n", .ini)
            #expect(s[0].contains(("core", .section)))
            #expect(s[1].contains(("editor", .property)) && s[1].contains(("vim", .string)))
        }

        @Test func robustness() {
            expectRobustLexing(.ini, pool: ["[section]", "[remote \"o\"]", "key = ", "${var}", "%(x)s", "%%", "true", "yes", "; c", "# c", "//", "\n  "])
        }
    }
}

// MARK: - TOML

extension ConfigMarkupShellLexerTests {
    @Suite struct TOML {
        @Test func tablesAndKeys() {
            let s = hlSpans("[servers.alpha]\n[[products]]\nsite.\"google.com\" = true\n'lit key' = 1", .toml)
            #expect(s[0].contains(("servers.alpha", .section)))
            #expect(s[1].contains(("[[", .punctuation)) && s[1].contains(("products", .section)) && s[1].contains(("]]", .punctuation)))
            #expect(s[2].contains(("site", .property)) && s[2].contains(("\"google.com\"", .property)) && s[2].contains((".", .punctuation)))
            #expect(s[2].contains(("true", .constant)))
            #expect(s[3].contains(("'lit key'", .property)))
        }

        @Test func numbersDatesAndStrings() {
            let s = hlSpans("""
            a = 1_000
            b = 0xDEAD_BEEF
            c = -3.14e-2
            d = -inf
            e = 1979-05-27T07:32:00Z
            f = 07:32:00
            g = 1979-05-27
            h = "tab\\there \\u00E9"
            i = 'C:\\path'
            """, .toml)
            #expect(s[0].contains(("1_000", .number)))
            #expect(s[1].contains(("0xDEAD_BEEF", .number)))
            #expect(s[2].contains(("-3.14e-2", .number)))
            #expect(s[3].contains(("-inf", .number)))
            #expect(s[4].contains(("1979-05-27T07:32:00Z", .constant)))
            #expect(s[5].contains(("07:32:00", .constant)))
            #expect(s[6].contains(("1979-05-27", .constant)))
            #expect(s[7].contains(("\\t", .escape)) && s[7].contains(("\\u00E9", .escape)))
            #expect(s[8].contains(("'C:\\path'", .string)))
        }

        @Test func inlineTablesAndMultilineArrays() {
            let s = hlSpans("point = { x = 1, y = 2 }\nmatrix = [\n  [1, 2],\n  [3, 4],\n]\nafter = \"x\"", .toml)
            #expect(s[0].contains(("x", .property)) && s[0].contains(("y", .property)) && s[0].contains(("{", .punctuation)))
            #expect(!s[2].contains(("[", .section)) && s[2].contains(("[", .punctuation)) && s[2].contains(("1", .number)))
            #expect(s[5].contains(("after", .property)))
        }

        @Test func multilineStrings() {
            let s = hlSpans("a = \"\"\"\nline \\n one\nend\"\"\"\nb = '''\nraw \\n\n'''\nc = 1", .toml)
            #expect(s[1].contains(("\\n", .escape)) && s[1].contains(("line ", .string)))
            #expect(s[2].contains(("end\"\"\"", .string)))
            #expect(s[4] == [HLSpan("raw \\n", .string)])
            #expect(s[6].contains(("c", .property)))
        }

        @Test func recoversFromUnclosedArray() {
            let s = hlSpans("a = [1, 2\n[table]\nkey = 1", .toml)
            #expect(s[1].contains(("table", .section)))
            #expect(s[2].contains(("key", .property)))
        }

        @Test func robustness() {
            expectRobustLexing(.toml, pool: ["\"\"\"", "'''", "[[", "]]", "= ", "1979-05-27T07:32:00Z", "07:32:00", "0xFF", "inf", "nan", "true",
                                       "\\u00E9", "\\n", "key.sub", "\"q\"", "{ a = 1 }", "\n["])
        }
    }
}

// MARK: - Properties

extension ConfigMarkupShellLexerTests {
    @Suite struct Properties {
        @Test func keysValuesAndEscapes() {
            let s = hlSpans("# comment\n! old\napp.name=My App\nserver.port: 8080\nkey\\ with\\ spaces = v\nspaced key value\nu=caf\\u00e9", .properties)
            #expect(s[0] == [HLSpan("# comment", .comment)] && s[1] == [HLSpan("! old", .comment)])
            #expect(s[2].contains(("app.name", .property)) && s[2].contains(("=", .operator)) && s[2].contains(("My App", .string)))
            #expect(s[3].contains((":", .operator)) && s[3].contains(("8080", .string)))
            #expect(s[4].contains(("\\ ", .escape)) && s[4].contains(("key", .property)))
            #expect(s[5].contains(("spaced", .property)) && s[5].contains(("key value", .string)))
            #expect(s[6].contains(("\\u00e9", .escape)))
        }

        @Test func placeholdersAndContinuations() {
            let s = hlSpans("greeting=Hello {0}, ${app.name}\ndesc = A long \\\n    value continues\nnext=1", .properties)
            #expect(s[0].contains(("{0}", .variable)) && s[0].contains(("${app.name}", .variable)))
            #expect(s[1].contains(("\\", .escape)))
            #expect(s[2] == [HLSpan("value continues", .string)])
            #expect(s[3].contains(("next", .property)))
        }

        @Test func robustness() {
            expectRobustLexing(.properties, pool: ["\\\\", "\\u0041", "${p}", "{0}", "!", "# c", "key=", "key: ", "\\"])
        }
    }
}

// MARK: - Conf / SSH config

extension ConfigMarkupShellLexerTests {
    @Suite struct Conf {
        @Test func nginx() {
            let s = hlSpans("server {\n    listen 80;\n    client_max_body_size 10m;\n    gzip on; # zip\n    return 301 https://$host$request_uri;\n    location ~* \\.(png)$ {", .conf)
            #expect(s[0].contains(("server", .keyword)) && s[0].contains(("{", .punctuation)))
            #expect(s[1].contains(("listen", .keyword)) && s[1].contains(("80", .number)) && s[1].contains((";", .punctuation)))
            #expect(s[2].contains(("10m", .number)))
            #expect(s[3].contains(("on", .constant)) && s[3].contains(("# zip", .comment)))
            #expect(s[4].contains(("$host", .variable)) && s[4].contains(("$request_uri", .variable)) && s[4].contains(("301", .number)))
            #expect(s[5].contains(("~", .operator)))
        }

        @Test func hostsRequirementsAndGoMod() {
            let s = hlSpans("127.0.0.1 localhost\n::1 localhost\nDjango>=3.2,<4.0\n-r base.txt\nrequire (\n\tgithub.com/pkg/errors v0.9.1 // indirect\n)", .conf)
            #expect(s[0].contains(("127.0.0.1", .number)))
            #expect(s[1].contains(("::1", .number)))
            #expect(s[2].contains(("Django", .keyword)) && s[2].contains((">=", .operator)) && s[2].contains(("3.2", .number)))
            #expect(s[3].contains(("-r", .attribute)))
            #expect(s[5].contains(("v0.9.1", .number)) && s[5].contains(("// indirect", .comment)))
            #expect(!s[5].contains(("github.com/pkg/errors", .keyword)), "arguments inside `require (` are not directives")
        }

        @Test func vimTmuxAndApache() {
            let s = hlSpans("\" vim comment\nset tabstop=4\nset -g mouse on\n<Directory \"/var/www\">\nRewriteCond %{HTTP_HOST} x", .conf)
            #expect(s[0] == [HLSpan("\" vim comment", .comment)])
            #expect(s[1].contains(("set", .keyword)) && s[1].contains(("=", .operator)) && s[1].contains(("4", .number)))
            #expect(s[2].contains(("-g", .attribute)) && s[2].contains(("on", .constant)))
            #expect(s[3].contains(("Directory", .tag)) && s[3].contains(("\"/var/www\"", .string)))
            #expect(s[4].contains(("%{HTTP_HOST}", .variable)))
        }

        @Test func continuationLines() {
            let s = hlSpans("cmd arg \\\n  next arg\nother", .conf)
            #expect(!s[1].contains(("next", .keyword)))
            #expect(s[2].contains(("other", .keyword)))
        }

        @Test func sshConfigBlocks() {
            let s = hlSpans("Host github.com *.example.com # work\n    HostName github.com\n    Port 22\n    ForwardAgent yes\nMatch user git\nHost=bastion", .sshConfig)
            #expect(s[0].contains(("Host", .keyword)) && s[0].contains(("github.com *.example.com", .section)) && s[0].contains(("# work", .comment)))
            #expect(s[1].contains(("HostName", .keyword)))
            #expect(s[2].contains(("22", .number)))
            #expect(s[3].contains(("yes", .constant)))
            #expect(s[4].contains(("Match", .keyword)) && s[4].contains(("user git", .section)))
            #expect(s[5].contains(("bastion", .section)))
            #expect(!hlSpans("Host example.com", .conf)[0].contains(("example.com", .section)), "only the ssh-config variant has blocks")
        }

        @Test func robustness() {
            expectRobustLexing(.conf, pool: ["server {", "listen 80;", "on", "$host", "${v}", "%{X}", "~*", ">=", "==", "<Dir", "</Dir>", "127.0.0.1",
                                       "::1", "-r", "//", "\" vim", "(", "10m"])
            expectRobustLexing(.sshConfig, pool: ["Host ", "Match ", "HostName ", "=", "*", "# c", "yes"])
        }
    }
}

// MARK: - xcconfig

extension ConfigMarkupShellLexerTests {
    @Suite struct Xcconfig {
        @Test func settings() {
            let s = hlSpans("""
            // comment
            #include "Base.xcconfig"
            #include? "Local.xcconfig"
            PRODUCT_BUNDLE_IDENTIFIER = com.example.$(PRODUCT_NAME:rfc1034identifier)
            CODE_SIGN_IDENTITY[sdk=iphoneos*][arch=*] = iPhone Developer
            OTHER_LDFLAGS = $(inherited) -ObjC ${SRCROOT}
            ENABLE_BITCODE = NO
            SWIFT_VERSION = 5.0 // trailing
            PATHS = "$(SRCROOT)/include"
            """, .xcconfig)
            #expect(s[0] == [HLSpan("// comment", .comment)])
            #expect(s[1].contains(("#include", .meta)) && s[1].contains(("\"Base.xcconfig\"", .string)))
            #expect(s[2].contains(("#include?", .meta)))
            #expect(s[3].contains(("PRODUCT_BUNDLE_IDENTIFIER", .property)) && s[3].contains(("$(PRODUCT_NAME:rfc1034identifier)", .variable)))
            #expect(s[4].contains(("[sdk=iphoneos*]", .attribute)) && s[4].contains(("[arch=*]", .attribute)) && s[4].contains(("=", .operator)))
            #expect(s[5].contains(("$(inherited)", .variable)) && s[5].contains(("-ObjC", .attribute)) && s[5].contains(("${SRCROOT}", .variable)))
            #expect(s[6].contains(("NO", .constant)))
            #expect(s[7].contains(("5.0", .number)) && s[7].contains(("// trailing", .comment)))
            #expect(s[8].contains(("$(SRCROOT)", .variable)) && s[8].contains(("/include\"", .string)))
        }

        @Test func robustness() {
            expectRobustLexing(.xcconfig, pool: ["#include ", "#include? ", "$(VAR)", "${V}", "$(A:rfc1034identifier)", "[sdk=iphoneos*]", "YES", "NO",
                                           "//", "-ObjC", "KEY = "])
        }
    }
}

// MARK: - Ignore lists

extension ConfigMarkupShellLexerTests {
    @Suite struct Gitignore {
        @Test func patterns() {
            let s = hlSpans("# comment\n!important.log\n**/node_modules/\nfile?.txt\n[Dd]ebug/\n\\#literal", .gitignore)
            #expect(s[0] == [HLSpan("# comment", .comment)])
            #expect(s[1].contains(("!", .operator)))
            #expect(s[2].contains(("**", .operator)) && s[2].contains(("/", .punctuation)))
            #expect(s[3].contains(("?", .operator)))
            #expect(s[4].contains(("[Dd]", .regex)))
            #expect(s[5].contains(("\\#", .escape)))
        }

        @Test func attributesAndOwners() {
            let s = hlSpans("*.png binary\n*.sh text eol=lf\n*.md -diff\n/docs/ @org/team docs@example.com\n[attr]custom -text", .gitignore)
            #expect(s[0].contains(("binary", .attribute)))
            #expect(s[1].contains(("eol", .attribute)) && s[1].contains(("=", .operator)) && s[1].contains(("lf", .string)))
            #expect(s[2].contains(("-", .operator)) && s[2].contains(("diff", .attribute)))
            #expect(s[3].contains(("@org/team", .variable)) && s[3].contains(("docs@example.com", .variable)))
            #expect(s[4].contains(("[attr]", .keyword)) && s[4].contains(("custom", .attribute)))
        }

        @Test func robustness() {
            expectRobustLexing(.gitignore, pool: ["!", "*", "**", "?", "[a-z]", "[!x]", "/", "\\#", "@owner", "-diff", "text=auto", "[attr]", "# c"])
        }
    }
}

// MARK: - XML / HTML

extension ConfigMarkupShellLexerTests {
    @Suite struct Markup {
        @Test func xmlBasics() {
            let s = hlSpans("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN">
            <plist version="1.0"><key>A &amp; B &#169;</key><br/></plist>
            """, .xml)
            #expect(s[0].contains(("<?xml", .meta)) && s[0].contains(("version", .attribute)) && s[0].contains(("\"1.0\"", .string)) && s[0].contains(("?>", .meta)))
            #expect(s[1].contains(("<!DOCTYPE plist PUBLIC ", .meta)) && s[1].contains(("\"-//Apple//DTD PLIST 1.0//EN\"", .string)))
            #expect(s[2].contains(("<", .punctuation)) && s[2].contains(("plist", .tag)) && s[2].contains(("version", .attribute)))
            #expect(s[2].contains(("=", .punctuation)) && s[2].contains(("</", .punctuation)) && s[2].contains(("/>", .punctuation)))
            #expect(s[2].contains(("&amp;", .escape)) && s[2].contains(("&#169;", .escape)))
            #expect(hlKind(of: "A ", in: "<k>A &amp; B</k>", .xml) == .plain)
        }

        @Test func multilineConstructs() {
            let s = hlSpans("""
            <!-- a
            comment --><a
              href="x"
              title="multi
            line">text</a>
            <![CDATA[ if (a < b)
            ]]><b/>
            """, .xml)
            #expect(s[0] == [HLSpan("<!-- a", .comment)])
            #expect(s[1].contains(("comment -->", .comment)) && s[1].contains(("a", .tag)))
            #expect(s[2].contains(("href", .attribute)) && s[2].contains(("\"x\"", .string)))
            #expect(s[3].contains(("\"multi", .string)))
            #expect(s[4].contains(("line\"", .string)) && s[4].contains((">", .punctuation)) && s[4].contains(("a", .tag)))
            #expect(s[5].contains(("<![CDATA[", .meta)) && s[5].contains((" if (a < b)", .string)))
            #expect(s[6].contains(("]]>", .meta)) && s[6].contains(("b", .tag)))
        }

        @Test func htmlScriptAndStyleAreEmbedded() {
            let s = hlSpans("""
            <style>
              body { color: #333; }
            </style>
            <script type="module">
              const x = "</div>";
            </script>
            <script>let y = 1;</script><p class="a">after</p>
            """, .html)
            #expect(s[1].contains(("body", .tag)) && s[1].contains(("color", .property)) && s[1].contains(("#333", .constant)))
            #expect(s[2].contains(("style", .tag)))
            #expect(s[4].contains(("const", .keyword)) && s[4].contains(("\"</div>\"", .string)))
            #expect(s[5].contains(("script", .tag)))
            #expect(s[6].contains(("let", .keyword)) && s[6].contains(("1", .number)))
            #expect(s[6].contains(("p", .tag)) && s[6].contains(("class", .attribute)))
            #expect(!hlSpans("<script>let y = 1;</script>", .xml)[0].contains(("let", .keyword)), "XML does not embed JavaScript")
        }

        @Test func embeddedStateSpansLines() {
            let text = "<script>\n/* open\nstill comment */ var a = 1;\n</script>\n<p>"
            let lexer = LanguageID.html.lexer
            var state = lexer.initialState
            var buffer = TokenBuffer()
            Array("<script>".utf16).withUnsafeBufferPointer {
                lexer.lex(LineBuffer(base: $0.baseAddress!, start: 0, end: $0.count), state: &state, tokens: &buffer)
            }
            #expect(state.embedded == .javascript)
            let s = hlSpans(text, .html)
            #expect(s[1] == [HLSpan("/* open", .comment)])
            #expect(s[2].contains(("still comment */", .comment)) && s[2].contains(("var", .keyword)))
            #expect(s[4].contains(("p", .tag)))
        }

        @Test func scriptTypes() {
            let s = hlSpans("<script type=\"text/x-template\"><div>{{ name }}</div></script>\n<style lang=\"scss\">$a: 1px;</style>", .html)
            #expect(s[0].contains(("div", .tag)) && s[0].contains(("name", .variable)))
            #expect(s[1].contains(("$a", .variable)))
        }

        @Test func templates() {
            let s = hlSpans("""
            <h1>Hello {{ user.name | upper }}</h1>
            {% if admin %}<a href="/x?id={{ id }}&amp;y=1">A</a>{% endif %}
            {# comment #} {{! handlebars comment }}
            <%= link_to "Home", root_path %>
            {{#each items}}{{/each}}
            """, .html)
            #expect(s[0].contains(("{{", .escape)) && s[0].contains(("user.name", .variable)) && s[0].contains(("|", .operator)) && s[0].contains(("}}", .escape)))
            #expect(s[1].contains(("{%", .escape)) && s[1].contains(("if", .keyword)) && s[1].contains(("admin", .variable)) && s[1].contains(("%}", .escape)))
            #expect(s[1].contains(("id", .variable)) && s[1].contains(("&amp;", .escape)) && s[1].contains(("\"/x?id=", .string)))
            #expect(s[2].contains(("{# comment #}", .comment)) && s[2].contains(("{{! handlebars comment }}", .comment)))
            #expect(s[3].contains(("<%=", .escape)) && s[3].contains(("\"Home\"", .string)) && s[3].contains(("%>", .escape)))
            #expect(s[4].contains(("#each", .keyword)) && s[4].contains(("/each", .keyword)))
            #expect(hlSpans("{#if svelte}<p>x</p>", .html)[0].contains(("p", .tag)), "Svelte blocks are not Jinja comments")
        }

        @Test func multilineTemplates() {
            let s = hlSpans("{% if a\n   and b %}<p>\n{# long\ncomment #}<b>", .html)
            #expect(s[1].contains(("b", .variable)) && s[1].contains(("%}", .escape)) && s[1].contains(("p", .tag)))
            #expect(s[2] == [HLSpan("{# long", .comment)])
            #expect(s[3].contains(("comment #}", .comment)) && s[3].contains(("b", .tag)))
        }

        @Test func unquotedAndVueAttributes() {
            let s = hlSpans("<input type=text disabled><button @click=\"go\" :disabled=\"!ok\" v-if=\"x\">", .html)
            #expect(s[0].contains(("type", .attribute)) && s[0].contains(("text", .string)) && s[0].contains(("disabled", .attribute)))
            #expect(s[0].contains(("@click", .attribute)) && s[0].contains((":disabled", .attribute)) && s[0].contains(("v-if", .attribute)))
        }

        @Test func embeddedAttributeValues() {
            let s = hlSpans("<p style=\"color: red; margin: 0 4px\" onclick=\"go(1); return false\" @click=\"count++\" title=\"x: y\">", .html)
            #expect(s[0].contains(("color", .property)) && s[0].contains(("red", .constant)) && s[0].contains(("4px", .number)))
            #expect(s[0].contains(("go", .function)) && s[0].contains(("return", .keyword)) && s[0].contains(("false", .constant)))
            #expect(s[0].contains(("++", .operator)))
            #expect(s[0].contains(("\"x: y\"", .string)), "other attributes stay strings")
            #expect(hlSpans("<p style=\"color: {{ c }}\">", .html)[0].contains(("c", .variable)), "templates keep the value a string")
            #expect(hlSpans("<p style=\"color: red\">", .xml)[0].contains(("\"color: red\"", .string)), "XML does not embed")
        }

        @Test func robustness() {
            let pool = ["<", "</", ">", "/>", "<!--", "-->", "<![CDATA[", "]]>", "<?xml", "?>", "<!DOCTYPE", "&amp;", "&#x1F;", "=\"", "='",
                        "<script>", "</script>", "<style>", "</style>", "<script type=\"text/x-template\">", "<style lang=\"scss\">", "{{",
                        "}}", "{%", "%}", "{#", "#}", "<%", "%>", "<%#", "{{!", "${", "attr", "div", "/*", "*/"]
            expectRobustLexing(.xml, pool: pool)
            expectRobustLexing(.html, pool: pool)
        }
    }
}

// MARK: - CSS / SCSS / Less

extension ConfigMarkupShellLexerTests {
    @Suite struct CSS {
        @Test func selectors() {
            let s = hlSpans("html, body > main .card#hero:not(.hidden)::before, input[type=\"text\" i] * {", .css)
            #expect(s[0].contains(("html", .tag)) && s[0].contains((",", .punctuation)) && s[0].contains((">", .operator)))
            #expect(s[0].contains((".card", .attribute)) && s[0].contains(("#hero", .attribute)) && s[0].contains((".hidden", .attribute)))
            #expect(s[0].contains((":not", .keyword)) && s[0].contains(("::before", .keyword)))
            #expect(s[0].contains(("type", .attribute)) && s[0].contains(("\"text\"", .string)) && s[0].contains(("i", .keyword)))
            #expect(s[0].contains(("*", .operator)) && s[0].contains(("{", .punctuation)))
        }

        @Test func declarations() {
            let s = hlSpans("""
            a {
              margin: -10px auto 0;
              font: bold 12px/1.5 "Helvetica Neue", sans-serif;
              color: rgba(0, 0, 0, .5) !important;
              width: calc(100% - var(--gap));
              background: #fff url(img/bg.png) no-repeat;
              --main-color: #06c;
              content: "\\201C";
            }
            """, .css)
            #expect(s[1].contains(("margin", .property)) && s[1].contains(("-10px", .number)) && s[1].contains(("auto", .constant)))
            #expect(s[2].contains(("bold", .constant)) && s[2].contains(("12px", .number)) && s[2].contains(("\"Helvetica Neue\"", .string)))
            #expect(s[3].contains(("rgba", .function)) && s[3].contains((".5", .number)) && s[3].contains(("!important", .keyword)))
            #expect(s[4].contains(("calc", .function)) && s[4].contains(("100%", .number)) && s[4].contains(("--gap", .variable)))
            #expect(s[5].contains(("#fff", .constant)) && s[5].contains(("url", .function)) && s[5].contains(("img/bg.png", .string)))
            #expect(s[6].contains(("--main-color", .variable)) && s[6].contains(("#06c", .constant)))
            #expect(s[7].contains(("\\201C", .escape)))
        }

        @Test func atRulesAndMediaQueries() {
            let s = hlSpans("@import url(\"a.css\") screen;\n@media screen and (max-width: 600px) {\n  .grid { display: grid }\n}\n@keyframes spin { from { opacity: 0 } 50% { opacity: .5 } }", .css)
            #expect(s[0].contains(("@import", .keyword)) && s[0].contains(("url", .function)) && s[0].contains(("\"a.css\"", .string)))
            #expect(s[1].contains(("@media", .keyword)) && s[1].contains(("and", .keyword)) && s[1].contains(("max-width", .property)) && s[1].contains(("600px", .number)))
            #expect(s[2].contains((".grid", .attribute)) && s[2].contains(("display", .property)) && s[2].contains(("grid", .constant)))
            #expect(s[4].contains(("spin", .function)) && s[4].contains(("from", .keyword)) && s[4].contains(("50%", .number)))
        }

        @Test func multilineSelectorsValuesAndComments() {
            let s = hlSpans("h1,\nh2 {\n  font-family: -apple-system,\n    \"Segoe UI\";\n  color: red\n}\n/* a\nb */ p { a: b }", .css)
            #expect(s[0].contains(("h1", .tag)) && s[1].contains(("h2", .tag)))
            #expect(s[2].contains(("font-family", .property)) && s[2].contains(("-apple-system", .constant)))
            #expect(s[3].contains(("\"Segoe UI\"", .string)))
            #expect(s[4].contains(("color", .property)) && s[4].contains(("red", .constant)))
            #expect(s[6] == [HLSpan("/* a", .comment)])
            #expect(s[7].contains(("b */", .comment)) && s[7].contains(("p", .tag)) && s[7].contains(("a", .property)))
            #expect(hlSpans("a:hover,\nb { }", .css)[0].contains((":hover", .keyword)))
        }

        @Test func minifiedCSS() {
            let s = hlSpans("a{color:red;background:blue}a:hover{color:#ABCDEF80}", .css)
            #expect(s[0].contains(("color", .property)) && s[0].contains(("red", .constant)) && s[0].contains(("background", .property)))
            #expect(s[0].contains((":hover", .keyword)) && s[0].contains(("#ABCDEF80", .constant)))
        }

        @Test func scss() {
            let s = hlSpans("""
            // comment
            $primary: #333 !default;
            @mixin respond($bp) { @media (min-width: $bp) { @content; } }
            .btn {
              &:hover { color: darken($primary, 10%); }
              &-large { padding: math.div(10px, 2); }
              .icon-#{$name} { width: 16px; }
              @include respond(medium);
              @extend %placeholder;
              content: "#{$glyph}";
            }
            """, .scss)
            #expect(s[0] == [HLSpan("// comment", .comment)])
            #expect(s[1].contains(("$primary", .variable)) && s[1].contains(("#333", .constant)) && s[1].contains(("!default", .keyword)))
            #expect(s[2].contains(("@mixin", .keyword)) && s[2].contains(("respond", .function)) && s[2].contains(("$bp", .variable)))
            #expect(s[4].contains(("&", .keyword)) && s[4].contains((":hover", .keyword)) && s[4].contains(("darken", .function)))
            #expect(s[5].contains(("-large", .attribute)) && s[5].contains(("math.div", .function)))
            #expect(s[6].contains((".icon-", .attribute)) && s[6].contains(("#{", .escape)) && s[6].contains(("$name", .variable)) && s[6].contains(("}", .escape)))
            #expect(s[7].contains(("@include", .keyword)) && s[7].contains(("respond", .function)) && s[7].contains(("medium", .constant)))
            #expect(s[8].contains(("%placeholder", .attribute)))
            #expect(s[9].contains(("#{", .escape)) && s[9].contains(("$glyph", .variable)))
            #expect(hlSpans("a { b: url(//cdn.example.com/x.png) }", .scss)[0].contains(("//cdn.example.com/x.png", .string)))
        }

        @Test func less() {
            let s = hlSpans("@color: #4D926F;\n.bordered(@width: 2px) { border: @width solid; }\n.guard when (@mode = huge) { a: b }\n.x { w: ~\"calc(100% - @{gutter})\"; }", .less)
            #expect(s[0].contains(("@color", .variable)) && s[0].contains(("#4D926F", .constant)))
            #expect(s[1].contains((".bordered", .attribute)) && s[1].contains(("@width", .variable)))
            #expect(s[2].contains(("when", .keyword)) && s[2].contains(("@mode", .variable)))
            #expect(s[3].contains(("@{gutter}", .variable)))
        }

        @Test func robustness() {
            let pool = ["/*", "*/", "//", "{", "}", ";", ":", "::", "@media", "@include", "@mixin", "#{", "@{", "$var", "@var", "--x", "url(",
                        "!important", "#fff", "10px", ".5em", ".cls", "#id", "&", "[type=", "calc(", "var(--y)", "%ph", "\n  "]
            expectRobustLexing(.css, pool: pool)
            expectRobustLexing(.scss, pool: pool)
            expectRobustLexing(.less, pool: pool)
        }
    }
}

// MARK: - Shell

extension ConfigMarkupShellLexerTests {
    @Suite struct Shell {
        @Test func commandsAndArguments() {
            let s = hlSpans("#!/usr/bin/env bash\nls -la /tmp | grep --color=auto foo > /dev/null 2>&1 && echo done # note\nsudo apt-get install -y curl", .shell)
            #expect(s[0] == [HLSpan("#!/usr/bin/env bash", .meta)])
            #expect(s[1].contains(("ls", .function)) && s[1].contains(("-la", .attribute)) && s[1].contains(("|", .operator)))
            #expect(s[1].contains(("grep", .function)) && s[1].contains(("--color", .attribute)) && s[1].contains(("=", .operator)))
            #expect(s[1].contains((">", .operator)) && s[1].contains(("&&", .operator)) && s[1].contains(("echo", .function)))
            #expect(s[1].contains(("# note", .comment)) && hlKind(of: "foo", in: "grep foo", .shell) == .plain)
            #expect(hlKind(of: "&1", in: "cmd 2>&1", .shell) == .operator)
            #expect(s[2].contains(("sudo", .function)) && s[2].contains(("apt-get", .function)) && s[2].contains(("-y", .attribute)))
        }

        @Test func keywordsOnlyInCommandPosition() {
            let s = hlSpans("if [[ -f \"$f\" ]]; then\n  echo if done\nelif true; then :\nfi\nfor f in *.txt; do cp \"$f\" x; done\nwhile read -r l; do :; done < in.txt", .shell)
            #expect(s[0].contains(("if", .keyword)) && s[0].contains(("[[", .keyword)) && s[0].contains(("]]", .keyword)) && s[0].contains(("then", .keyword)))
            #expect(s[1].contains(("echo", .function)) && !s[1].contains(("if", .keyword)) && !s[1].contains(("done", .keyword)))
            #expect(s[2].contains(("elif", .keyword)) && s[2].contains(("true", .function)))
            #expect(s[4].contains(("for", .keyword)) && s[4].contains(("f", .variable)) && s[4].contains(("in", .keyword)) && s[4].contains(("do", .keyword)))
            #expect(s[4].contains(("cp", .function)) && s[4].contains(("done", .keyword)))
            #expect(s[5].contains(("while", .keyword)) && s[5].contains(("read", .function)) && s[5].contains(("<", .operator)))
        }

        @Test func comments() {
            #expect(hlSpans("echo a#b $# ${#x} # real", .shell)[0] == [
                HLSpan("echo", .function), HLSpan("$#", .variable), HLSpan("${#x}", .variable), HLSpan("# real", .comment),
            ])
            #expect(hlSpans("# whole line", .shell)[0] == [HLSpan("# whole line", .comment)])
        }

        @Test func stringsAndExpansions() {
            let s = hlSpans("echo \"Hi ${NAME:-x} $1 $(whoami) `date` \\$HOME\" 'lit $x' $'a\\tb'", .shell)
            #expect(s[0].contains(("\"Hi ", .string)) && s[0].contains(("${NAME:-x}", .variable)) && s[0].contains(("$1", .variable)))
            #expect(s[0].contains(("$(", .variable)) && s[0].contains(("whoami", .function)) && s[0].contains(("date", .function)))
            #expect(s[0].contains(("\\$", .escape)) && s[0].contains(("'lit $x'", .string)) && s[0].contains(("\\t", .escape)))
            for special in ["$@", "$#", "$?", "$$", "$!", "$*", "$0", "$-"] {
                #expect(hlSpans("echo \(special)", .shell)[0].contains((special, .variable)), "\(special)")
            }
        }

        @Test func multilineStrings() {
            let s = hlSpans("echo \"one\ntwo $x\nthree\" done\necho 'a\nb' c", .shell)
            #expect(s[1].contains(("two ", .string)) && s[1].contains(("$x", .variable)))
            #expect(s[2].contains(("three\"", .string)) && !s[2].contains(("done", .keyword)))
            #expect(s[4].contains(("b'", .string)))
        }

        @Test func substitutionAndArithmetic() {
            let s = hlSpans("result=$(git rev-parse --short HEAD)\ncount=$((count + 1))\n(( i++ ))", .shell)
            #expect(s[0].contains(("result", .property)) && s[0].contains(("=", .operator)) && s[0].contains(("$(", .variable)))
            #expect(s[0].contains(("git", .function)) && s[0].contains(("--short", .attribute)) && s[0].contains((")", .variable)))
            #expect(s[1].contains(("$((", .variable)) && s[1].contains(("count", .variable)) && s[1].contains(("+", .operator)) && s[1].contains(("1", .number)))
            #expect(s[1].contains(("))", .variable)))
            #expect(s[2].contains(("((", .operator)) && s[2].contains(("i", .variable)))
        }

        @Test func assignmentsAndDeclarations() {
            let s = hlSpans("NAME=world cmd\nexport PATH=\"$HOME/bin:$PATH\"\nlocal -r x=1 y\narr=(one two)", .shell)
            #expect(s[0].contains(("NAME", .property)) && s[0].contains(("cmd", .function)))
            #expect(s[1].contains(("export", .function)) && s[1].contains(("PATH", .property)) && s[1].contains(("$HOME", .variable)))
            #expect(s[2].contains(("local", .function)) && s[2].contains(("-r", .attribute)) && s[2].contains(("x", .property)) && s[2].contains(("1", .number)))
            #expect(s[2].contains(("y", .property)))
            #expect(s[3].contains(("arr", .property)) && s[3].contains(("(", .punctuation)) && !s[3].contains(("one", .function)))
        }

        @Test func functionDefinitions() {
            let s = hlSpans("greet() {\n  echo hi\n}\nfunction cleanup {\n  rm -f x\n}", .shell)
            #expect(s[0].contains(("greet", .function)) && s[0].contains(("(", .punctuation)) && s[0].contains(("{", .punctuation)))
            #expect(s[2] == [HLSpan("}", .punctuation)])
            #expect(s[3].contains(("function", .keyword)) && s[3].contains(("cleanup", .function)))
        }

        @Test func caseStatements() {
            let s = hlSpans("case \"$1\" in\n  start|run)\n    echo go ;;\n  *)\n    exit 1 ;;\nesac", .shell)
            #expect(s[0].contains(("case", .keyword)) && s[0].contains(("in", .keyword)))
            #expect(!s[1].contains(("start", .function)) && s[1].contains(("|", .operator)) && s[1].contains((")", .operator)))
            #expect(s[2].contains(("echo", .function)) && s[2].contains((";;", .operator)))
            #expect(s[3].contains(("*", .operator)))
            #expect(s[5] == [HLSpan("esac", .keyword)])
        }

        @Test func heredocs() {
            let s = hlSpans("cat <<EOF > out.txt\nHello $NAME\n\\$HOME\nEOF\ncat <<-'END'\n\tno $expansion\n\tEND\necho after", .shell)
            #expect(s[0].contains(("<<", .operator)) && s[0].contains(("EOF", .meta)) && s[0].contains((">", .operator)))
            #expect(s[1].contains(("Hello ", .string)) && s[1].contains(("$NAME", .variable)))
            #expect(s[2].contains(("\\$", .escape)))
            #expect(s[3] == [HLSpan("EOF", .meta)])
            #expect(s[4].contains(("'END'", .meta)))
            #expect(s[5] == [HLSpan("\tno $expansion", .string)])
            #expect(s[6] == [HLSpan("END", .meta)])
            #expect(s[7].contains(("echo", .function)))
        }

        @Test func lineContinuations() {
            let s = hlSpans("docker run \\\n  -it \\\n  ubuntu\nmake &&\n  make install\ncmd && \\\n  other", .shell)
            #expect(s[0].contains(("\\", .escape)))
            #expect(s[1].contains(("-it", .attribute)))
            #expect(!s[2].contains(("ubuntu", .function)), "a continued line is not in command position")
            #expect(s[4].contains(("make", .function)))
            #expect(s[6].contains(("other", .function)), "a continuation after && still expects a command")
        }

        @Test func carriageReturns() {
            let s = hlSpans("echo hi\r\nls \\\r\n  -la\r\n", .shell)
            #expect(s[0].contains(("echo", .function)))
            #expect(s[1].contains(("\\", .escape)))
            #expect(s[2].contains(("-la", .attribute)))
        }

        @Test func robustness() {
            expectRobustLexing(.shell, pool: ["$(", "$((", "))", "${", "}", "$'", "$\"", "`", "<<EOF", "<<-'EOF'", "EOF", "\tEOF", "<<<", "2>&1", "&>", "|",
                                        "||", "&&", ";;", "case ", " in ", "esac", "if ", "then", "fi", "for ", "do", "done", "function ", "()", "[[",
                                        "]]", "export A=", "local ", "--opt=", "-x", "NAME=", "arr=(", "((", "{ ", " }", "\\\n"])
        }
    }
}

// MARK: - Dockerfile

extension ConfigMarkupShellLexerTests {
    @Suite struct Dockerfile {
        @Test func instructions() {
            let s = hlSpans("""
            # syntax=docker/dockerfile:1
            FROM --platform=$BUILDPLATFORM golang:1.22 AS builder
            ARG VERSION=dev
            ENV GOOS=linux CGO_ENABLED="0"
            ENV LEGACY value here
            COPY --from=builder --chown=app:app /src ./
            EXPOSE 8080/tcp 9090
            LABEL title="My App"
            CMD ["./app", "--port", "8080"]
            from alpine as base
            """, .dockerfile)
            #expect(s[0] == [HLSpan("# syntax=docker/dockerfile:1", .meta)])
            #expect(s[1].contains(("FROM", .keyword)) && s[1].contains(("--platform", .attribute)) && s[1].contains(("$BUILDPLATFORM", .variable)))
            #expect(s[1].contains(("golang:1.22", .string)) && s[1].contains(("AS", .keyword)) && s[1].contains(("builder", .type)))
            #expect(s[2].contains(("VERSION", .property)) && s[2].contains(("=", .operator)) && s[2].contains(("dev", .string)))
            #expect(s[3].contains(("CGO_ENABLED", .property)) && s[3].contains(("\"0\"", .string)))
            #expect(s[4].contains(("LEGACY", .property)) && s[4].contains(("value here", .string)))
            #expect(s[5].contains(("--from", .attribute)) && s[5].contains(("builder", .string)) && s[5].contains(("--chown", .attribute)))
            #expect(s[6].contains(("8080/tcp", .number)) && s[6].contains(("9090", .number)))
            #expect(s[7].contains(("title", .property)) && s[7].contains(("\"My App\"", .string)))
            #expect(s[8].contains(("[", .punctuation)) && s[8].contains(("\"./app\"", .string)) && s[8].contains((",", .punctuation)))
            #expect(s[9].contains(("from", .keyword)) && s[9].contains(("as", .keyword)) && s[9].contains(("base", .type)))
        }

        @Test func shellFormAndContinuations() {
            let s = hlSpans("""
            RUN --mount=type=cache,target=/root/.cache \\
                apt-get update && \\
                # comment inside
                apt-get install -y curl
            ENV A=1 \\
                B=2
            WORKDIR /app
            """, .dockerfile)
            #expect(s[0].contains(("RUN", .keyword)) && s[0].contains(("--mount", .attribute)) && s[0].contains(("type", .property)))
            #expect(s[0].contains(("cache", .string)) && s[0].contains(("\\", .escape)))
            #expect(s[1].contains(("apt-get", .function)) && s[1].contains(("&&", .operator)))
            #expect(s[2] == [HLSpan("# comment inside", .comment)])
            #expect(s[3].contains(("apt-get", .function)) && s[3].contains(("-y", .attribute)))
            #expect(s[5].contains(("B", .property)) && s[5].contains(("2", .string)))
            #expect(s[6].contains(("WORKDIR", .keyword)))
        }

        @Test func heredocs() {
            let s = hlSpans("RUN <<EOF\napt-get update\necho $HOME\nEOF\nCOPY <<EOT /etc/motd\nWelcome $USER\nEOT\nUSER app", .dockerfile)
            #expect(s[0].contains(("<<", .operator)) && s[0].contains(("EOF", .meta)))
            #expect(s[1].contains(("apt-get", .function)))
            #expect(s[2].contains(("$HOME", .variable)))
            #expect(s[3] == [HLSpan("EOF", .meta)])
            #expect(s[5] == [HLSpan("Welcome $USER", .string)])
            #expect(s[6] == [HLSpan("EOT", .meta)])
            #expect(s[7].contains(("USER", .keyword)))
            let shellHeredoc = hlSpans("RUN cat <<EOF > /x\nhello\nEOF\nRUN true", .dockerfile)
            #expect(shellHeredoc[1] == [HLSpan("hello", .string)])
            #expect(shellHeredoc[3].contains(("RUN", .keyword)))
        }

        @Test func escapeDirective() {
            let s = hlSpans("# escape=`\nFROM mcr.microsoft.com/windows\nRUN dir c:\\ `\n    && echo hi\nWORKDIR c:\\app", .dockerfile)
            #expect(s[0] == [HLSpan("# escape=`", .meta)])
            #expect(s[3].contains(("&&", .operator)) && s[3].contains(("echo", .function)))
            #expect(s[4].contains(("WORKDIR", .keyword)))
            #expect(hlSpans("FROM x\n# escape=`", .dockerfile)[1] == [HLSpan("# escape=`", .comment)], "directives only at the top")
        }

        @Test func healthcheckAndOnbuild() {
            let s = hlSpans("HEALTHCHECK --interval=30s CMD curl -f http://localhost/ || exit 1\nONBUILD RUN make", .dockerfile)
            #expect(s[0].contains(("HEALTHCHECK", .keyword)) && s[0].contains(("CMD", .keyword)) && s[0].contains(("curl", .function)))
            #expect(s[1].contains(("ONBUILD", .keyword)) && s[1].contains(("RUN", .keyword)) && s[1].contains(("make", .function)))
        }

        @Test func robustness() {
            expectRobustLexing(.dockerfile, pool: ["FROM ", "RUN ", "CMD ", "ENV ", "ARG ", "LABEL ", "COPY ", "EXPOSE ", "HEALTHCHECK ", "ONBUILD ", " AS ",
                                             "--from=", "--mount=type=cache,target=/x", "[\"a\", \"b\"]", "<<EOF", "EOF", "# escape=`",
                                             "# syntax=x", "$VAR", "${V:-x}", "8080/tcp", "&&", "\\\n"])
        }
    }
}

// MARK: - Makefile

extension ConfigMarkupShellLexerTests {
    @Suite struct Makefile {
        @Test func assignmentsAndRules() {
            let s = hlSpans("""
            CC := gcc
            CFLAGS ?= -O2
            LIBS += -lm
            SRCS = $(wildcard src/*.c)
            VERSION != git describe
            .PHONY: all clean
            all: $(TARGET) | build # default
            $(OBJS): %.o: %.c
            debug: CFLAGS += -g
            """, .makefile)
            #expect(s[0].contains(("CC", .property)) && s[0].contains((":=", .operator)))
            #expect(s[1].contains(("?=", .operator)) && s[2].contains(("+=", .operator)) && s[4].contains(("!=", .operator)))
            #expect(s[3].contains(("$(", .variable)) && s[3].contains(("wildcard", .function)) && s[3].contains((")", .variable)))
            #expect(s[5].contains((".PHONY", .function)) && s[5].contains((":", .operator)))
            #expect(s[6].contains(("all", .function)) && s[6].contains(("$(TARGET)", .variable)) && s[6].contains(("|", .operator)) && s[6].contains(("# default", .comment)))
            #expect(s[7].contains(("$(OBJS)", .variable)) && s[7].contains(("%", .operator)))
            #expect(s[8].contains(("debug", .function)) && s[8].contains(("CFLAGS", .property)) && s[8].contains(("+=", .operator)))
        }

        @Test func recipes() {
            let s = hlSpans("all:\n\t@echo \"Building $@ from $<\"\n\t$(CC) $(CFLAGS) -c $< -o $@\n\t-rm -f $(OBJS)\n\tfor f in $(OBJS); do echo $$f; done", .makefile)
            #expect(s[1].contains(("@", .operator)) && s[1].contains(("echo", .function)) && s[1].contains(("$@", .variable)) && s[1].contains(("$<", .variable)))
            #expect(s[2].contains(("$(CC)", .variable)) && s[2].contains(("$(CFLAGS)", .variable)) && s[2].contains(("-c", .attribute)))
            #expect(s[3].contains(("-", .operator)) && s[3].contains(("rm", .function)) && s[3].contains(("$(OBJS)", .variable)))
            #expect(s[4].contains(("for", .keyword)) && s[4].contains(("$$f", .variable)) && s[4].contains(("done", .keyword)))
        }

        @Test func recipeContinuations() {
            let s = hlSpans("x:\n\tif true; then \\\n\t  echo yes; \\\n\tfi\ny = 1", .makefile)
            #expect(s[1].contains(("if", .keyword)) && s[1].contains(("\\", .escape)))
            #expect(s[2].contains(("echo", .function)))
            #expect(s[3].contains(("fi", .keyword)))
            #expect(s[4].contains(("y", .property)))
        }

        @Test func directives() {
            let s = hlSpans("""
            ifeq ($(OS),Windows_NT)
            else ifneq "$(CC)" "clang"
            endif
            ifdef DEBUG
            endif
            include config.mk
            export PATH := $(PATH):/bin
            override X = 1
            define HELP
            Usage: make $(TARGET)
            endef
            after := 1
            """, .makefile)
            #expect(s[0].contains(("ifeq", .keyword)) && s[0].contains(("$(OS)", .variable)) && s[0].contains((",", .punctuation)))
            #expect(s[1].contains(("else", .keyword)) && s[1].contains(("ifneq", .keyword)) && s[1].contains(("$(CC)", .variable)) && s[1].contains(("\"clang\"", .string)))
            #expect(s[3].contains(("DEBUG", .variable)))
            #expect(s[5].contains(("include", .keyword)))
            #expect(s[6].contains(("export", .keyword)) && s[6].contains(("PATH", .property)) && s[6].contains((":=", .operator)))
            #expect(s[7].contains(("override", .keyword)) && s[7].contains(("X", .property)))
            #expect(s[8].contains(("define", .keyword)) && s[8].contains(("HELP", .property)))
            #expect(s[9] == [HLSpan("$(TARGET)", .variable)])
            #expect(s[10] == [HLSpan("endef", .keyword)])
            #expect(s[11].contains(("after", .property)))
        }

        @Test func nestedDefine() {
            let s = hlSpans("define OUTER\ndefine INNER\n\t@echo $(X)\nendef\nendef\nY = 1", .makefile)
            #expect(s[1].contains(("define", .keyword)) && s[1].contains(("INNER", .property)))
            #expect(s[2].contains(("@", .operator)) && s[2].contains(("$(X)", .variable)))
            #expect(s[3] == [HLSpan("endef", .keyword)] && s[4] == [HLSpan("endef", .keyword)])
            #expect(s[5].contains(("Y", .property)))
        }

        @Test func continuedValues() {
            let s = hlSpans("LIBS = -lm \\\n\t-lpthread\nall: a \\\n\tb\nx = 1", .makefile)
            #expect(s[0].contains(("\\", .escape)))
            #expect(!s[1].contains(("-lpthread", .attribute)), "a continued value is not a recipe")
            #expect(s[4].contains(("x", .property)))
        }

        @Test func robustness() {
            expectRobustLexing(.makefile, pool: ["\t", "$(", "${", "$@", "$<", "$$", "$(shell ", "$(wildcard ", ":=", "?=", "+=", "!=", "::=", "::", ":", "=",
                                           ".PHONY", "ifeq (", "ifdef ", "else", "endif", "define ", "endef", "include ", "export ", "override ",
                                           "@", "%", "\\\n", "\n\t"])
        }
    }
}

// MARK: - Diff

extension ConfigMarkupShellLexerTests {
    @Suite struct Diff {
        @Test func unifiedDiff() {
            let s = hlSpans("""
            diff --git a/f b/f
            index 83db48f..bf269f4 100644
            --- a/f
            +++ b/f
            @@ -1,4 +1,4 @@ func main()
             context
            --- removed line that looks like a header
            +++ added line that looks like a header
            -old
            +new
            \\ No newline at end of file
            new file mode 100644
            """, .diff)
            #expect(s[0] == [HLSpan("diff --git a/f b/f", .meta)] && s[1] == [HLSpan("index 83db48f..bf269f4 100644", .meta)])
            #expect(s[2] == [HLSpan("--- a/f", .meta)] && s[3] == [HLSpan("+++ b/f", .meta)])
            #expect(s[4] == [HLSpan("@@ -1,4 +1,4 @@", .changed), HLSpan("func main()", .function)])
            #expect(s[5].isEmpty)
            #expect(s[6] == [HLSpan("--- removed line that looks like a header", .deleted)])
            #expect(s[7] == [HLSpan("+++ added line that looks like a header", .inserted)])
            #expect(s[8] == [HLSpan("-old", .deleted)] && s[9] == [HLSpan("+new", .inserted)])
            #expect(s[10] == [HLSpan("\\ No newline at end of file", .comment)])
            #expect(s[11] == [HLSpan("new file mode 100644", .meta)])
        }

        @Test func otherFormats() {
            let s = hlSpans("Index: a.txt\n===================================================================\n@@@ -1 -1 +1 @@@\n-a\n+b\n*** 1,2 ****\n! changed", .diff)
            #expect(s[0] == [HLSpan("Index: a.txt", .meta)])
            #expect(s[1].first?.kind == .meta)
            #expect(s[2].first == HLSpan("@@@ -1 -1 +1 @@@", .changed))
            #expect(s[3] == [HLSpan("-a", .deleted)] && s[4] == [HLSpan("+b", .inserted)])
            #expect(s[5] == [HLSpan("*** 1,2 ****", .changed)] && s[6] == [HLSpan("! changed", .changed)])
        }

        @Test func robustness() {
            expectRobustLexing(.diff, pool: ["diff --git a b", "index 1..2", "--- a", "+++ b", "@@ -1,2 +1,3 @@", "@@ -1 +1 @@", "@@@ -1 -1 +1 @@@", "+", "-",
                                       " ", "\\ No newline", "===", "*** 1,2 ****", "! ", "\n+", "\n-", "\n "])
        }
    }
}

// MARK: - Log

extension ConfigMarkupShellLexerTests {
    @Suite struct Log {
        @Test func timestampsAndLevels() {
            let s = hlSpans("""
            2024-01-15 10:30:00,123 ERROR [main] com.example.App - failed
            2024-01-15T10:30:00.123+01:00 WARN low disk
            Jan 15 10:30:00 host sshd[1234]: INFO accepted
            [15/Jan/2024:10:30:00 +0000] DEBUG x
            10:30:00.123 error: boom
            Error: cannot open file
            2024/01/15 10:30:00 [warn] deprecated
            the error was ignored
            """, .log)
            #expect(s[0].contains(("2024-01-15 10:30:00,123", .comment)) && s[0].contains(("ERROR", .logError)))
            #expect(s[1].contains(("2024-01-15T10:30:00.123+01:00", .comment)) && s[1].contains(("WARN", .logWarning)))
            #expect(s[2].contains(("Jan 15 10:30:00", .comment)) && s[2].contains(("INFO", .logInfo)) && s[2].contains(("1234", .number)))
            #expect(s[3].contains(("[15/Jan/2024:10:30:00 +0000]", .comment)) && s[3].contains(("DEBUG", .logDebug)))
            #expect(s[4].contains(("10:30:00.123", .comment)) && s[4].contains(("error", .logError)))
            #expect(s[5].contains(("Error", .logError)))
            #expect(s[6].contains(("warn", .logWarning)))
            #expect(!s[7].contains(("error", .logError)), "lowercase levels only count in clear positions")
        }

        @Test func moreTimestampFormats() {
            let s = hlSpans("Mon, 15 Jan 2024 10:30:00 +0000 sent\nMon Jan 15 10:30:00 2024 x\n[2024-01-15 10:30:00] y", .log)
            #expect(s[0].first == HLSpan("Mon, 15 Jan 2024 10:30:00 +0000", .comment))
            #expect(s[1].first == HLSpan("Mon Jan 15 10:30:00 2024", .comment))
            #expect(s[2].first == HLSpan("[2024-01-15 10:30:00]", .comment))
        }

        @Test func structuredLogs() {
            let s = hlSpans("time=2024-01-15T10:30:00Z level=warn msg=\"disk low\" usage=91%\n{\"level\":\"info\",\"msg\":\"started\"}\n01-15 10:30:00.123  1234  5678 E AndroidRuntime: crash\nW/ActivityManager( 99): slow", .log)
            #expect(s[0].contains(("time", .property)) && s[0].contains(("=", .operator)) && s[0].contains(("2024-01-15T10:30:00Z", .comment)))
            #expect(s[0].contains(("warn", .logWarning)) && s[0].contains(("\"disk low\"", .string)) && s[0].contains(("91%", .number)))
            #expect(s[1].contains(("\"level\"", .property)) && s[1].contains(("\"info\"", .logInfo)) && s[1].contains(("\"started\"", .string)))
            #expect(s[2].contains(("E", .logError)) && s[2].contains(("01-15 10:30:00.123", .comment)))
            #expect(s[3].contains(("W", .logWarning)))
        }

        @Test func valuesAndIdentifiers() {
            let s = hlSpans("""
            GET /api took 12ms (1.5s total, 3MB, 99%) from 192.168.1.10:8080 id=123e4567-e89b-12d3-a456-426614174000
            commit abc1234 at 0x7fff5fbff8c0 see https://example.com/x?y=1. ip ::1 and fe80::1 mac 00:1a:2b:3c:4d:5e
            127.0.0.1 - - "POST /login HTTP/1.1" 200
            """, .log)
            #expect(s[0].contains(("GET", .keyword)) && s[0].contains(("12ms", .number)) && s[0].contains(("1.5s", .number)))
            #expect(s[0].contains(("3MB", .number)) && s[0].contains(("99%", .number)) && s[0].contains(("192.168.1.10:8080", .number)))
            #expect(s[0].contains(("123e4567-e89b-12d3-a456-426614174000", .constant)))
            #expect(s[1].contains(("abc1234", .constant)) && s[1].contains(("0x7fff5fbff8c0", .constant)))
            #expect(s[1].contains(("https://example.com/x?y=1", .url)) && s[1].contains(("::1", .number)) && s[1].contains(("fe80::1", .number)))
            #expect(s[1].contains(("00:1a:2b:3c:4d:5e", .constant)))
            #expect(s[2].contains(("POST", .keyword)) && s[2].contains(("200", .number)))
        }

        @Test func exceptionsAndStackTraces() {
            let s = hlSpans("""
            Exception in thread "main" java.lang.NullPointerException: boom
            \tat com.example.Main.run(Main.java:12)
            Caused by: java.io.IOException
            \t... 3 more
            Traceback (most recent call last):
              File "app.py", line 3, in <module>
            ValueError: invalid literal
            #3  0x00007fff in main () at main.c:12
            """, .log)
            #expect(s[0].contains(("java.lang.NullPointerException", .type)) && s[0].contains(("\"main\"", .string)))
            #expect(s[1] == [HLSpan("at com.example.Main.run(Main.java:12)", .comment)])
            #expect(s[2].contains(("Caused by", .keyword)) && s[2].contains(("java.io.IOException", .type)))
            #expect(s[3] == [HLSpan("... 3 more", .comment)])
            #expect(s[4].contains(("Traceback", .keyword)))
            #expect(s[5] == [HLSpan("File \"app.py\", line 3, in <module>", .comment)])
            #expect(s[6].contains(("ValueError", .type)))
            #expect(s[7].first?.kind == .comment)
        }

        @Test func robustness() {
            expectRobustLexing(.log, pool: ["2024-01-15 10:30:00,123", "2024-01-15T10:30:00Z", "10:30:00.123", "[15/Jan/2024:10:30:00 +0000]",
                                      "Jan 15 10:30:00", "Mon, 15 Jan 2024 10:30:00 +0000", "ERROR", "warn", "[info]", "level=", "\"level\":",
                                      "\"debug\"", " E/Tag:", "W ", "12ms", "1.5s", "99%", "https://x.y/z", "123e4567-e89b-12d3-a456-426614174000",
                                      "0x7fff", "abc1234", "192.168.0.1:80", "::1", "fe80::1%en0", "00:1a:2b:3c:4d:5e", "java.lang.NullPointerException",
                                      "ValueError", "\n    at x.Y.z(F.java:1)", "\n  File \"x.py\", line 3", "\n#3 0x1", "GET", "Caused by:",
                                      "Traceback", "key=value"])
        }
    }
}

// MARK: - CSV / TSV

extension ConfigMarkupShellLexerTests {
    @Suite struct CSV {
        @Test func rainbowColumns() {
            let s = hlSpans("a,b,c,d,e,f,g\n1,\"x, \"\"y\"\"\",,4", .csv)
            #expect(s[0].map(\.kind) == [.rainbow1, .punctuation, .rainbow2, .punctuation, .rainbow3, .punctuation, .rainbow4, .punctuation,
                                         .rainbow5, .punctuation, .rainbow6, .punctuation, .rainbow1])
            #expect(s[1] == [HLSpan("1", .rainbow1), HLSpan(",", .punctuation), HLSpan("\"x, \"\"y\"\"\"", .rainbow2), HLSpan(",", .punctuation),
                             HLSpan(",", .punctuation), HLSpan("4", .rainbow4)])
        }

        @Test func quotedFieldsSpanLines() {
            let s = hlSpans("1,\"multi\nline, still\",3\nnext,row", .csv)
            #expect(s[0].last == HLSpan("\"multi", .rainbow2))
            #expect(s[1] == [HLSpan("line, still\"", .rainbow2), HLSpan(",", .punctuation), HLSpan("3", .rainbow3)])
            #expect(s[2].first == HLSpan("next", .rainbow1))
        }

        @Test func tabSeparated() {
            let s = hlSpans("id\tname\n1\t\"a\tb\"", .tsv)
            #expect(s[0] == [HLSpan("id", .rainbow1), HLSpan("\t", .punctuation), HLSpan("name", .rainbow2)])
            #expect(s[1].last == HLSpan("\"a\tb\"", .rainbow2))
            #expect(hlSpans("a,b\r\n", .csv)[0].last == HLSpan("b", .rainbow2), "the carriage return is not part of the field")
        }

        @Test func robustness() {
            expectRobustLexing(.csv, pool: [",", "\"", "\"\"", "\t", "a", "1"])
            expectRobustLexing(.tsv, pool: [",", "\"", "\"\"", "\t", "a", "1"])
        }
    }
}

// MARK: - Performance

/// Long lines made of one repeated fragment must lex in linear time (the engine lexes lines of up
/// to 20,000 UTF-16 units; a quadratic scan would take seconds here).
extension ConfigMarkupShellLexerTests {
    @Suite struct PathologicalLines {
        static let languages: [LanguageID] = [.ini, .toml, .properties, .conf, .sshConfig, .xcconfig, .gitignore, .xml, .html, .css, .scss,
                                              .less, .shell, .dockerfile, .makefile, .diff, .log, .csv, .tsv]
        static let fragments = ["[", "[[", "{", "{{", "{%", "{#", "<%", "$(", "$((", "${", "%(", "%{", "@{", "#{", "\"", "'", "`", "<", "</",
                                "<a ", "<!--", "<![CDATA[", "<?", "<!", "/*", "(", "((", "\\", "*", "[a", "<<", "\"$(", "&#", "&", ":", "::",
                                "-", "a=", "$", "@", "!", ";", "|", "x ", "0x", "1.", "1:", "=", "\"a", "'a ", "--", "#", "a:b ", "\t", " "]

        @Test(arguments: languages)
        func linearTime(_ language: LanguageID) {
            let clock = ContinuousClock()
            for fragment in Self.fragments {
                let line = String(repeating: fragment, count: max(1, 20_000 / fragment.utf16.count))
                let elapsed = clock.measure {
                    _ = SyntaxHighlighter.tokenize(line + "\n" + line, language: language)
                }
                #expect(elapsed < .seconds(1), "\(language) took \(elapsed) on a line of \(fragment.debugDescription)")
            }
        }
    }
}
