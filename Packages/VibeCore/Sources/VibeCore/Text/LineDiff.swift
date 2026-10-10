import Foundation

/// A region where the buffer differs from an earlier version of the file (what git has), in
/// buffer lines. Drives the change markers next to the line numbers.
public struct LineChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// New lines.
        case added
        /// Lines that replace earlier ones.
        case modified
        /// Lines were removed just before `lines.lowerBound` (`lines` is empty).
        case deleted
    }

    public var kind: Kind
    /// 0-based buffer lines; empty for `.deleted`.
    public var lines: Range<Int>

    public init(kind: Kind, lines: Range<Int>) {
        self.kind = kind
        self.lines = lines
    }
}

/// Line-by-line diff (Myers' algorithm) between an earlier version of a file and the buffer.
public enum LineDiff {
    /// The changes that turn `old` into `new`, both split on `\n`. When more than `maxEdits` lines
    /// would have to be added or removed, everything from the first to the last difference is
    /// reported as one modified block, which keeps huge rewrites cheap.
    public static func changes(from old: String, to new: String, maxEdits: Int = 1_000) -> [LineChange] {
        changes(from: lineHashes(old), to: lineHashes(new), maxEdits: maxEdits)
    }

    /// Same as `changes(from:to:)`, with lines already reduced to hashes (see `lineHashes`).
    public static func changes(from a: [UInt64], to b: [UInt64], maxEdits: Int = 1_000) -> [LineChange] {
        // Most edits touch a small part of the file: skip what's equal at both ends.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let old = Array(a[prefix..<(a.count - suffix)])
        let new = Array(b[prefix..<(b.count - suffix)])
        if old.isEmpty, new.isEmpty { return [] }
        guard let hunks = hunks(old, new, maxEdits: maxEdits) else {
            return [change(oldCount: old.count, newStart: prefix, newCount: new.count)]
        }
        return hunks.map { change(oldCount: $0.oldCount, newStart: prefix + $0.newStart, newCount: $0.newCount) }
    }

    /// One hash per line (FNV-1a over its UTF-8 bytes), splitting on `\n` like the editor does:
    /// "a\nb\n" has three lines, the last one empty.
    public static func lineHashes(_ text: String) -> [UInt64] {
        var text = text
        text.makeContiguousUTF8()
        let basis: UInt64 = 0xcbf2_9ce4_8422_2325
        var hashes: [UInt64] = []
        var hash = basis
        let hashed: Void? = text.utf8.withContiguousStorageIfAvailable { bytes in
            for byte in bytes {
                if byte == 0x0A {
                    hashes.append(hash)
                    hash = basis
                } else {
                    hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
                }
            }
        }
        if hashed == nil {
            for byte in text.utf8 {
                if byte == 0x0A {
                    hashes.append(hash)
                    hash = basis
                } else {
                    hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
                }
            }
        }
        hashes.append(hash)
        return hashes
    }

    private static func change(oldCount: Int, newStart: Int, newCount: Int) -> LineChange {
        if oldCount == 0 { return LineChange(kind: .added, lines: newStart..<(newStart + newCount)) }
        if newCount == 0 { return LineChange(kind: .deleted, lines: newStart..<newStart) }
        return LineChange(kind: .modified, lines: newStart..<(newStart + newCount))
    }

    private struct Hunk {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
    }

    /// Myers' O(ND) diff, grouped into runs of removed/added lines. Nil past `maxEdits`.
    private static func hunks(_ a: [UInt64], _ b: [UInt64], maxEdits: Int) -> [Hunk]? {
        let n = a.count, m = b.count
        let limit = min(n + m, max(0, maxEdits))
        let offset = limit + 1
        // v[offset + k]: the furthest x reached on diagonal k.
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        // trace[d]: v for diagonals -d-1...d+1 as it was before step d, for walking back.
        var trace: [[Int32]] = []
        var steps: Int?
        search: for d in 0...limit {
            trace.append(v[(offset - d - 1)...(offset + d + 1)].map { Int32($0) })
            for k in stride(from: -d, through: d, by: 2) {
                var x = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n, y >= m {
                    steps = d
                    break search
                }
            }
        }
        guard let steps else { return nil }

        // Walk back from the end, collecting each step's insertion or deletion.
        var edits: [(x: Int, y: Int, inserts: Bool)] = []
        edits.reserveCapacity(steps)
        var x = n, y = m
        for d in stride(from: steps, through: 1, by: -1) {
            let band = trace[d]
            func at(_ k: Int) -> Int { Int(band[k + d + 1]) }
            let k = x - y
            let previousK = k == -d || (k != d && at(k - 1) < at(k + 1)) ? k + 1 : k - 1
            let previousX = at(previousK)
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                x -= 1
                y -= 1
            }
            edits.append((previousX, previousY, x == previousX))
            x = previousX
            y = previousY
        }

        var hunks: [Hunk] = []
        for edit in edits.reversed() {
            if let last = hunks.last, last.oldStart + last.oldCount == edit.x, last.newStart + last.newCount == edit.y {
                if edit.inserts { hunks[hunks.count - 1].newCount += 1 } else { hunks[hunks.count - 1].oldCount += 1 }
            } else {
                hunks.append(Hunk(oldStart: edit.x, oldCount: edit.inserts ? 0 : 1, newStart: edit.y, newCount: edit.inserts ? 1 : 0))
            }
        }
        return hunks
    }
}

extension Array where Element == LineChange {
    /// The added or modified change that includes `line`. Changes start on increasing lines, as
    /// `LineDiff` returns them.
    public func change(coveringLine line: Int) -> LineChange? {
        // The last change starting at or before `line` is the only candidate.
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid].lines.lowerBound <= line { low = mid + 1 } else { high = mid }
        }
        guard low > 0, self[low - 1].lines.contains(line) else { return nil }
        return self[low - 1]
    }

    /// Whether lines were removed just before `line`.
    public func hasDeletion(beforeLine line: Int) -> Bool {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid].lines.lowerBound < line { low = mid + 1 } else { high = mid }
        }
        return low < count && self[low].kind == .deleted && self[low].lines.lowerBound == line
    }
}
