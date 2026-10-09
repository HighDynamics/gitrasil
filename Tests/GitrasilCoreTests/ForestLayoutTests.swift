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
                       lastActive: now.addingTimeInterval(-Double((i * 7) % 40) * 86_400 * 3))
        }
    }

    func testEveryTreeStandsOnScreenOnceUnderTheTop() {
        for count in [1, 4, 17, 64] {
            let plan = ForestLayout.rows(trees(count), screen: screen)
            XCTAssertEqual(plan.placements.map(\.index).sorted(), Array(0..<count), "\(count)")
            for place in plan.placements {
                XCTAssertGreaterThan(place.x, 0, "\(count)")
                XCTAssertLessThan(place.x, screen.size.width, "\(count)")
                XCTAssertLessThanOrEqual(place.ground, screen.groundY, "\(count)")
                let height = CGFloat(trees(count)[place.index].height) * place.scale
                XCTAssertGreaterThanOrEqual(place.ground - height, screen.top, "\(count) tree \(place.index)")
            }
        }
    }

    func testRowsPutTheMostRecentlyActiveInFrontAndFadeTheRest() {
        let items = trees(40)
        let plan = ForestLayout.rows(items, screen: screen)
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
        XCTAssertEqual(ForestLayout.rows(trees(3), screen: screen).lines, 1)
        XCTAssertGreaterThan(ForestLayout.rows(trees(60), screen: screen).lines, 2)
    }

    func testAFolderStandsTogetherWithinALine() {
        let items = trees(40)
        let plan = ForestLayout.rows(items, screen: screen)
        for line in 0..<plan.lines {
            let standing = plan.placements.filter { $0.line == line }.sorted { $0.x < $1.x }.map { items[$0.index] }
            let keys = standing.map { "\($0.group)\u{1F}\($0.id)" }
            XCTAssertEqual(keys, keys.sorted(), "line \(line)")
        }
    }

    func testPlacementsAreDeterministic() {
        XCTAssertEqual(ForestLayout.rows(trees(33), screen: screen), ForestLayout.rows(trees(33), screen: screen))
    }

    func testAGapKeepsTheMiddleClearAndEveryTreeOnScreen() {
        var beside = screen
        beside.gap = 600
        beside.minFade = 0.4
        for count in [3, 20, 52] {
            let items = trees(count)
            let plan = ForestLayout.rows(items, screen: beside)
            XCTAssertEqual(plan.placements.count, count)
            for place in plan.placements {
                // The foot is out of the gap, whichever side; the crown's own width may reach into it.
                XCTAssertFalse(abs(place.x - screen.size.width / 2) < 300 - 1, "\(count): tree at \(place.x)")
                XCTAssertGreaterThanOrEqual(place.fade, 0.4, "even the front line stands back")
                XCTAssertGreaterThan(place.x, 0)
                XCTAssertLessThan(place.x, screen.size.width)
            }
            // The lines are narrower, so the trees stand smaller than without a gap.
            XCTAssertLessThanOrEqual(plan.scale, ForestLayout.rows(items, screen: screen).scale)
        }
    }

    func testAGroundLineBehindIsCutAtTheGap() {
        var beside = screen
        beside.gap = 500
        let plan = ForestLayout.rows(trees(52), screen: beside)
        let middle = screen.size.width / 2
        XCTAssertGreaterThan(plan.grounds.count, plan.lines - 1, "a line with trees both sides has two pieces")
        for ground in plan.grounds { XCTAssertFalse(ground.from < middle - 1 && ground.to > middle + 1, "no piece crosses the middle") }
    }

    /// Rows rank by the day of the last commit, so a commit in a back-row repo re-packs every line it
    /// passes through, and the lines it doesn't touch drift a few points because the scale is shared
    /// (the known cost of ranking, which is why the app freezes the ranking: docs/forest/PLAN.md). No
    /// other tree changes line.
    func testACommitInRowsRepacksOnlyTheLinesItCrosses() {
        var items = trees(40)
        let before = ForestLayout.rows(items, screen: screen)
        items[7].lastActive = now
        let after = ForestLayout.rows(items, screen: screen)
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

    func testLastActiveIsTheNewestCommit() {
        let fresh = RepoTree.Commit(sha: "a", date: now), old = RepoTree.Commit(sha: "b", date: now.addingTimeInterval(-90 * 86_400))
        let tree = RepoTree(trunkName: "main", trunk: [old, fresh, old], limbs: [], isTrunkCheckedOut: false)
        XCTAssertEqual(tree.lastActive, now)
        XCTAssertEqual(RepoTree(trunkName: "main", trunk: [], limbs: [], isTrunkCheckedOut: false).lastActive, .distantPast)
    }
}

final class ForestPolicyTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheOrchardPacksOnlyPastItsLimit() {
        let policy = ForestPolicy(plainLimit: 12)
        XCTAssertFalse(ForestMode.auto.packs(12, policy: policy))
        XCTAssertTrue(ForestMode.auto.packs(13, policy: policy))
        XCTAssertFalse(ForestMode.off.packs(64, policy: policy))
        XCTAssertTrue(ForestMode.rows.packs(2, policy: policy))
    }

    func testTheTreeHoldsMoreOnATallerDisplay() {
        let policy = ForestPolicy()
        XCTAssertEqual(policy.treeCapacity(for: CGSize(width: 1440, height: 900)), 12)
        XCTAssertEqual(policy.treeCapacity(for: CGSize(width: 3440, height: 1440)), 20)
        XCTAssertEqual(policy.treeCapacity(for: CGSize(width: 2560, height: 1440)), 20)
        XCTAssertEqual(policy.treeCapacity(for: CGSize(width: 800, height: 400)), 8, "never fewer than a handful")
        XCTAssertEqual(ForestPolicy(fixedTreeCapacity: 5).treeCapacity(for: CGSize(width: 3440, height: 1440)), 5)
    }

    func testRankingGoesByDayThenName() {
        let entries: [(id: String, lastActive: Date)] = [
            ("b", now.addingTimeInterval(-10 * day)), ("d", now), ("a", now.addingTimeInterval(-10 * day)), ("c", now.addingTimeInterval(-60))
        ]
        // c and d are the same day (two commits in a day don't swap places): by name.
        XCTAssertEqual(ForestPolicy.rank(entries).map { entries[$0].id }, ["c", "d", "a", "b"])
    }

    func testTheFitBlendsFromStandardToWideByCount() {
        XCTAssertEqual(YggdrasilLayout.Fit.fitting(count: 2), .standard)
        XCTAssertEqual(YggdrasilLayout.Fit.fitting(count: 4), .standard)
        XCTAssertEqual(YggdrasilLayout.Fit.fitting(count: 8), .wide)
        XCTAssertEqual(YggdrasilLayout.Fit.fitting(count: 20), .wide)
        let six = YggdrasilLayout.Fit.fitting(count: 6)
        XCTAssertGreaterThan(six.footSpread, YggdrasilLayout.Fit.standard.footSpread)
        XCTAssertLessThan(six.footSpread, YggdrasilLayout.Fit.wide.footSpread)
    }
}
