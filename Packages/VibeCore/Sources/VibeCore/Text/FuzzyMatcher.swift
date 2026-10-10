import Foundation

/// Result of a fuzzy match: a score (higher is better) and the matched character offsets.
public struct FuzzyMatch: Sendable, Equatable {
    public let score: Int
    /// Offsets (in `Character`s) of the matched characters in the candidate.
    public let positions: [Int]
}

/// Sublime-style "Goto Anything" matching: query characters must appear in order; matches
/// at word starts, after separators, on camelCase humps and in runs score higher.
///
/// Matching works on UTF-16 code units (fast enough to rank a whole project on every
/// keystroke); positions are converted back to `Character` offsets for highlighting.
public enum FuzzyMatcher {
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        var needle: [UInt16] = []
        for unit in query.utf16 where !isWhitespace(unit) { needle.append(lower(unit)) }
        guard !needle.isEmpty else { return FuzzyMatch(score: 0, positions: []) }

        // Quick rejection before allocating anything.
        var k = 0
        for unit in candidate.utf16 where lower(unit) == needle[k] {
            k += 1
            if k == needle.count { break }
        }
        guard k == needle.count else { return nil }

        let original = Array(candidate.utf16)
        var haystack: [UInt16] = []
        haystack.reserveCapacity(original.count)
        // One code unit per Character (plain ASCII without "\r\n"): offsets need no conversion.
        var oneUnitPerCharacter = true
        for unit in original {
            if unit >= 0x80 || unit == 0x0D { oneUnitPerCharacter = false }
            haystack.append(lower(unit))
        }

        // latest[k]: the last position where needle[k...] can still start (so choices stay feasible).
        var latest = [Int](repeating: -1, count: needle.count)
        var position = haystack.count - 1
        for k in stride(from: needle.count - 1, through: 0, by: -1) {
            while position >= 0, haystack[position] != needle[k] { position -= 1 }
            guard position >= 0 else { return nil }
            latest[k] = position
            position -= 1
        }

        var best: (score: Int, positions: [Int])?
        var starts = 0
        for start in haystack.indices where haystack[start] == needle[0] {
            if start > latest[0] { break }
            starts += 1
            if starts > 24 { break }
            if let m = greedy(needle, haystack, original, from: start, latest: latest), m.score > (best?.score ?? .min) {
                best = m
            }
        }
        guard let best else { return nil }
        let positions = oneUnitPerCharacter ? best.positions : characterOffsets(best.positions, in: candidate, unitCount: original.count)
        return FuzzyMatch(score: best.score, positions: positions)
    }

    private static func greedy(_ needle: [UInt16], _ haystack: [UInt16], _ original: [UInt16], from start: Int, latest: [Int]) -> (score: Int, positions: [Int])? {
        var positions: [Int] = [start]
        positions.reserveCapacity(needle.count)
        var i = start + 1
        for (offset, q) in needle.dropFirst().enumerated() {
            let limit = latest[offset + 1]
            // Prefer the next occurrence at a word boundary if it's close; otherwise the nearest one.
            var nearest: Int?
            var boundary: Int?
            var j = i
            while j < haystack.count, j <= limit {
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
        return (score(positions, original), positions)
    }

    private static func isBoundary(_ s: [UInt16], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let previous = s[i - 1]
        // "/", "_", "-", ".", " "
        if previous == 0x2F || previous == 0x5F || previous == 0x2D || previous == 0x2E || previous == 0x20 { return true }
        return isLowercase(previous) && isUppercase(s[i])
    }

    private static func score(_ positions: [Int], _ s: [UInt16]) -> Int {
        var total = 0
        var previous = -2
        for p in positions {
            total += 16
            if p == 0 { total += 24 } else if isBoundary(s, p) { total += 18 }
            if p == previous + 1 { total += 14 } else if previous >= 0 { total -= min(10, p - previous - 1) }
            previous = p
        }
        // Prefer matches in the last path component and shorter candidates.
        if let slash = s.lastIndex(of: 0x2F), let first = positions.first, first > slash { total += 20 }
        total -= s.count / 6
        return total
    }

    // MARK: UTF-16 helpers

    @inline(__always)
    private static func lower(_ unit: UInt16) -> UInt16 {
        if unit < 0x80 { return unit >= 0x41 && unit <= 0x5A ? unit + 32 : unit }
        guard let scalar = Unicode.Scalar(unit) else { return unit } // surrogate halves have no case
        let lowered = scalar.properties.lowercaseMapping.utf16
        return lowered.count == 1 ? lowered.first! : unit
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        if unit < 0x80 { return unit == 0x20 || (unit >= 0x09 && unit <= 0x0D) }
        return Unicode.Scalar(unit)?.properties.isWhitespace ?? false
    }

    private static func isLowercase(_ unit: UInt16) -> Bool {
        if unit < 0x80 { return unit >= 0x61 && unit <= 0x7A }
        return Unicode.Scalar(unit)?.properties.isLowercase ?? false
    }

    private static func isUppercase(_ unit: UInt16) -> Bool {
        if unit < 0x80 { return unit >= 0x41 && unit <= 0x5A }
        return Unicode.Scalar(unit)?.properties.isUppercase ?? false
    }

    /// Converts UTF-16 offsets to `Character` offsets (they differ once a character takes
    /// several code units: emoji, combining accents…).
    private static func characterOffsets(_ positions: [Int], in candidate: String, unitCount: Int) -> [Int] {
        var characterAt = [Int](repeating: 0, count: unitCount)
        var unit = 0
        for (index, character) in candidate.enumerated() {
            for _ in 0..<character.utf16.count where unit < unitCount {
                characterAt[unit] = index
                unit += 1
            }
        }
        var result: [Int] = []
        for position in positions where result.last != characterAt[position] {
            result.append(characterAt[position])
        }
        return result
    }
}
