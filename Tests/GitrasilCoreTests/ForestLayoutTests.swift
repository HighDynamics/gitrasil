import XCTest
@testable import GitrasilCore

final class ForestLayoutTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let screen = ForestScreen(size: CGSize(width: 1440, height: 900), groundY: 783, top: 44, margin: 40, nominalHeight: 1.45)

    /// `count` trees of varied crowns and ages, in groups of five folders.
    private func trees(_ count: Int) -> [ForestTree] {
        (0..<count).map { i in
            ForestTree(id: String(format: "tree%02d", i), group: "/work/group\(i % 5)", left: -0.2 - Double(i % 4) * 0.1,
                       right: 0.25 + Double(i % 3) * 0.15, height: 1.0 + Double(i % 5) * 0.1,
                       lastActive: now.addingTimeInterval(-Double((i * 7) % 40) * 86_400 * 3), activity: Double((i * 5) % 11))
        }
    }

    func testPlainAndOffPlaceNothing() {
        XCTAssertTrue(ForestLayout.plan(trees(8), mode: .plain, screen: screen).placements.isEmpty)
        XCTAssertTrue(ForestLayout.plan(trees(8), mode: .off, screen: screen).placements.isEmpty)
    }

    func testEveryModePlacesEveryTreeOnScreenOnce() {
        for mode in ForestMode.allCases where mode.isPacked {
            for count in [1, 4, 17, 64] {
                let plan = ForestLayout.plan(trees(count), mode: mode, screen: screen)
                XCTAssertEqual(plan.placements.map(\.index).sorted(), Array(0..<count), "\(mode) \(count)")
                for place in plan.placements {
                    XCTAssertGreaterThan(place.x, 0, "\(mode) \(count)")
                    XCTAssertLessThan(place.x, screen.size.width, "\(mode) \(count)")
                    XCTAssertLessThanOrEqual(place.ground, screen.groundY, "\(mode) \(count)")
                    // The crown stays under the top.
                    let height = CGFloat(trees(count)[place.index].height) * place.scale
                    XCTAssertGreaterThanOrEqual(place.ground - height, screen.top, "\(mode) \(count) tree \(place.index)")
                }
            }
        }
    }

    func testTheRowFitsTheScreen() {
        for mode in [ForestMode.canopy, .activity] {
            let plan = ForestLayout.plan(trees(40), mode: mode, screen: screen)
            let items = trees(40)
            for place in plan.placements {
                let (left, right) = ForestLayout.span(items[place.index])
                let factor = place.scale / plan.scale
                XCTAssertGreaterThanOrEqual(place.x - CGFloat(left) * plan.scale * factor, screen.margin - 8, "\(mode)")
                XCTAssertLessThanOrEqual(place.x + CGFloat(right) * plan.scale * factor, screen.size.width - screen.margin + 8, "\(mode)")
            }
        }
    }

    func testCanopyGivesRoomByCrownNotEqualPlots() {
        var slim = trees(6), wide = trees(6)
        for i in slim.indices { slim[i].left = -0.1; slim[i].right = 0.1; wide[i].left = -0.6; wide[i].right = 0.6 }
        let a = ForestLayout.plan(slim, mode: .canopy, screen: screen), b = ForestLayout.plan(wide, mode: .canopy, screen: screen)
        XCTAssertGreaterThan(a.scale, b.scale * 1.5, "narrow crowns stand bigger on the same ground")
    }

    func testActivitySizesBusyTreesBiggerThanQuietOnes() {
        var items = trees(6)
        for i in items.indices { items[i].left = -0.3; items[i].right = 0.3; items[i].activity = i == 0 ? 20 : 0 }
        let plan = ForestLayout.plan(items, mode: .activity, screen: screen)
        let busy = plan.placements.first { $0.index == 0 }!, quiet = plan.placements.first { $0.index == 1 }!
        XCTAssertGreaterThan(busy.scale, quiet.scale * 2)
        XCTAssertEqual(ForestLayout.sizeFactor(activity: 20), 1)
        XCTAssertLessThan(ForestLayout.sizeFactor(activity: 0), ForestLayout.sizeFactor(activity: 1))
    }

    func testRowsPutTheMostRecentlyActiveInFrontAndFadeTheRest() {
        let items = trees(40)
        let plan = ForestLayout.plan(items, mode: .rows, screen: screen)
        XCTAssertGreaterThan(plan.lines, 1)
        let front = plan.placements.filter { $0.line == 0 }, back = plan.placements.filter { $0.line > 0 }
        let newestFront = front.map { items[$0.index].lastActive }.min()!
        let newestBack = back.map { items[$0.index].lastActive }.max()!
        XCTAssertGreaterThanOrEqual(Int(newestFront.timeIntervalSince1970 / 86_400), Int(newestBack.timeIntervalSince1970 / 86_400))
        XCTAssertEqual(front.map(\.fade).max(), 0)
        for place in back {
            XCTAssertGreaterThan(place.fade, 0)
            XCTAssertLessThan(place.ground, screen.groundY)
            XCTAssertLessThan(place.scale, plan.scale)
        }
        XCTAssertEqual(plan.grounds.count, plan.lines - 1)
    }

    func testRowsUseOneLineWhileTheyFitComfortably() {
        XCTAssertEqual(ForestLayout.plan(trees(3), mode: .rows, screen: screen).lines, 1)
        XCTAssertGreaterThan(ForestLayout.plan(trees(60), mode: .rows, screen: screen).lines, 2)
    }

    func testGrovesClusterByFolder() {
        let items = trees(30)
        let plan = ForestLayout.plan(items, mode: .groves, screen: screen)
        XCTAssertEqual(plan.groves.count, 5)
        XCTAssertEqual(plan.groves.map(\.count).reduce(0, +), 30)
        // Each tree stands inside its own folder's stretch, and the stretches don't overlap.
        for place in plan.placements {
            let grove = plan.groves.first { $0.name == items[place.index].group }!
            XCTAssertGreaterThanOrEqual(place.x, grove.from - 40)
            XCTAssertLessThanOrEqual(place.x, grove.to + 40)
        }
        for (a, b) in zip(plan.groves, plan.groves.dropFirst()) { XCTAssertLessThan(a.to, b.from) }
    }

    func testPlacementsAreDeterministic() {
        for mode in ForestMode.allCases where mode.isPacked {
            XCTAssertEqual(ForestLayout.plan(trees(33), mode: mode, screen: screen), ForestLayout.plan(trees(33), mode: mode, screen: screen))
        }
    }

    /// How much moves when one repository commits: the row's most recent commit lands in a quiet one.
    func testACommitMovesFewTreesInTheFixedLayouts() {
        var items = trees(32)
        for mode in [ForestMode.canopy, .groves] {
            let before = ForestLayout.plan(items, mode: mode, screen: screen)
            items[7].lastActive = now
            let after = ForestLayout.plan(items, mode: mode, screen: screen)
            let moved = zip(before.placements, after.placements).filter { abs($0.x - $1.x) > 1 || $0.line != $1.line }.count
            // Recency only orders the groves' lines, so a commit may reseat its own folder's trees but never another's.
            XCTAssertLessThanOrEqual(moved, mode == .canopy ? 0 : items.filter { $0.group == items[7].group }.count, "\(mode)")
        }
    }

    /// Rows rank by the day of the last commit, so a commit in a back-row repo re-packs every line it
    /// passes through, and the lines it doesn't touch drift a few points because the scale is shared
    /// (the known cost of ranking: docs/forest/PLAN.md). No other tree changes line.
    func testACommitInRowsRepacksOnlyTheLinesItCrosses() {
        var items = trees(40)
        let before = ForestLayout.plan(items, mode: .rows, screen: screen)
        items[7].lastActive = now
        let after = ForestLayout.plan(items, mode: .rows, screen: screen)
        XCTAssertEqual(before.lines, after.lines)
        let from = before.placements.first { $0.index == 7 }!.line, to = after.placements.first { $0.index == 7 }!.line
        XCTAssertLessThan(to, from, "a commit today brings the repo forward")
        for (old, new) in zip(before.placements, after.placements) where !(to...from).contains(old.line) {
            XCTAssertEqual(old.line, new.line)
            XCTAssertEqual(old.x, new.x, accuracy: 40)
        }
    }

    func testPennantAllowanceShrinksWithTheTree() {
        XCTAssertNil(ForestLayout.pennantAllowance(scale: 400, fade: 0))
        XCTAssertEqual(ForestLayout.pennantAllowance(scale: 160, fade: 0), 3)
        XCTAssertEqual(ForestLayout.pennantAllowance(scale: 90, fade: 0), 0)
        XCTAssertEqual(ForestLayout.pennantAllowance(scale: 400, fade: 0.5), 0)
    }

    func testActivityCountsFreshCommitsMost() {
        let fresh = RepoTree.Commit(sha: "a", date: now), old = RepoTree.Commit(sha: "b", date: now.addingTimeInterval(-90 * 86_400))
        let busy = RepoTree(trunkName: "main", trunk: [fresh, fresh, fresh], limbs: [], isTrunkCheckedOut: false)
        let quiet = RepoTree(trunkName: "main", trunk: [old, old, old], limbs: [], isTrunkCheckedOut: false)
        XCTAssertGreaterThan(busy.activity(now: now), 2.9)
        XCTAssertLessThan(quiet.activity(now: now), 0.1)
        XCTAssertEqual(busy.lastActive, now)
    }
}
