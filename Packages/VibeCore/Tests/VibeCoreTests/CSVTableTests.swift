import Foundation
import Testing
@testable import VibeCore

@Suite struct CSVTableTests {
    private func rows(_ table: CSVTable) -> [[String]] {
        (0..<table.rowCount).map { table.values(row: $0) }
    }

    @Test func plainRecords() {
        let table = CSVTable("name,age\nBob,32\nAlice,40\n")
        #expect(table.delimiter == .comma)
        #expect(rows(table) == [["name", "age"], ["Bob", "32"], ["Alice", "40"]])
        #expect(table.columnCount == 2)
        #expect(table.firstRowLooksLikeHeader)
    }

    @Test func quotedFields() {
        let table = CSVTable("a,\"b, c\",\"say \"\"hi\"\"\"\n\"multi\nline\",x,\"\"")
        #expect(rows(table) == [["a", "b, c", "say \"hi\""], ["multi\nline", "x", ""]])
        // Records are found by line: the second one starts on line 1 and holds line 2 too.
        #expect(table.line(ofRow: 1) == 1)
        // Text after a closing quote is kept; a quote inside an unquoted field is just a character.
        #expect(rows(CSVTable("\"a\"b,5\" screen")) == [["ab", "5\" screen"]])
        // An unclosed quote runs to the end.
        #expect(rows(CSVTable("x,\"open\nstill")) == [["x", "open\nstill"]])
    }

    @Test func lineEndingsAndBlankLines() {
        #expect(rows(CSVTable("a,b\r\nc,d\r\n")) == [["a", "b"], ["c", "d"]])
        #expect(rows(CSVTable("a,b\rc,d")) == [["a", "b"], ["c", "d"]])
        let blank = CSVTable("a,b\n\nc,d")
        #expect(rows(blank) == [["a", "b"], [""], ["c", "d"]])
        #expect((0..<blank.rowCount).map(blank.line(ofRow:)) == [0, 1, 2])
        // CRLF inside quotes counts as one line.
        let quoted = CSVTable("\"a\r\nb\",c\r\nd,e")
        #expect(quoted.line(ofRow: 1) == 2)
        #expect(CSVTable("").rowCount == 0)
        #expect(rows(CSVTable("a,b,")) == [["a", "b", ""]])
    }

    @Test func raggedRows() {
        let table = CSVTable("a,b,c\n1\n2,3")
        #expect(table.columnCount == 3)
        #expect(table.fieldCount(row: 1) == 1)
        #expect(table.value(row: 1, column: 2) == "")
        #expect(table.range(row: 1, column: 1) == nil)
    }

    @Test func rangesMapToTheText() {
        let text = "id,\"x, y\"\n7,\"q\"\"t\""
        let table = CSVTable(text)
        let ns = text as NSString
        #expect(ns.substring(with: table.range(row: 0, column: 1)!) == "\"x, y\"")
        #expect(ns.substring(with: table.contentRange(row: 0, column: 1)!) == "x, y")
        #expect(ns.substring(with: table.contentRange(row: 1, column: 1)!) == "q\"\"t")
        #expect(ns.substring(with: table.rowRange(1)) == "7,\"q\"\"t\"")
        // The caret's field: a delimiter belongs to the field before it, the line break to its record.
        #expect(table.cell(at: 0)! == (0, 0))
        #expect(table.cell(at: 2)! == (0, 0))
        #expect(table.cell(at: 3)! == (0, 1))
        #expect(table.cell(at: 9)! == (0, 1))
        #expect(table.cell(at: 10)! == (1, 0))
        #expect(table.cell(at: ns.length)! == (1, 1))
        #expect(CSVTable("").cell(at: 0) == nil)
    }

    @Test func detectsTheDelimiter() {
        #expect(CSVTable("a;b;c\n1,5;2,5;3\n4;5;6").delimiter == .semicolon)
        #expect(CSVTable("a,b\n1;2,3\n4;5,6").delimiter == .comma)
        #expect(CSVTable("a\tb\n1\t2").delimiter == .tab)
        #expect(CSVTable("a|b|c\n1|2|3").delimiter == .pipe)
        // Delimiters inside quotes don't count.
        #expect(CSVTable("\"a;b\",c\n\"d;e\",f").delimiter == .comma)
        // One column: the preferred delimiter.
        #expect(CSVTable("one\ntwo", preferred: .tab).delimiter == .tab)
        #expect(CSVTable("a,b\n1,2", preferred: .tab).delimiter == .comma)
        #expect(CSVTable.detectDelimiter("x;y\n1;2") == .semicolon)
        // Asked for: used even when another one fits better.
        #expect(CSVTable("a;b\n1;2", delimiter: .comma).columnCount == 1)
    }

    @Test func header() {
        #expect(CSVTable("id,price\n1,2.5").firstRowLooksLikeHeader)
        #expect(!CSVTable("Bob,32\nAlice,40").firstRowLooksLikeHeader)
        #expect(!CSVTable(",\n1,2").firstRowLooksLikeHeader)
        #expect(!CSVTable("").firstRowLooksLikeHeader)
        // An empty corner is still a header.
        #expect(CSVTable(",Jan,Feb\nSales,1,2").firstRowLooksLikeHeader)
    }

    @Test func numbers() {
        #expect(CSVTable.number("42") == 42)
        #expect(CSVTable.number(" -3.5 ") == -3.5)
        #expect(CSVTable.number("1,25") == 1.25)
        #expect(CSVTable.number(".5") == 0.5)
        #expect(CSVTable.number("6.02e23") == 6.02e23)
        #expect(CSVTable.number("15%") == 15)
        #expect(CSVTable.number("+7") == 7)
        for text in ["", "-", ".", "1.2.3", "2024-01-05", "1e", "abc", "12px", "1,234,567"] {
            #expect(CSVTable.number(text) == nil, "\(text)")
        }
    }

    @Test func sorting() {
        let table = CSVTable("v\n10\nb\n2\n\nA\nfile10\nfile2\n-1")
        let rows = Array(1..<table.rowCount)
        let ascending = table.sorted(rows, byColumn: 0, ascending: true).map { table.value(row: $0, column: 0) }
        #expect(ascending == ["-1", "2", "10", "A", "b", "file2", "file10", ""])
        let descending = table.sorted(rows, byColumn: 0, ascending: false).map { table.value(row: $0, column: 0) }
        #expect(descending == ["file10", "file2", "b", "A", "10", "2", "-1", ""])
        // Accents and case don't count; leading zeros neither.
        let names = CSVTable("Émile\nzoe\nEmma\nadam\nitem 007\nitem 7b\nitem 10")
        #expect(names.sorted(Array(0..<names.rowCount), byColumn: 0, ascending: true).map { names.value(row: $0, column: 0) }
                == ["adam", "Émile", "Emma", "item 007", "item 7b", "item 10", "zoe"])
        // Equal values keep their order.
        let ties = CSVTable("a,1\nb,1\nc,0")
        #expect(ties.sorted([0, 1, 2], byColumn: 1, ascending: true) == [2, 0, 1])
        #expect(ties.sorted([0, 1, 2], byColumn: 1, ascending: false) == [0, 1, 2])
    }

    @Test func writing() {
        #expect(CSVTable.field("plain", delimiter: .comma) == "plain")
        #expect(CSVTable.field("a,b", delimiter: .comma) == "\"a,b\"")
        #expect(CSVTable.field("a,b", delimiter: .tab) == "a,b")
        #expect(CSVTable.field("say \"hi\"", delimiter: .tab) == "\"say \"\"hi\"\"\"")
        #expect(CSVTable.field("two\nlines", delimiter: .tab) == "\"two\nlines\"")
        #expect([0, 1, 25, 26, 27, 51, 52, 701, 702].map(CSVTable.columnName) == ["A", "B", "Z", "AA", "AB", "AZ", "BA", "ZZ", "AAA"])
    }

    @Test func engineColorsColumnsAtTheDelimiter() {
        let text = "a;b,c\n1;2,5" as NSString
        let engine = SyntaxEngine(language: .csv)
        func kinds(_ engine: SyntaxEngine) -> [TokenKind] {
            var kinds: [TokenKind] = []
            engine.enumerateTokens(lines: 0..<1, text: text) { _, kind in kinds.append(kind) }
            return kinds
        }
        engine.reset(text: text, language: .csv)
        #expect(kinds(engine) == [.rainbow1, .punctuation, .rainbow2])
        engine.setCSVDelimiter(Ch.semicolon, text: text)
        #expect(kinds(engine) == [.rainbow1, .punctuation, .rainbow2])
        #expect(engine.csvDelimiter == Ch.semicolon)
        // It holds through reloads and is only for CSV and TSV.
        engine.reset(text: text, language: .csv)
        var ranges: [NSRange] = []
        engine.enumerateTokens(lines: 0..<1, text: text) { range, _ in ranges.append(range) }
        #expect(ranges.first == NSRange(location: 0, length: 1))
        #expect(ranges.last == NSRange(location: 2, length: 3))
        engine.setLanguage(.json, text: text)
        #expect(!kinds(engine).contains(.rainbow2))
    }

    @Test func wideCharacters() {
        // Offsets are UTF-16, like the editor's.
        let text = "😀,é\nx,y"
        let table = CSVTable(text)
        #expect(table.value(row: 0, column: 0) == "😀")
        #expect(table.range(row: 0, column: 1) == NSRange(location: 3, length: 1))
        #expect(table.cell(at: 5)! == (1, 0))
    }
}
