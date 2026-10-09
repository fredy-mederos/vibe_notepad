import Foundation
import Testing
@testable import VibeCore

/// `(text, kind)` pairs for every token, line by line.
func spans(_ text: String, _ language: LanguageID) -> [[(String, TokenKind)]] {
    let lines = text.components(separatedBy: "\n")
    let tokens = SyntaxHighlighter.tokenize(text, language: language)
    return zip(lines, tokens).map { line, lineTokens in
        let units = Array(line.utf16)
        return lineTokens.map { t in
            (String(decoding: units[t.start..<min(units.count, t.start + t.length)], as: UTF16.self), t.kind)
        }
    }
}

func has(_ spans: [[(String, TokenKind)]], _ text: String, _ kind: TokenKind, line: Int? = nil) -> Bool {
    let candidates = line.map { [spans[$0]] } ?? spans
    return candidates.contains { $0.contains { $0.0 == text && $0.1 == kind } }
}

@Suite struct LanguageDetectionTests {
    @Test func detectsByNameAndExtension() {
        #expect(LanguageRegistry.detect(path: "/x/.env") == .env)
        #expect(LanguageRegistry.detect(path: "/x/.env.local") == .env)
        #expect(LanguageRegistry.detect(path: "/x/production.env") == .env)
        #expect(LanguageRegistry.detect(path: "/x/.envrc") == .shell)
        #expect(LanguageRegistry.detect(path: "/x/README.md") == .markdown)
        #expect(LanguageRegistry.detect(path: "/x/Dockerfile") == .dockerfile)
        #expect(LanguageRegistry.detect(path: "/x/Dockerfile.dev") == .dockerfile)
        #expect(LanguageRegistry.detect(path: "/x/Makefile") == .makefile)
        #expect(LanguageRegistry.detect(path: "/Users/me/.zshrc") == .shell)
        #expect(LanguageRegistry.detect(path: "/Users/me/.ssh/config") == .sshConfig)
        #expect(LanguageRegistry.detect(path: "/x/Podfile") == .ruby)
        #expect(LanguageRegistry.detect(path: "/x/build.gradle.kts") == .kotlin)
        #expect(LanguageRegistry.detect(path: "/x/app.ts") == .typescript)
        #expect(LanguageRegistry.detect(path: "/x/.gitignore") == .gitignore)
        #expect(LanguageRegistry.detect(path: "/x/config.yml") == .yaml)
        #expect(LanguageRegistry.detect(path: "/x/Info.plist") == .xml)
        #expect(LanguageRegistry.detect(path: "/x/server.log") == .log)
        #expect(LanguageRegistry.detect(path: "/x/server.log.1") == .log)
        #expect(LanguageRegistry.detect(path: "/x/env.json") == .json)
    }

    @Test func detectsByContent() {
        #expect(LanguageRegistry.detect(path: "/x/script", content: "#!/usr/bin/env python3\nprint(1)") == .python)
        #expect(LanguageRegistry.detect(path: "/x/run", content: "#!/bin/bash\necho hi") == .shell)
        #expect(LanguageRegistry.detect(path: "/x/data", content: "{\n  \"a\": 1\n}") == .json)
        #expect(LanguageRegistry.detect(path: "/x/settings", content: "API_KEY=abc\nDEBUG=true\n# c\n") == .env)
        #expect(LanguageRegistry.detect(path: "/x/notes", content: "hello world") == .plainText)
        #expect(LanguageRegistry.detect(path: "/x/thing.h", content: "@interface Foo : NSObject\n@end") == .objectiveC)
    }

    @Test func fenceInfoStrings() {
        #expect(LanguageRegistry.language(forFenceInfo: "swift") == .swift)
        #expect(LanguageRegistry.language(forFenceInfo: "js {linenos}") == .javascript)
        #expect(LanguageRegistry.language(forFenceInfo: "language-ts") == .typescript)
        #expect(LanguageRegistry.language(forFenceInfo: "bash") == .shell)
        #expect(LanguageRegistry.language(forFenceInfo: "unknownlang") == nil)
        #expect(LanguageRegistry.language(forFenceInfo: "") == nil)
    }
}

@Suite struct EnvLexerTests {
    @Test func keysValuesAndComments() {
        let s = spans("""
        # Database
        export DB_HOST=localhost
        DB_PORT=5432
        DEBUG=true
        URL="postgres://${DB_HOST}:$DB_PORT/app" # inline
        NAME='literal $NOT'
        EMPTY=
        """, .env)
        #expect(has(s, "# Database", .comment, line: 0))
        #expect(has(s, "export", .keyword, line: 1))
        #expect(has(s, "DB_HOST", .property, line: 1))
        #expect(has(s, "=", .operator, line: 1))
        #expect(has(s, "localhost", .string, line: 1))
        #expect(has(s, "5432", .number, line: 2))
        #expect(has(s, "true", .constant, line: 3))
        #expect(has(s, "${DB_HOST}", .variable, line: 4))
        #expect(has(s, "$DB_PORT", .variable, line: 4))
        #expect(has(s, "# inline", .comment, line: 4))
        #expect(has(s, "'literal $NOT'", .string, line: 5))
        #expect(has(s, "EMPTY", .property, line: 6))
    }

    @Test func multilineQuotedValue() {
        let s = spans("KEY=\"line one\nline two\"\nNEXT=1", .env)
        #expect(has(s, "line two\"", .string, line: 1))
        #expect(has(s, "NEXT", .property, line: 2))
    }
}

@Suite struct JSONLexerTests {
    @Test func keysAndValues() {
        let s = spans("""
        {
          "name": "vibe", // comment
          "count": -12.5e3,
          "ok": true, "none": null,
          "nested": { "a": [1, 2] }
        }
        """, .json)
        #expect(has(s, "\"name\"", .property))
        #expect(has(s, "\"vibe\"", .string))
        #expect(has(s, "// comment", .comment))
        #expect(has(s, "-12.5e3", .number))
        #expect(has(s, "true", .constant))
        #expect(has(s, "null", .constant))
        #expect(has(s, "\"a\"", .property))
    }

    @Test func blockCommentsSpanLines() {
        let s = spans("/* a\nb */ {\"x\": 1}", .json)
        #expect(has(s, "b */", .comment, line: 1))
        #expect(has(s, "\"x\"", .property, line: 1))
    }
}

@Suite struct YAMLLexerTests {
    @Test func mappingsAndScalars() {
        let s = spans("""
        version: "3.9"
        services:
          web:
            image: nginx:1.25
            ports:
              - "8080:80"
            enabled: yes
            replicas: 3
            ratio: 0.5
            anchor: &base { a: 1, b: two }
            ref: *base
            tag: !!str 42
            url: http://example.com # trailing
        on: push
        """, .yaml)
        #expect(has(s, "version", .property))
        #expect(has(s, "\"3.9\"", .string))
        #expect(has(s, "image", .property))
        #expect(has(s, "nginx:1.25", .string))
        #expect(has(s, "-", .punctuation))
        #expect(has(s, "\"8080:80\"", .string))
        #expect(has(s, "yes", .constant))
        #expect(has(s, "3", .number))
        #expect(has(s, "0.5", .number))
        #expect(has(s, "&base", .variable))
        #expect(has(s, "*base", .variable))
        #expect(has(s, "!!str", .type))
        #expect(has(s, "a", .property))
        #expect(has(s, "two", .string))
        #expect(has(s, "http://example.com", .string))
        #expect(has(s, "# trailing", .comment))
        #expect(has(s, "on", .property))
    }

    @Test func blockScalars() {
        let s = spans("""
        run: |
          echo "hi"
          make test

        next: value
        """, .yaml)
        #expect(has(s, "|", .operator, line: 0))
        #expect(has(s, "echo \"hi\"", .string, line: 1))
        #expect(has(s, "make test", .string, line: 2))
        #expect(has(s, "next", .property, line: 4))
    }

    @Test func versionsAndDates() {
        let s = spans("v: 1.2.3\nd: 2024-01-31\nt: 2024-01-31T10:00:00Z\nr: 1-2-3", .yaml)
        #expect(has(s, "1.2.3", .string))
        #expect(has(s, "2024-01-31", .number))
        #expect(has(s, "2024-01-31T10:00:00Z", .number))
        #expect(has(s, "1-2-3", .string))
    }
}

@Suite struct MarkdownLexerTests {
    @Test func headingsEmphasisAndCode() {
        let s = spans("""
        # Title
        Some **bold** and *italic* and `code` and ~~gone~~.
        snake_case_word stays plain
        """, .markdown)
        #expect(has(s, "#", .markup, line: 0))
        #expect(has(s, "Title", .heading, line: 0))
        #expect(has(s, "bold", .strong, line: 1))
        #expect(has(s, "italic", .emphasis, line: 1))
        #expect(has(s, "code", .code, line: 1))
        #expect(has(s, "gone", .strikethrough, line: 1))
        #expect(!s[2].contains { $0.1 == .emphasis })
    }

    @Test func nestedEmphasis() {
        let s = spans("**bold *inner* bold**", .markdown)
        #expect(has(s, "inner", .emphasis))
        #expect(s[0].contains { $0.0.contains("bold") && $0.1 == .strong })
    }

    @Test func linksListsAndTasks() {
        let s = spans("""
        - [ ] todo
        - [x] done
        1. first [link](https://example.com "Title") and https://bare.dev/path.
        > quote with `code`
        [ref]: https://example.com
        """, .markdown)
        #expect(has(s, "-", .listMarker, line: 0))
        #expect(has(s, "[ ]", .listMarker, line: 0))
        #expect(has(s, "[x]", .inserted, line: 1))
        #expect(has(s, "done", .comment, line: 1))
        #expect(has(s, "1.", .listMarker, line: 2))
        #expect(has(s, "link", .link, line: 2))
        #expect(has(s, "https://example.com", .url, line: 2))
        #expect(has(s, "\"Title\"", .string, line: 2))
        #expect(has(s, "https://bare.dev/path", .url, line: 2))
        #expect(has(s, ">", .markup, line: 3))
        #expect(has(s, "code", .code, line: 3))
        #expect(has(s, "[ref]", .link, line: 4))
    }

    @Test func fencedCodeIsHighlightedWithItsLanguage() {
        let s = spans("""
        ```swift
        let x = "hi" // note
        ```
        after **this**
        """, .markdown)
        #expect(has(s, "```", .markup, line: 0))
        #expect(has(s, "swift", .meta, line: 0))
        #expect(has(s, "let", .keyword, line: 1))
        #expect(has(s, "\"hi\"", .string, line: 1))
        #expect(has(s, "// note", .comment, line: 1))
        #expect(has(s, "```", .markup, line: 2))
        #expect(has(s, "this", .strong, line: 3))
    }

    @Test func unknownFenceIsCode() {
        let s = spans("~~~\nraw *text*\n~~~", .markdown)
        #expect(has(s, "raw *text*", .code, line: 1))
    }

    @Test func frontMatterIsYAML() {
        let s = spans("---\ntitle: Hello\n---\n# Doc", .markdown)
        #expect(has(s, "---", .markup, line: 0))
        #expect(has(s, "title", .property, line: 1))
        #expect(has(s, "Hello", .string, line: 1))
        #expect(has(s, "Doc", .heading, line: 3))
    }

    @Test func tables() {
        let s = spans("| a | b |\n| --- | :-: |\n| `x|y` | 2 |", .markdown)
        #expect(has(s, "|", .markup, line: 0))
        #expect(has(s, "| --- | :-: |", .markup, line: 1))
        #expect(has(s, "x|y", .code, line: 2))
    }
}

@Suite struct CodeLexerTests {
    @Test func swiftBasics() {
        let s = spans("""
        @MainActor struct Foo: View {
            let name = "Hi \\(user.name)!" // greet
            func render(_ x: Int) -> some View { Text(name).padding() }
            /* multi
               line */ var y = 0x1F
            #if DEBUG
        }
        """, .swift)
        #expect(has(s, "@MainActor", .meta))
        #expect(has(s, "struct", .keyword))
        #expect(has(s, "Foo", .type))
        #expect(has(s, "View", .type))
        #expect(has(s, "\"Hi ", .string))
        #expect(has(s, "\\(", .escape))
        #expect(has(s, "name", .property))
        #expect(has(s, "// greet", .comment))
        #expect(has(s, "render", .function))
        #expect(has(s, "Int", .type))
        #expect(has(s, "padding", .function))
        #expect(s[4].contains { $0.0.hasSuffix("line */") && $0.1 == .comment })
        #expect(has(s, "0x1F", .number))
        #expect(has(s, "#if", .meta))
    }

    @Test func pythonStringsAndDecorators() {
        let s = spans("""
        @app.route("/")
        def handler(self, n=10):
            return f"value {n + 1}" if n else None
        doc = \"\"\"multi
        line\"\"\"
        """, .python)
        #expect(has(s, "@app.route", .meta))
        #expect(has(s, "def", .keyword))
        #expect(has(s, "handler", .function))
        #expect(has(s, "self", .variable))
        #expect(has(s, "10", .number))
        #expect(has(s, "None", .constant))
        #expect(has(s, "{", .escape))
        #expect(has(s, "line\"\"\"", .string, line: 4))
    }

    @Test func javascriptRegexTemplatesAndJSX() {
        let s = spans("""
        const re = /ab+c/gi; const t = `x ${a + 1} y`;
        return <Button onClick={go} label="Hi" />;
        """, .javascript)
        #expect(has(s, "const", .keyword))
        #expect(has(s, "/ab+c/gi", .regex))
        #expect(has(s, "${", .escape))
        #expect(has(s, "Button", .type))
        #expect(has(s, "onClick", .attribute))
        #expect(has(s, "\"Hi\"", .string))
    }

    @Test func rustLifetimesAndMacros() {
        let s = spans("fn longest<'a>(x: &'a str) -> &'a str { println!(\"{}\", x); 'c' }", .rust)
        #expect(has(s, "fn", .keyword))
        #expect(has(s, "longest", .function))
        #expect(has(s, "'a", .type))
        #expect(has(s, "println", .function))
        #expect(has(s, "'c'", .string))
    }

    @Test func sqlIsCaseInsensitive() {
        let s = spans("SELECT name, COUNT(*) FROM users WHERE id = 'x''y' -- c", .sql)
        #expect(has(s, "SELECT", .keyword))
        #expect(has(s, "COUNT", .function))
        #expect(has(s, "'x''y'", .string))
        #expect(has(s, "-- c", .comment))
    }

    @Test func kotlinTemplates() {
        let s = spans("fun String.shout() = \"$this! ${length}\"", .kotlin)
        #expect(has(s, "fun", .keyword))
        #expect(has(s, "String", .type))
        #expect(has(s, "shout", .function))
        #expect(has(s, "$this", .variable))
    }

    @Test func cPreprocessor() {
        let s = spans("#include <stdio.h>\n#define MAX 10\nsize_t n = MAX;", .c)
        #expect(has(s, "#include", .meta))
        #expect(has(s, "<stdio.h>", .string))
        #expect(has(s, "MAX", .constant, line: 1))
        #expect(has(s, "size_t", .type))
    }
}

@Suite struct SyntaxEngineTests {
    /// The incremental engine must agree with a from-scratch lex after arbitrary edits.
    @Test func incrementalMatchesFullRelex() {
        var rng = SystemRandomNumberGenerator()
        let pieces = ["/*", "*/", "\"", "\n", "let x = 1", " ", "// c", "`", "\"\"\"", "{", "}", "a", "\n\n", "'"]
        let languages: [LanguageID] = [.swift, .markdown, .yaml, .python, .json, .env]
        for language in languages {
            let storage = NSMutableString(string: "let a = 1\n/* comment\n still */\nvar s = \"x\"\n")
            let engine = SyntaxEngine(language: language)
            engine.reset(text: storage)
            for _ in 0..<300 {
                let length = storage.length
                let location = Int.random(in: 0...length, using: &rng)
                let deleteLength = Int.random(in: 0...min(3, length - location), using: &rng)
                let insert = Bool.random(using: &rng) ? pieces.randomElement(using: &rng)! : ""
                storage.replaceCharacters(in: NSRange(location: location, length: deleteLength), with: insert)
                let inserted = (insert as NSString).length
                engine.applyEdit(text: storage, editedRange: NSRange(location: location, length: inserted), changeInLength: inserted - deleteLength)

                let fresh = SyntaxEngine(language: language)
                fresh.reset(text: storage)
                #expect(engine.lineStarts == fresh.lineStarts)
                for line in 0..<fresh.lineCount {
                    #expect(engine.state(atLine: line) == fresh.state(atLine: line))
                }
            }
        }
    }

    @Test func tokensStayInsideLines() {
        let text = NSString(string: "# Title\n```js\nconst a = `x ${b}`\n```\n- [x] done\n")
        let engine = SyntaxEngine(language: .markdown)
        engine.reset(text: text)
        engine.enumerateTokens(lines: 0..<engine.lineCount, text: text) { range, _ in
            let line = engine.lineIndex(containing: range.location)
            #expect(range.location + range.length <= engine.lineContentEnd(line))
        }
    }

    @Test func styledBookkeeping() {
        let text = NSMutableString(string: "a\nb\nc\nd")
        let engine = SyntaxEngine(language: .swift)
        engine.reset(text: text)
        #expect(engine.unstyledRuns(in: 0..<4) == [0..<4])
        engine.markStyled(0..<4)
        #expect(engine.unstyledRuns(in: 0..<4).isEmpty)
        text.replaceCharacters(in: NSRange(location: 2, length: 0), with: "x\ny")
        let changed = engine.applyEdit(text: text, editedRange: NSRange(location: 2, length: 3), changeInLength: 3)
        #expect(changed.contains(1))
        #expect(engine.lineCount == 5)
        #expect(engine.needsStyling(1))
        #expect(!engine.needsStyling(4))
    }

    @Test func htmlHighlighting() {
        let html = SyntaxHighlighter.html("let a = \"<b>\"", language: .swift)
        #expect(html.contains("<span class=\"tk-keyword\">let</span>"))
        #expect(html.contains("&lt;b&gt;"))
    }

    @Test func lexersSurviveGarbage() {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("abc XYZ 0123 _-+*/\\\"'`#$@!?:;.,=<>()[]{}|&%^~\t\n\r")
        for language in LanguageID.allCases {
            var text = ""
            for _ in 0..<2000 { text.append(alphabet.randomElement(using: &rng)!) }
            let lines = SyntaxHighlighter.tokenize(text, language: language)
            let units = text.components(separatedBy: "\n").map { $0.utf16.count }
            for (index, tokens) in lines.enumerated() {
                for t in tokens {
                    #expect(t.start >= 0 && t.length > 0 && t.start + t.length <= units[index], "\(language) produced out-of-range token")
                }
            }
        }
    }
}
