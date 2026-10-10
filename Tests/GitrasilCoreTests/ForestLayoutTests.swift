import XCTest
@testable import GitrasilCore

final class ForestLayoutTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let screen = ForestScreen(size: CGSize(width: 1440, height: 900), groundY: 783, top: 44, margin: 40, nominalHeight: 1.45)

    /// `count` trees of varied crowns and ages, in groups of five folders.
    private func trees(_ count: Int) -> [ForestTree] {
        (0..<count).map { (i: Int) -> ForestTree in
            let left: Double = -0.2 - Double(i % 4) * 0.1
            let right: Double = 0.25 + Double(i % 3) * 0.15
            let height: Double = 1.0 + Double(i % 5) * 0.1
            let days: Double = Double((i * 7) % 40) * 3
            return ForestTree(id: String(format: "tree%02d", i), group: "/work/group\(i % 5)", left: left, right: right,
                              height: height, lastActive: now.addingTimeInterval(-days * 86_400))
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
        XCTAssertGreaterThanOrEqual(Calendar.current.startOfDay(for: newestFront), Calendar.current.startOfDay(for: newestBack))
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

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    func testRankingGoesByDayThenName() {
        let entries: [(id: String, lastActive: Date)] = [
            ("b", now.addingTimeInterval(-10 * day)), ("d", now), ("a", now.addingTimeInterval(-10 * day)), ("c", now.addingTimeInterval(-60))
        ]
        // c and d are the same day (two commits in a day don't swap places): by name.
        XCTAssertEqual(ForestPolicy.rank(entries, calendar: calendar("UTC")).map { entries[$0].id }, ["c", "d", "a", "b"])
    }

    func testTheDayIsTheUsersNotUTC() {
        // 03:00 and 09:00 UTC on one day: the same day in London, but in Los Angeles (UTC-8 in January) the
        // first is the evening before.
        let early = Date(timeIntervalSince1970: 1_767_322_800), late = early.addingTimeInterval(6 * 3600)
        let entries: [(id: String, lastActive: Date)] = [("a", early), ("b", late)]
        XCTAssertEqual(ForestPolicy.rank(entries, calendar: calendar("Europe/London")).map { entries[$0].id }, ["a", "b"], "one day: by name")
        XCTAssertEqual(ForestPolicy.rank(entries, calendar: calendar("America/Los_Angeles")).map { entries[$0].id }, ["b", "a"],
                       "two days: the later first")
    }

    func testTheFitBlendsFromStandardToWideByCount() {
        XCTAssertEqual(YggdrasilLayout.Fit.fitting(count: 2), .standard)
        XCTAssertEqual(YggdrasilLayout.Fit.fitting(count: 4), .standard)
        // From 8 on it's the wide fan, spreading further into an oak as boughs are added.
        for count in [8, 20, 40] {
            var fit = YggdrasilLayout.Fit.fitting(count: count)
            XCTAssertEqual(fit.oak, YggdrasilLayout.Fit.oak(count: count))
            fit.oak = 0
            XCTAssertEqual(fit, .wide, "\(count)")
        }
        let six = YggdrasilLayout.Fit.fitting(count: 6)
        XCTAssertGreaterThan(six.footSpread, YggdrasilLayout.Fit.standard.footSpread)
        XCTAssertLessThan(six.footSpread, YggdrasilLayout.Fit.wide.footSpread)
    }

    func testTheTreeGrowsIntoAnOakAsBoughsAreAdded() {
        XCTAssertEqual(YggdrasilLayout.Fit.oak(count: 2), 0)
        XCTAssertEqual(YggdrasilLayout.Fit.oak(count: 5), 0, "a handful of boughs is the tree as it was")
        let oaks = (5...40).map { YggdrasilLayout.Fit.oak(count: $0) }
        XCTAssertEqual(oaks, oaks.sorted(), "never less of an oak for more boughs")
        XCTAssertEqual(YggdrasilLayout.Fit.oak(count: 28), 1)
        XCTAssertEqual(YggdrasilLayout.Fit.oak(count: 64), 1)
    }
}
