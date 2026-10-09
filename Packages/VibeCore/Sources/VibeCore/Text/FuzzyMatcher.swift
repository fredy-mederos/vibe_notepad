import Foundation

/// Result of a fuzzy match: a score (higher is better) and the matched character offsets.
public struct FuzzyMatch: Sendable, Equatable {
    public let score: Int
    /// Offsets (in `Character`s) of the matched characters in the candidate.
    public let positions: [Int]
}

/// Sublime-style "Goto Anything" matching: query characters must appear in order; matches
/// at word starts, after separators, on camelCase humps and in runs score higher.
public enum FuzzyMatcher {
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return FuzzyMatch(score: 0, positions: []) }
        let original = Array(candidate)
        let haystack = original.map { Character($0.lowercased()) }
        guard needle.count <= haystack.count else { return nil }

        // Quick rejection.
        var k = 0
        for c in haystack where k < needle.count && c == needle[k] { k += 1 }
        guard k == needle.count else { return nil }

        var best: FuzzyMatch?
        var starts = 0
        for start in haystack.indices where haystack[start] == needle[0] {
            starts += 1
            if starts > 24 { break }
            if let m = greedy(needle, haystack, original, from: start), m.score > (best?.score ?? .min) {
                best = m
            }
        }
        return best
    }

    private static func greedy(_ needle: [Character], _ haystack: [Character], _ original: [Character], from start: Int) -> FuzzyMatch? {
        var positions: [Int] = [start]
        positions.reserveCapacity(needle.count)
        var i = start + 1
        for q in needle.dropFirst() {
            // Prefer the next occurrence at a word boundary if it's close; otherwise the nearest one.
            var nearest: Int?
            var boundary: Int?
            var j = i
            while j < haystack.count {
                if haystack[j] == q {
                    if nearest == nil { nearest = j }
                    if isBoundary(original, j) { boundary = j; break }
                    if let n = nearest, j - n > 12 { break }
                }
                j += 1
            }
            guard let n = nearest else { return nil }
            let chosen = (boundary != nil && n != i) ? boundary! : n
            positions.append(chosen)
            i = chosen + 1
        }
        return FuzzyMatch(score: score(positions, original), positions: positions)
    }

    private static func isBoundary(_ s: [Character], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let previous = s[i - 1]
        if previous == "/" || previous == "_" || previous == "-" || previous == "." || previous == " " { return true }
        return previous.isLowercase && s[i].isUppercase
    }

    private static func score(_ positions: [Int], _ s: [Character]) -> Int {
        var total = 0
        var previous = -2
        for p in positions {
            total += 16
            if p == 0 { total += 24 } else if isBoundary(s, p) { total += 18 }
            if p == previous + 1 { total += 14 } else if previous >= 0 { total -= min(10, p - previous - 1) }
            previous = p
        }
        // Prefer matches in the last path component and shorter candidates.
        if let slash = s.lastIndex(of: "/"), let first = positions.first, first > slash { total += 20 }
        total -= s.count / 6
        return total
    }
}
