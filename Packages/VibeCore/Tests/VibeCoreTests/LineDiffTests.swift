import Foundation
import Testing
@testable import VibeCore

@Suite struct LineDiffTests {
    private func diff(_ old: [String], _ new: [String], maxEdits: Int = 1_000) -> [LineChange] {
        LineDiff.changes(from: old.joined(separator: "\n"), to: new.joined(separator: "\n"), maxEdits: maxEdits)
    }

    @Test func identicalTextHasNoChanges() {
        #expect(diff(["a", "b", "c"], ["a", "b", "c"]).isEmpty)
        #expect(LineDiff.changes(from: "", to: "").isEmpty)
    }

    @Test func classifiesAddedModifiedAndDeletedLines() {
        #expect(diff(["a", "b", "c"], ["a", "B", "c"]) == [LineChange(kind: .modified, lines: 1..<2)])
        #expect(diff(["a", "c"], ["a", "b1", "b2", "c"]) == [LineChange(kind: .added, lines: 1..<3)])
        #expect(diff(["a", "b", "c", "d"], ["a", "d"]) == [LineChange(kind: .deleted, lines: 1..<1)])
        // Two removed lines replaced by three: one modified block.
        #expect(diff(["a", "x", "y", "d"], ["a", "1", "2", "3", "d"]) == [LineChange(kind: .modified, lines: 1..<4)])
    }

    @Test func handlesBothEnds() {
        #expect(diff(["a", "b"], ["new", "a", "b"]) == [LineChange(kind: .added, lines: 0..<1)])
        #expect(diff(["a", "b", "c"], ["a", "b"]) == [LineChange(kind: .deleted, lines: 2..<2)])
        #expect(diff(["a", "b"], ["a", "b", "c"]) == [LineChange(kind: .added, lines: 2..<3)])
        #expect(diff(["gone"], ["a", "b"]) == [LineChange(kind: .modified, lines: 0..<2)])
        // A trailing newline adds an empty last line.
        #expect(LineDiff.changes(from: "a\nb", to: "a\nb\n") == [LineChange(kind: .added, lines: 2..<3)])
    }

    @Test func findsSeparateHunksInOrder() {
        let old = (0..<20).map { "line \($0)" }
        var new = old
        new[2] = "changed"
        new.insert("inserted", at: 10)
        new.remove(at: 16) // old line 15
        #expect(diff(old, new) == [
            LineChange(kind: .modified, lines: 2..<3),
            LineChange(kind: .added, lines: 10..<11),
            LineChange(kind: .deleted, lines: 16..<16),
        ])
    }

    @Test func mergesEverythingPastTheEditLimit() {
        let old = (0..<50).map { "old \($0)" }
        var new = old
        for index in stride(from: 5, to: 45, by: 2) { new[index] = "new \(index)" }
        let changes = diff(old, new, maxEdits: 10)
        #expect(changes == [LineChange(kind: .modified, lines: 5..<44)])
        #expect(diff(old, new).count == 20)
    }

    @Test func looksUpChangesByLine() {
        let changes = [
            LineChange(kind: .modified, lines: 2..<4),
            LineChange(kind: .deleted, lines: 6..<6),
            LineChange(kind: .added, lines: 9..<10),
        ]
        #expect(changes.change(coveringLine: 1) == nil)
        #expect(changes.change(coveringLine: 2)?.kind == .modified)
        #expect(changes.change(coveringLine: 3)?.kind == .modified)
        #expect(changes.change(coveringLine: 4) == nil)
        #expect(changes.change(coveringLine: 6) == nil)
        #expect(changes.change(coveringLine: 9)?.kind == .added)
        #expect(changes.hasDeletion(beforeLine: 6))
        #expect(!changes.hasDeletion(beforeLine: 5))
        #expect(!changes.hasDeletion(beforeLine: 9))
    }

    @Test func staysFastOnLargeFiles() {
        let old = (0..<200_000).map { "let value\($0) = \($0 * 7)" }
        var new = old
        new[10] = "edited near the top"
        new[199_000] = "edited near the bottom"
        let start = Date()
        let changes = diff(old, new)
        #expect(changes == [LineChange(kind: .modified, lines: 10..<11), LineChange(kind: .modified, lines: 199_000..<199_001)])
        #expect(Date().timeIntervalSince(start) < 1.5)
        // A complete rewrite gives up quickly instead of searching every path.
        let rewrite = (0..<200_000).map { "something else \($0)" }
        let rewriteStart = Date()
        #expect(diff(old, rewrite) == [LineChange(kind: .modified, lines: 0..<200_000)])
        #expect(Date().timeIntervalSince(rewriteStart) < 3)
    }
}
