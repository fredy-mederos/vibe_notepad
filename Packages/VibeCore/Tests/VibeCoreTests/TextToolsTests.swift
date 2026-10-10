import Foundation
import Testing
@testable import VibeCore

private func apply(_ edit: TextEdit, to text: String) -> String {
    (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
}

@Suite struct CodecTests {
    @Test func utf8AndLineEndings() throws {
        let decoded = try TextFileCodec.decode(Data("a\r\nb\r\nc".utf8))
        #expect(decoded.text == "a\nb\nc")
        #expect(decoded.lineEnding == .crlf)
        #expect(decoded.encoding == .utf8)
        #expect(!decoded.hasBOM)
        let data = try TextFileCodec.encode(decoded.text, encoding: decoded.encoding, hasBOM: decoded.hasBOM, lineEnding: decoded.lineEnding)
        #expect(data == Data("a\r\nb\r\nc".utf8))
    }

    @Test func bomRoundTrip() throws {
        let original = Data([0xEF, 0xBB, 0xBF] + Array("héllo\n".utf8))
        let decoded = try TextFileCodec.decode(original)
        #expect(decoded.hasBOM)
        #expect(decoded.text == "héllo\n")
        #expect(try TextFileCodec.encode(decoded.text, encoding: .utf8, hasBOM: true, lineEnding: .lf) == original)
    }

    @Test func utf16WithAndWithoutBOM() throws {
        var le = Data([0xFF, 0xFE])
        le.append("hi there".data(using: .utf16LittleEndian)!)
        #expect(try TextFileCodec.decode(le).text == "hi there")
        let noBOM = "plain ascii text".data(using: .utf16LittleEndian)!
        let decoded = try TextFileCodec.decode(noBOM)
        #expect(decoded.text == "plain ascii text")
        #expect(decoded.encoding == .utf16LittleEndian)
    }

    @Test func latin1Fallback() throws {
        let data = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in Latin-1
        let decoded = try TextFileCodec.decode(data)
        #expect(decoded.text == "café")
        #expect(decoded.encoding != .utf8)
    }

    @Test func binaryIsRejected() {
        #expect(throws: TextFileCodec.CodecError.self) {
            try TextFileCodec.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x01, 0x02, 0x00]))
        }
    }

    @Test func indentationDetection() {
        #expect(TextFileCodec.detectIndentation(in: "a:\n  b:\n    c: 1\n  d: 2\n") == Indentation(usesTabs: false, width: 2))
        #expect(TextFileCodec.detectIndentation(in: "func a() {\n    b()\n    if x {\n        c()\n    }\n}\n") == Indentation(usesTabs: false, width: 4))
        #expect(TextFileCodec.detectIndentation(in: "a {\n\tb\n\tc\n}\n") == Indentation(usesTabs: true, width: 4))
        #expect(TextFileCodec.detectIndentation(in: "no indentation\nat all\n") == nil)
    }
}

@Suite struct TransformTests {
    @Test func indentAndOutdent() throws {
        let text = "a\nb\n\nc"
        let edit = TextTransforms.indent(text as NSString, selection: NSRange(location: 0, length: 6), unit: "  ")
        #expect(apply(edit, to: text) == "  a\n  b\n\n  c")
        let indented = apply(edit, to: text)
        let back = try #require(TextTransforms.outdent(indented as NSString, selection: edit.selection, tabWidth: 2))
        #expect(apply(back, to: indented) == text)
    }

    @Test func toggleLineComments() throws {
        let text = "  let a = 1\n  let b = 2\n"
        let on = try #require(TextTransforms.toggleComment(text as NSString, selection: NSRange(location: 0, length: 20), lineComment: "//", blockComment: nil))
        let commented = apply(on, to: text)
        #expect(commented == "  // let a = 1\n  // let b = 2\n")
        let off = try #require(TextTransforms.toggleComment(commented as NSString, selection: NSRange(location: 0, length: 5), lineComment: "//", blockComment: nil))
        #expect(apply(off, to: commented) == "  let a = 1\n  // let b = 2\n")
    }

    @Test func toggleBlockComments() throws {
        let text = "<p>hi</p>"
        let on = try #require(TextTransforms.toggleComment(text as NSString, selection: NSRange(location: 0, length: 0), lineComment: nil, blockComment: ("<!--", "-->")))
        let wrapped = apply(on, to: text)
        #expect(wrapped == "<!-- <p>hi</p> -->")
        let off = try #require(TextTransforms.toggleComment(wrapped as NSString, selection: NSRange(location: 0, length: 0), lineComment: nil, blockComment: ("<!--", "-->")))
        #expect(apply(off, to: wrapped) == text)
    }

    @Test func moveLines() throws {
        let text = "one\ntwo\nthree"
        let down = try #require(TextTransforms.moveLines(text as NSString, selection: NSRange(location: 1, length: 0), up: false))
        #expect(apply(down, to: text) == "two\none\nthree")
        #expect(down.selection.location == 5)
        let lastUp = try #require(TextTransforms.moveLines(text as NSString, selection: NSRange(location: 9, length: 0), up: true))
        #expect(apply(lastUp, to: text) == "one\nthree\ntwo")
        let lastDown = try #require(TextTransforms.moveLines("a\nb" as NSString, selection: NSRange(location: 0, length: 0), up: false))
        #expect(apply(lastDown, to: "a\nb") == "b\na")
        #expect(TextTransforms.moveLines(text as NSString, selection: NSRange(location: 0, length: 0), up: true) == nil)
    }

    @Test func duplicateAndDelete() {
        let text = "one\ntwo"
        let dup = TextTransforms.duplicate(text as NSString, selection: NSRange(location: 5, length: 0))
        #expect(apply(dup, to: text) == "one\ntwo\ntwo")
        #expect(dup.selection.location == 9)
        let del = TextTransforms.deleteLines(text as NSString, selection: NSRange(location: 5, length: 0))
        #expect(apply(del, to: text) == "one")
        let delFirst = TextTransforms.deleteLines(text as NSString, selection: NSRange(location: 0, length: 0))
        #expect(apply(delFirst, to: text) == "two")
    }

    @Test func joinAndSort() throws {
        let joined = try #require(TextTransforms.joinLines("a  \n   b\nc" as NSString, selection: NSRange(location: 0, length: 0)))
        #expect(apply(joined, to: "a  \n   b\nc") == "a b\nc")
        let sorted = try #require(TextTransforms.sortLines("pear\nApple\nbanana\napple" as NSString, selection: NSRange(location: 0, length: 0), unique: true))
        #expect(apply(sorted, to: "pear\nApple\nbanana\napple") == "Apple\nbanana\npear")
    }

    @Test func smartNewlines() {
        func enter(_ text: String, at location: Int, _ language: LanguageID = .swift) -> (String, Int) {
            let edit = TextTransforms.newline(text as NSString, selection: NSRange(location: location, length: 0), indentUnit: "    ", language: language)
            return (apply(edit, to: text), edit.selection.location)
        }
        #expect(enter("    foo", at: 7).0 == "    foo\n    ")
        let braces = enter("func a() {}", at: 10)
        #expect(braces.0 == "func a() {\n    \n}")
        #expect(braces.1 == 15)
        #expect(enter("if x:", at: 5, .python).0 == "if x:\n    ")
        #expect(enter("- item", at: 6, .markdown).0 == "- item\n- ")
        #expect(enter("  3. third", at: 10, .markdown).0 == "  3. third\n  4. ")
        #expect(enter("- [x] done", at: 10, .markdown).0 == "- [x] done\n- [ ] ")
        #expect(enter("> quoted", at: 8, .markdown).0 == "> quoted\n> ")
        let ended = enter("- item\n- ", at: 9, .markdown)
        #expect(ended.0 == "- item\n")
        #expect(ended.1 == 7)
    }

    @Test func jsonFormattingKeepsOrder() throws {
        let pretty = try TextTransforms.formatJSON(#"{"b":1,"a":[1,2,{}],"c":{"x":"y:z"}}"#)
        #expect(pretty == """
        {
          "b": 1,
          "a": [
            1,
            2,
            {}
          ],
          "c": {
            "x": "y:z"
          }
        }
        """)
        #expect(try TextTransforms.minifyJSON(pretty) == #"{"b":1,"a":[1,2,{}],"c":{"x":"y:z"}}"#)
        #expect(throws: TextTransforms.JSONFormatError.self) { try TextTransforms.formatJSON("{nope") }
    }

    @Test func trimKeepsTheCaretOnItsLine() throws {
        // Caret inside trailing spaces on the first line.
        let text = "abc   \nnext  \nend" as NSString
        let edit = try #require(TextTransforms.trimTrailingWhitespace(text, selection: NSRange(location: 5, length: 0)))
        #expect(edit.replacement == "abc\nnext\nend")
        #expect(edit.selection.location == 3)
        // Caret after the trimmed lines keeps its place in the text.
        let later = try #require(TextTransforms.trimTrailingWhitespace(text, selection: NSRange(location: 15, length: 0)))
        #expect(later.selection.location == 10)
    }

    @Test func formatJSONKeepsComments() throws {
        let source = """
        // Editor settings
        {"tabSize": 2, // spaces
          /* theme */ "theme": "dark",
          "list": [1, /* two */ 2]
        } // end
        """
        let pretty = try TextTransforms.formatJSON(source)
        #expect(pretty == """
        // Editor settings
        {
          "tabSize": 2, // spaces
          /* theme */
          "theme": "dark",
          "list": [
            1, /* two */
            2
          ]
        } // end
        """)
        // Formatting is stable, and minifying drops comments.
        #expect(try TextTransforms.formatJSON(pretty) == pretty)
        #expect(try TextTransforms.minifyJSON(source) == #"{"tabSize":2,"theme":"dark","list":[1,2]}"#)
    }

    @Test func caseTransformOnWord() throws {
        let edit = try #require(TextTransforms.transform("hello world" as NSString, selection: NSRange(location: 8, length: 0)) { $0.uppercased() })
        #expect(apply(edit, to: "hello world") == "hello WORLD")
    }
}

@Suite struct FindTests {
    @Test func literalAndRegex() throws {
        let text = "Foo foo food FOO" as NSString
        #expect(try FindEngine.matches(of: "foo", in: text, options: FindOptions()).count == 4)
        #expect(try FindEngine.matches(of: "foo", in: text, options: FindOptions(caseSensitive: true)).count == 2)
        #expect(try FindEngine.matches(of: "foo", in: text, options: FindOptions(wholeWord: true)).count == 3)
        #expect(try FindEngine.matches(of: "f(o+)d", in: text, options: FindOptions(isRegex: true)).count == 1)
        #expect(try FindEngine.matches(of: "a.b", in: "a.b axb" as NSString, options: FindOptions()).count == 1)
        #expect(throws: FindEngine.FindError.self) { try FindEngine.matches(of: "(", in: text, options: FindOptions(isRegex: true)) }
    }

    @Test func replaceAllWithGroupsAndEscapes() throws {
        let text = "key=value\nother=thing" as NSString
        let edits = try FindEngine.replaceAll(in: text, pattern: "(\\w+)=(\\w+)", template: "$2:$1\\t", options: FindOptions(isRegex: true))
        #expect(edits.map(\.1) == ["value:key\t", "thing:other\t"])
        let prefix = try FindEngine.replaceAll(in: "a\nb" as NSString, pattern: "^", template: "// ", options: FindOptions(isRegex: true))
        #expect(prefix.count == 2)
        let literal = try FindEngine.replaceAll(in: "cost $5" as NSString, pattern: "$5", template: "$10", options: FindOptions())
        #expect(literal.map(\.1) == ["$10"])
    }
}

@Suite struct FuzzyTests {
    @Test func ranksSensibly() throws {
        #expect(FuzzyMatcher.match("xyz", in: "abc") == nil)
        let a = try #require(FuzzyMatcher.match("env", in: "~/project/.env"))
        let b = try #require(FuzzyMatcher.match("env", in: "~/src/environment/handler.swift"))
        #expect(a.score > b.score)
        let camel = try #require(FuzzyMatcher.match("ctv", in: "CodeTextView.swift"))
        #expect(camel.positions == [0, 4, 8])
        let prefix = try #require(FuzzyMatcher.match("read", in: "README.md"))
        #expect(prefix.positions == [0, 1, 2, 3])
    }

    @Test func positionsCountCharactersNotCodeUnits() throws {
        let accented = try #require(FuzzyMatcher.match("ne", in: "café/naïve.md"))
        #expect(accented.positions == [5, 9])
        let emoji = try #require(FuzzyMatcher.match("n", in: "😀notes.md"))
        #expect(emoji.positions == [1])
        let uppercase = try #require(FuzzyMatcher.match("ü", in: "Über.txt"))
        #expect(uppercase.positions == [0])
        #expect(FuzzyMatcher.match("a b", in: "alpha beta") == FuzzyMatcher.match("ab", in: "alpha beta"))
    }
}

@Suite struct ThemeTests {
    @Test func everyThemeStylesEveryKind() {
        for theme in Themes.all {
            for kind in TokenKind.allCases where kind != .plain {
                #expect(theme.style(for: kind) != nil, "\(theme.name) misses \(kind)")
            }
            // Text must be readable on the background.
            let contrast = (max(theme.foreground.luminance, theme.background.luminance) + 0.05) / (min(theme.foreground.luminance, theme.background.luminance) + 0.05)
            #expect(contrast > 4.5, "\(theme.name) contrast \(contrast)")
            #expect(theme.isDark == (theme.background.luminance < 0.2))
        }
        #expect(Set(Themes.all.map(\.id)).count == Themes.all.count)
    }

    @Test func hexParsing() {
        #expect(RGBA("#FF8000").hex == "#FF8000")
        #expect(RGBA("#0000000A").a < 0.05)
        #expect(RGBA("#abc").hex == "#AABBCC")
    }
}
