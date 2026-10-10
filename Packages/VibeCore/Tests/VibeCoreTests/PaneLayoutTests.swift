import Foundation
import Testing
@testable import VibeCore

@Suite struct PaneLayoutTests {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func splittingAddsAPaneNextToTheSplitOne() {
        let one = PaneLayout.pane(a)
        let two = one.splitting(a, axis: .horizontal, newPane: b)
        #expect(two.paneIDs == [a, b])
        guard case .split(_, let axis, let ratio, _, _) = two else { Issue.record("not a split"); return }
        #expect(axis == .horizontal)
        #expect(ratio == 0.5)
        // Splitting the left pane again puts the new one below it, before the right pane.
        let three = two.splitting(a, axis: .vertical, newPane: c)
        #expect(three.paneIDs == [a, c, b])
        #expect(three.paneCount == 3)
        // Before: the new pane goes on the left (or on top).
        #expect(one.splitting(a, axis: .horizontal, newPane: b, before: true).paneIDs == [b, a])
        // A pane that isn't there leaves the layout alone.
        #expect(one.splitting(d, axis: .horizontal, newPane: b) == one)
    }

    @Test func removingAPaneGivesItsSpaceToItsSibling() {
        let layout = PaneLayout.pane(a).splitting(a, axis: .horizontal, newPane: b).splitting(b, axis: .vertical, newPane: c)
        #expect(layout.paneIDs == [a, b, c])
        #expect(layout.sibling(of: c) == b)
        #expect(layout.sibling(of: a) == b)
        let withoutB = layout.removing(b)
        #expect(withoutB?.paneIDs == [a, c])
        #expect(layout.removing(a)?.paneIDs == [b, c])
        #expect(PaneLayout.pane(a).removing(a) == nil)
        #expect(PaneLayout.pane(a).sibling(of: a) == nil)
        // Removing everything but one pane leaves just that pane.
        #expect(withoutB?.removing(a) == .pane(c))
    }

    @Test func framesDivideTheArea() throws {
        let layout = PaneLayout.preset(.mainAndTwo, panes: [a, b, c])
        let frames = layout.frames()
        #expect(frames[a] == PaneRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(frames[b] == PaneRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(frames[c] == PaneRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        let id = try #require(splitID(of: layout))
        #expect(layout.settingRatio(0.25, of: id).frames()[a]?.width == 0.25)
    }

    @Test func ratiosStayWithinLimits() throws {
        let layout = PaneLayout.pane(a).splitting(a, axis: .horizontal, newPane: b)
        let id = try #require(splitID(of: layout))
        #expect(ratio(of: layout.settingRatio(0, of: id)) == PaneLayout.minimumRatio)
        #expect(ratio(of: layout.settingRatio(2, of: id)) == PaneLayout.maximumRatio)
        #expect(ratio(of: layout.settingRatio(0.3, of: UUID())) == 0.5)
    }

    @Test func equalRatioGivesEveryPaneTheSameRoom() throws {
        let three = PaneLayout.preset(.threeColumns, panes: [a, b, c])
        let outer = try #require(splitID(of: three))
        #expect(three.equalRatio(of: outer) == 1.0 / 3)
        // A column holding two stacked panes counts as one column.
        let main = PaneLayout.preset(.mainAndTwo, panes: [a, b, c])
        #expect(main.equalRatio(of: try #require(splitID(of: main))) == 0.5)
        #expect(PaneLayout.pane(a).equalRatio(of: outer) == nil)
    }

    @Test func neighborsFollowTheGeometry() {
        // a | b
        // --+--
        // c | d
        let grid = PaneLayout.preset(.grid, panes: [a, b, c, d])
        #expect(Set(grid.paneIDs) == [a, b, c, d])
        #expect(grid.neighbor(of: a, toward: .right) == b)
        #expect(grid.neighbor(of: a, toward: .down) == c)
        #expect(grid.neighbor(of: d, toward: .left) == c)
        #expect(grid.neighbor(of: d, toward: .up) == b)
        #expect(grid.neighbor(of: a, toward: .left) == nil)
        #expect(grid.neighbor(of: a, toward: .up) == nil)

        // a | b
        //   +--
        //   | c
        let main = PaneLayout.preset(.mainAndTwo, panes: [a, b, c])
        #expect(main.neighbor(of: c, toward: .left) == a)
        #expect(main.neighbor(of: b, toward: .down) == c)
        // Two equally good panes: the top one.
        #expect(main.neighbor(of: a, toward: .right) == b)
        #expect(main.neighbor(of: c, toward: .right) == nil)
    }

    @Test func presetsHaveTheirPanes() {
        for preset in PaneLayout.Preset.allCases {
            let ids = (0..<preset.paneCount).map { _ in UUID() }
            let layout = PaneLayout.preset(preset, panes: ids)
            #expect(layout.paneCount == preset.paneCount)
            #expect(Set(layout.paneIDs) == Set(ids))
            let area = layout.frames().values.reduce(0) { $0 + $1.width * $1.height }
            #expect(abs(area - 1) < 1e-9)
        }
        #expect(PaneLayout.preset(.threeColumns, panes: [a, b, c]).frames()[b]?.x == 1.0 / 3)
    }

    @Test func roundTripsThroughJSON() throws {
        let layout = PaneLayout.preset(.grid, panes: [a, b, c, d])
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(PaneLayout.self, from: data) == layout)
    }

    private func splitID(of layout: PaneLayout) -> UUID? {
        if case .split(let id, _, _, _, _) = layout { return id }
        return nil
    }

    private func ratio(of layout: PaneLayout) -> Double? {
        if case .split(_, _, let ratio, _, _) = layout { return ratio }
        return nil
    }
}
