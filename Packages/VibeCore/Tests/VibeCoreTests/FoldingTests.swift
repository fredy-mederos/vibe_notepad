import Foundation
import Testing
@testable import VibeCore

@Suite struct FoldingTests {
    private func hidden(_ text: String, _ region: FoldRegion) -> String {
        (text as NSString).substring(with: region.hiddenRange)
    }

    @Test func jsonObjectsAndArrays() {
        let json = """
        {
          "name": "vibe",
          "tags": ["a", "b"],
          "meta": {
            "created": "2024",
            "note": "brace } inside a string"
          },
          "items": [
            1,
            2
          ]
        }
        """
        let regions = FoldingAnalyzer.regions(in: json as NSString, language: .json)
        #expect(regions.count == 3) // root, meta, items — the one-line array isn't foldable
        #expect(regions.map(\.depth) == [0, 1, 1])
        // Folding "meta" hides from the end of its first line up to the closing brace.
        let meta = regions[1]
        #expect(hidden(json, meta).hasPrefix("\n    \"created\""))
        #expect(hidden(json, meta).hasSuffix("string\"\n  "))
        #expect((json as NSString).character(at: meta.hiddenEnd) == 0x7D) // }
        // Lookup by the line feed that ends the first line.
        #expect(regions.region(startingAtLineEnd: meta.hiddenStart) == meta)
    }

    @Test func commentsAndStringsAreIgnored() {
        let swift = """
        func a() { // {
            let s = "{"
            /* { */
        }
        """
        let regions = FoldingAnalyzer.regions(in: swift as NSString, language: .swift)
        #expect(regions.count == 1)
    }

    @Test func yamlIndentation() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "80"

          db:
            image: postgres
        volumes: {}
        """
        let regions = FoldingAnalyzer.regions(in: yaml as NSString, language: .yaml)
        let firstLines = regions.map { (yaml as NSString).substring(to: $0.hiddenStart).components(separatedBy: "\n").last ?? "" }
        #expect(firstLines == ["services:", "  web:", "    ports:", "  db:"])
        #expect(hidden(yaml, regions[0]).hasSuffix("image: postgres"))
    }

    @Test func markdownHeadings() {
        let md = """
        # Title
        intro
        ## A
        text

        ## B
        ```
        # not a heading
        ```
        """
        let regions = FoldingAnalyzer.regions(in: md as NSString, language: .markdown)
        #expect(regions.count == 3)
        #expect(hidden(md, regions[1]) == "\ntext")
        #expect(regions[0].depth == 0 && regions[1].depth == 1)
    }

    @Test func foldStateTracksEdits() {
        var state = FoldState()
        state.fold(NSRange(location: 10, length: 20))
        state.fold(NSRange(location: 12, length: 5)) // nested
        state.fold(NSRange(location: 50, length: 10))
        #expect(state.effective == [NSRange(location: 10, length: 20), NSRange(location: 50, length: 10)])
        #expect(state.hiddenRange(containing: 15) == NSRange(location: 10, length: 20))
        #expect(state.hiddenRange(containing: 10) == nil) // the first position stays reachable
        #expect(state.hiddenRange(containing: 30) == nil)

        // Typing before everything shifts all folds.
        state.applyEdit(editedRange: NSRange(location: 0, length: 3), changeInLength: 3)
        #expect(state.effective.first == NSRange(location: 13, length: 20))

        // Editing inside a fold drops it (and the nested one).
        let removed = state.applyEdit(editedRange: NSRange(location: 16, length: 1), changeInLength: 1)
        #expect(removed.count == 2)
        #expect(state.effective == [NSRange(location: 54, length: 10)])

        // Revealing a match inside a fold unfolds it.
        let unfolded = state.unfold(containing: NSRange(location: 58, length: 2))
        #expect(unfolded)
        #expect(state.isEmpty)
    }

    @Test func unsupportedLanguagesHaveNoRegions() {
        #expect(!FoldingAnalyzer.supportsFolding(.plainText))
        #expect(FoldingAnalyzer.regions(in: "a {\n}\n", language: .plainText).isEmpty)
    }

    @Test func largeJSONIsFast() {
        var text = "[\n"
        for i in 0..<20_000 { text += "  {\n    \"id\": \(i),\n    \"tags\": [\n      \"x\"\n    ]\n  },\n" }
        text += "  {}\n]\n"
        let start = Date()
        let regions = FoldingAnalyzer.regions(in: text as NSString, language: .json)
        #expect(regions.count == 40_001)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
