import Foundation
import Testing
@testable import VibeCore

@Suite struct SymbolTests {
    @Test func swiftSymbols() {
        let source = """
        import Foundation
        @MainActor final class Store {
            private(set) var items: [Int] = []
            public static func make() -> Store { Store() }
            func add(_ x: Int) {}
        }
        struct Point {}
        extension Store.Nested {}
        enum Kind { case a }
        """
        let symbols = SymbolExtractor.symbols(in: source, language: .swift)
        #expect(symbols.map(\.name) == ["Store", "make", "add", "Point", "Store.Nested", "Kind"])
        #expect(symbols.first?.kind == .type)
        #expect(symbols[1].kind == .function)
        #expect(symbols[1].line == 3)
    }

    @Test func markdownHeadingsSkipCode() {
        let source = "# Title\ntext\n```\n# not a heading\n```\n## Section ##\n####### too deep"
        let symbols = SymbolExtractor.symbols(in: source, language: .markdown)
        #expect(symbols.map(\.name) == ["Title", "Section"])
        #expect(symbols.map(\.level) == [1, 2])
        #expect(symbols.map(\.line) == [0, 5])
    }

    @Test func configSymbols() {
        #expect(SymbolExtractor.symbols(in: "A=1\nexport B_C=2\n# c\n", language: .env).map(\.name) == ["A", "B_C"])
        #expect(SymbolExtractor.symbols(in: "[core]\n\teditor = vim\n[remote \"origin\"]\n", language: .ini).map(\.name) == ["core", "remote \"origin\""])
        #expect(SymbolExtractor.symbols(in: "build: deps\n\tcc x\nCC := gcc\n.PHONY: build\n", language: .makefile).map(\.name) == ["build", ".PHONY"])
        #expect(SymbolExtractor.symbols(in: "name: x\nspec:\n  nested: 1\n", language: .yaml).map(\.name) == ["name", "spec"])
        #expect(SymbolExtractor.symbols(in: "def run(self):\n    pass\nclass A:\n", language: .python).map(\.name) == ["run", "A"])
        #expect(SymbolExtractor.symbols(in: "func main() {}\nfunc (s *S) Do() {}\ntype S struct{}\n", language: .go).map(\.name) == ["main", "Do", "S"])
        #expect(SymbolExtractor.symbols(in: "export const handler = async (event) => {}\nfunction go() {}\n", language: .javascript).map(\.name) == ["handler", "go"])
    }

    @Test func everyLanguageIsSafe() {
        let garbage = "func (x) {\nclass\n# h\n[s]\nk=v\n"
        for language in LanguageID.allCases {
            _ = SymbolExtractor.symbols(in: garbage, language: language)
        }
    }
}
