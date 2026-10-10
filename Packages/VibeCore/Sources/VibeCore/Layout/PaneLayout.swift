import Foundation

/// How a split arranges its two parts.
public enum SplitAxis: String, Codable, Sendable {
    /// Side by side: the first part on the left.
    case horizontal
    /// Stacked: the first part on top.
    case vertical
}

/// A direction to move between panes.
public enum PaneDirection: Sendable, CaseIterable {
    case left, right, up, down
}

/// A pane's place in the editor area, as fractions of it (origin at the top left).
public struct PaneRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// How the editor area is divided: a single pane, or a split in two parts that can each be split
/// again. Panes are identified by UUIDs; what each one shows is up to the app.
public indirect enum PaneLayout: Codable, Equatable, Sendable {
    case pane(UUID)
    /// `ratio` is the first part's share of the space (between `minimumRatio` and `maximumRatio`).
    case split(id: UUID, axis: SplitAxis, ratio: Double, first: PaneLayout, second: PaneLayout)

    public static let minimumRatio = 0.1
    public static let maximumRatio = 0.9

    /// Common arrangements, in the order the View menu lists them.
    public enum Preset: String, CaseIterable, Sendable {
        case single, twoColumns, twoRows, threeColumns, mainAndTwo, grid

        public var title: String {
            switch self {
            case .single: "Single"
            case .twoColumns: "Two Columns"
            case .twoRows: "Two Rows"
            case .threeColumns: "Three Columns"
            case .mainAndTwo: "One Left, Two Right"
            case .grid: "Grid (2 × 2)"
            }
        }

        public var paneCount: Int {
            switch self {
            case .single: 1
            case .twoColumns, .twoRows: 2
            case .threeColumns, .mainAndTwo: 3
            case .grid: 4
            }
        }
    }

    // MARK: Reading

    /// Every pane, left to right and top to bottom (the order of the tree).
    public var paneIDs: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, _, let first, let second): first.paneIDs + second.paneIDs
        }
    }

    public var paneCount: Int { paneIDs.count }

    public func contains(_ pane: UUID) -> Bool { paneIDs.contains(pane) }

    /// The first pane in this part of the layout.
    public var firstPane: UUID {
        switch self {
        case .pane(let id): id
        case .split(_, _, _, let first, _): first.firstPane
        }
    }

    /// Each pane's place, as fractions of `rect` (the whole area by default).
    public func frames(in rect: PaneRect = PaneRect(x: 0, y: 0, width: 1, height: 1)) -> [UUID: PaneRect] {
        switch self {
        case .pane(let id):
            return [id: rect]
        case .split(_, let axis, let ratio, let first, let second):
            var a = rect, b = rect
            if axis == .horizontal {
                a.width = rect.width * ratio
                b.x = rect.x + a.width
                b.width = rect.width - a.width
            } else {
                a.height = rect.height * ratio
                b.y = rect.y + a.height
                b.height = rect.height - a.height
            }
            return first.frames(in: a).merging(second.frames(in: b)) { a, _ in a }
        }
    }

    /// The pane next to `pane` in `direction`: of the panes beyond its edge, the closest one that
    /// overlaps it the most (the top or left one of equals). Nil at the edge of the area.
    public func neighbor(of pane: UUID, toward direction: PaneDirection) -> UUID? {
        let frames = frames()
        guard let current = frames[pane] else { return nil }
        let epsilon = 1e-6
        var best: (id: UUID, gap: Double, overlap: Double, position: Double)?
        for (id, frame) in frames where id != pane {
            let gap: Double
            let overlap: Double
            let horizontal = direction == .left || direction == .right
            switch direction {
            case .left: gap = current.x - frame.maxX
            case .right: gap = frame.x - current.maxX
            case .up: gap = current.y - frame.maxY
            case .down: gap = frame.y - current.maxY
            }
            if horizontal {
                overlap = min(current.maxY, frame.maxY) - max(current.y, frame.y)
            } else {
                overlap = min(current.maxX, frame.maxX) - max(current.x, frame.x)
            }
            guard gap > -epsilon, overlap > epsilon else { continue }
            let position = horizontal ? frame.y : frame.x
            if let best {
                if best.gap < gap - epsilon { continue }
                if abs(best.gap - gap) <= epsilon {
                    if best.overlap > overlap + epsilon { continue }
                    if abs(best.overlap - overlap) <= epsilon, best.position <= position { continue }
                }
            }
            best = (id, gap, overlap, position)
        }
        return best?.id
    }

    /// The pane that takes `pane`'s space when it's removed: the first pane of its sibling.
    public func sibling(of pane: UUID) -> UUID? {
        guard case .split(_, _, _, let first, let second) = self else { return nil }
        if case .pane(let id) = first, id == pane { return second.firstPane }
        if case .pane(let id) = second, id == pane { return first.firstPane }
        return first.sibling(of: pane) ?? second.sibling(of: pane)
    }

    // MARK: Changing

    /// Splits `pane` in two along `axis`; `newPane` goes after it (right or below), or before it.
    public func splitting(_ pane: UUID, axis: SplitAxis, newPane: UUID, before: Bool = false, splitID: UUID = UUID()) -> PaneLayout {
        switch self {
        case .pane(let id):
            guard id == pane else { return self }
            let new = PaneLayout.pane(newPane)
            return .split(id: splitID, axis: axis, ratio: 0.5, first: before ? new : self, second: before ? self : new)
        case .split(let id, let splitAxis, let ratio, let first, let second):
            return .split(id: id, axis: splitAxis, ratio: ratio,
                          first: first.splitting(pane, axis: axis, newPane: newPane, before: before, splitID: splitID),
                          second: second.splitting(pane, axis: axis, newPane: newPane, before: before, splitID: splitID))
        }
    }

    /// The layout without `pane` (its sibling takes the space); nil when it's the only pane.
    public func removing(_ pane: UUID) -> PaneLayout? {
        switch self {
        case .pane(let id):
            return id == pane ? nil : self
        case .split(let id, let axis, let ratio, let first, let second):
            guard let first = first.removing(pane) else { return second }
            guard let second = second.removing(pane) else { return first }
            return .split(id: id, axis: axis, ratio: ratio, first: first, second: second)
        }
    }

    /// Sets the share of the split `split` gives its first part.
    public func settingRatio(_ ratio: Double, of split: UUID) -> PaneLayout {
        guard case .split(let id, let axis, let current, let first, let second) = self else { return self }
        let clamped = min(Self.maximumRatio, max(Self.minimumRatio, ratio))
        return .split(id: id, axis: axis, ratio: id == split ? clamped : current,
                      first: first.settingRatio(ratio, of: split), second: second.settingRatio(ratio, of: split))
    }

    /// The share that gives every pane along the split's axis the same room (one third for a pane
    /// next to two others).
    public func equalRatio(of split: UUID) -> Double? {
        switch self {
        case .pane:
            return nil
        case .split(let id, let axis, _, let first, let second):
            if id == split {
                let a = Double(first.span(along: axis)), b = Double(second.span(along: axis))
                return a / (a + b)
            }
            return first.equalRatio(of: split) ?? second.equalRatio(of: split)
        }
    }

    /// How many panes sit side by side along `axis`.
    private func span(along axis: SplitAxis) -> Int {
        switch self {
        case .pane:
            return 1
        case .split(_, let splitAxis, _, let first, let second):
            let a = first.span(along: axis), b = second.span(along: axis)
            return splitAxis == axis ? a + b : max(a, b)
        }
    }

    /// The arrangement `preset` with the panes `ids` (in reading order; as many as the preset has).
    public static func preset(_ preset: Preset, panes ids: [UUID]) -> PaneLayout {
        precondition(ids.count >= preset.paneCount, "\(preset) needs \(preset.paneCount) panes")
        let p = ids.map(PaneLayout.pane)
        switch preset {
        case .single:
            return p[0]
        case .twoColumns:
            return .split(id: UUID(), axis: .horizontal, ratio: 0.5, first: p[0], second: p[1])
        case .twoRows:
            return .split(id: UUID(), axis: .vertical, ratio: 0.5, first: p[0], second: p[1])
        case .threeColumns:
            return .split(id: UUID(), axis: .horizontal, ratio: 1.0 / 3, first: p[0],
                          second: .split(id: UUID(), axis: .horizontal, ratio: 0.5, first: p[1], second: p[2]))
        case .mainAndTwo:
            return .split(id: UUID(), axis: .horizontal, ratio: 0.5, first: p[0],
                          second: .split(id: UUID(), axis: .vertical, ratio: 0.5, first: p[1], second: p[2]))
        case .grid:
            return .split(id: UUID(), axis: .horizontal, ratio: 0.5,
                          first: .split(id: UUID(), axis: .vertical, ratio: 0.5, first: p[0], second: p[2]),
                          second: .split(id: UUID(), axis: .vertical, ratio: 0.5, first: p[1], second: p[3]))
        }
    }
}
