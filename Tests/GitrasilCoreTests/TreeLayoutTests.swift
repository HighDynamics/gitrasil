import XCTest
@testable import GitrasilCore

final class TreeLayoutTests: XCTestCase {

    private func commits(_ prefix: String, _ count: Int) -> [RepoTree.Commit] {
        (0..<count).map { RepoTree.Commit(sha: "\(prefix)\($0)", date: Date(timeIntervalSince1970: Double($0))) }
    }

    /// A 40-commit trunk with a low limb (with a sub-branch) and a high one.
    private func tree(lowCommits: Int = 5, extraLimb: RepoTree.Limb? = nil) -> RepoTree {
        var limbs = [
            RepoTree.Limb(name: "feature/low", commits: commits("l", lowCommits), parent: .trunk(node: 8), isCheckedOut: false),
            RepoTree.Limb(name: "feature/low-sub", commits: commits("s", 3), parent: .limb(index: 0, node: 2), isCheckedOut: false),
            RepoTree.Limb(name: "feature/high", commits: commits("h", 4), parent: .trunk(node: 36), isCheckedOut: true),
        ]
        if let extraLimb { limbs.append(extraLimb) }
        return RepoTree(trunkName: "main", trunk: commits("t", 40), limbs: limbs, isTrunkCheckedOut: false)
    }

    private func stem(_ layout: TreeLayout, _ name: String) -> TreeLayout.Stem? {
        layout.stems.first { $0.name == name }
    }

    private func points(_ stem: TreeLayout.Stem?) -> [CGPoint] { stem?.nodes.map(\.point) ?? [] }

    func testALimbWhoseParentComesAfterItIsLeftOut() {
        let limbs = [
            RepoTree.Limb(name: "early-sub", commits: commits("s", 2), parent: .limb(index: 1, node: 1), isCheckedOut: false),
            RepoTree.Limb(name: "feature", commits: commits("f", 3), parent: .trunk(node: 10), isCheckedOut: false),
            RepoTree.Limb(name: "stray", commits: commits("x", 2), parent: .limb(index: 9, node: 0), isCheckedOut: false),
        ]
        let layout = TreeLayout(tree: RepoTree(trunkName: "main", trunk: commits("t", 20), limbs: limbs,
                                               isTrunkCheckedOut: false), seed: "ash")
        XCTAssertNotNil(stem(layout, "feature"))
        XCTAssertNil(stem(layout, "early-sub"))
        XCTAssertNil(stem(layout, "stray"))
    }

    func testTheSameTreeGrowsTheSameEveryTime() {
        let a = TreeLayout(tree: tree(), seed: "ash"), b = TreeLayout(tree: tree(), seed: "ash")
        XCTAssertEqual(a.stems.map(\.nodes), b.stems.map(\.nodes))
        XCTAssertEqual(a.bounds, b.bounds)
    }

    func testEveryStemHasANodePerCommitAfterItsBase() {
        let layout = TreeLayout(tree: tree(), seed: "ash")
        XCTAssertEqual(layout.stems.map(\.name), ["main", "feature/low", "feature/low-sub", "feature/high"])
        XCTAssertEqual(layout.stems.map(\.nodes.count), [41, 6, 4, 5])
        XCTAssertEqual(layout.stems.map(\.level), [0, 1, 2, 1])
        XCTAssertEqual(stem(layout, "main")?.nodes.first?.point, .zero, "the trunk stands on the origin")
    }

    func testLimbsLeaveFromTheirForkCommit() {
        let layout = TreeLayout(tree: tree(), seed: "ash")
        let trunk = layout.stems[0], low = stem(layout, "feature/low")!
        XCTAssertEqual(low.nodes.first?.point, trunk.nodes[8].point)
        XCTAssertEqual(stem(layout, "feature/low-sub")?.nodes.first?.point, low.nodes[2].point)
        XCTAssertGreaterThan(stem(layout, "feature/high")!.nodes[0].point.y, low.nodes[0].point.y,
                             "a fork from more recent trunk leaves higher")
    }

    func testANewCommitGrowsAStepAtTheTipAndMovesNothingElse() {
        let before = TreeLayout(tree: tree(lowCommits: 5), seed: "ash")
        let after = TreeLayout(tree: tree(lowCommits: 6), seed: "ash")
        let low = points(stem(after, "feature/low"))
        XCTAssertEqual(low.count, 7)
        XCTAssertEqual(Array(low.prefix(6)), points(stem(before, "feature/low")), "earlier nodes stay put")
        for name in ["main", "feature/low-sub", "feature/high"] {
            XCTAssertEqual(points(stem(after, name)), points(stem(before, name)), name)
        }
    }

    func testANewBranchHighUpLeavesTheLimbsBelowAlone() {
        let sprout = RepoTree.Limb(name: "feature/sprout", commits: commits("p", 2), parent: .trunk(node: 40), isCheckedOut: false)
        let before = TreeLayout(tree: tree(), seed: "ash")
        let after = TreeLayout(tree: tree(extraLimb: sprout), seed: "ash")
        for name in ["main", "feature/low", "feature/low-sub", "feature/high"] {
            XCTAssertEqual(points(stem(after, name)), points(stem(before, name)), name)
        }
        XCTAssertEqual(stem(after, "feature/sprout")?.nodes.count, 3)
    }

    func testStemsTaperFromBaseToTip() {
        let layout = TreeLayout(tree: tree(), seed: "ash")
        for stem in layout.stems {
            let widths = stem.nodes.map(\.width)
            XCTAssertEqual(widths, widths.sorted(by: >), "\(stem.name ?? "trunk") never thickens toward its tip")
        }
        XCTAssertGreaterThan(layout.stems[0].nodes[0].width, stem(layout, "feature/low")!.nodes[0].width)
    }

    func testAGrowingLimbShowsPartOfItsLastStep() {
        let full = TreeLayout(tree: tree(), seed: "ash")
        let growing = TreeLayout(tree: tree(), seed: "ash", grown: ["feature/low": 2.5])
        let low = stem(growing, "feature/low")!
        XCTAssertEqual(low.nodes.count, 4, "base, two whole steps, and half the third")
        XCTAssertEqual(Array(low.nodes.prefix(3).map(\.point)), Array(points(stem(full, "feature/low")).prefix(3)))
        let a = full.stems[1].nodes[2].point, b = full.stems[1].nodes[3].point, mid = low.nodes[3].point
        XCTAssertLessThan(hypot(mid.x - a.x, mid.y - a.y), hypot(b.x - a.x, b.y - a.y))
        XCTAssertEqual(stem(growing, "feature/low-sub")?.nodes.count, 4, "its sub-branch's fork node is grown")
        let early = TreeLayout(tree: tree(), seed: "ash", grown: ["feature/low": 1.5])
        XCTAssertEqual(stem(early, "feature/low-sub")?.nodes.count, 0, "a sub-branch waits for its fork node")
    }

    func testAYoungRepositoryIsASapling() {
        let young = RepoTree(trunkName: "main", trunk: commits("t", 6), limbs: [], isTrunkCheckedOut: true)
        XCTAssertLessThan(TreeLayout(tree: young, seed: "x").bounds.maxY, TreeLayout(tree: tree(), seed: "x").bounds.maxY)
        XCTAssertEqual(TreeLayout.trunkHeight(commits: 1), TreeLayout.saplingHeight)
        XCTAssertEqual(TreeLayout.trunkHeight(commits: 500), 1)
    }

    func testLimbsOffTheTrunkBalanceTheCrown() {
        let limbs = (0..<8).map { RepoTree.Limb(name: "b\($0)", commits: commits("c\($0)", 2), parent: .trunk(node: 10 + $0 * 3), isCheckedOut: false) }
        let sides = TreeLayout.sides(RepoTree(trunkName: "main", trunk: commits("t", 40), limbs: limbs, isTrunkCheckedOut: false))
        var lean = 0.0
        for side in sides {
            lean += side
            XCTAssertLessThanOrEqual(abs(lean), 1)
        }
    }

    func testEveryLimbKnowsTheWoodItGrowsFrom() {
        let layout = TreeLayout(tree: tree(), seed: "ash")
        XCTAssertNil(layout.stems[0].fork, "the trunk stands on the ground")
        let low = stem(layout, "feature/low")!, sub = stem(layout, "feature/low-sub")!
        XCTAssertEqual(low.fork?.parent, 0)
        XCTAssertEqual(low.fork?.node, 8)
        XCTAssertEqual(low.fork?.width, layout.stems[0].nodes[8].width)
        XCTAssertEqual(sub.fork?.parent, layout.stems.firstIndex { $0.name == "feature/low" })
        XCTAssertEqual(sub.fork?.node, 2)
        XCTAssertEqual(sub.fork?.width, low.nodes[2].width)
    }

    func testACollarFlaresIntoItsParentAndEasesBackToItsOwnWidth() {
        let own = 0.01, parent = 0.05, angle = 1.2
        let exit = TreeLayout.collarExit(parentWidth: parent, angle: angle)
        let widths = stride(from: 0.0, through: exit + own * 4, by: own / 8).map {
            TreeLayout.collarWidth(at: $0, own: own, parentWidth: parent, angle: angle)
        }
        XCTAssertEqual(widths.first!, own * TreeLayout.collarFlare, accuracy: 1e-9, "flared at the fork")
        XCTAssertEqual(widths.last!, own, accuracy: 1e-9, "its own width a few widths past the parent's edge")
        XCTAssertEqual(widths, widths.sorted(by: >), "never swells again once it narrows")
        // Concave like a fillet: it narrows fastest right at the parent's edge.
        let past = widths.enumerated().filter { Double($0.offset) * own / 8 > exit }.map(\.element)
        let drops = zip(past, past.dropFirst()).map { $0 - $1 }
        XCTAssertEqual(drops, drops.sorted(by: >))
    }

    func testACollarNeverOutgrowsItsParent() {
        let width = TreeLayout.collarWidth(at: 0, own: 0.04, parentWidth: 0.05, angle: 1.0)
        XCTAssertLessThanOrEqual(width, 0.05)
        XCTAssertGreaterThanOrEqual(width, 0.04)
        XCTAssertEqual(TreeLayout.collarWidth(at: 0, own: 0.06, parentWidth: 0.05, angle: 1.0), 0.06,
                       "a stem wider than its parent stays its own width")
    }

    func testGrownInFullyIsTheTreeAsItStands() {
        let full = TreeLayout(tree: tree(), seed: "ash"), grown = TreeLayout(tree: tree(), seed: "ash", growIn: 1)
        XCTAssertEqual(grown.stems.map(\.nodes), full.stems.map(\.nodes))
        XCTAssertEqual(grown.stems.map(\.grown), full.stems.map(\.grown))
    }

    func testAGrowInStartsFromTheGroundAndOnlyEverAdds() {
        let start = TreeLayout(tree: tree(), seed: "ash", growIn: 0)
        XCTAssertLessThanOrEqual(start.stems[0].nodes.count, 1, "nothing above the foot yet")
        XCTAssertTrue(start.stems.dropFirst().allSatisfy(\.nodes.isEmpty), "no limbs yet")
        var top = -1.0, nodes = 0
        for step in 1...20 {
            let layout = TreeLayout(tree: tree(), seed: "ash", growIn: Double(step) / 20)
            let height = Double(layout.stems[0].nodes.last!.point.y)
            let count = layout.stems.reduce(0) { $0 + $1.nodes.count }
            XCTAssertGreaterThanOrEqual(height, top)
            XCTAssertGreaterThanOrEqual(count, nodes)
            top = height
            nodes = count
        }
    }

    func testAGrowingInLimbWaitsForTheTrunkToReachItsFork() {
        let full = TreeLayout(tree: tree(), seed: "ash")
        let forkHeight = Double(stem(full, "feature/high")!.nodes[0].point.y)
        for step in 1...40 {
            let layout = TreeLayout(tree: tree(), seed: "ash", growIn: Double(step) / 40)
            let reached = Double(layout.stems[0].nodes.last!.point.y)
            if reached < forkHeight - 1e-9 {
                XCTAssertEqual(stem(layout, "feature/high")?.nodes.count ?? 0, 0, "step \(step)")
            }
            let low = stem(layout, "feature/low")?.grown ?? 0
            if low < 2 { XCTAssertEqual(stem(layout, "feature/low-sub")?.nodes.count ?? 0, 0, "the sub-branch waits for node 2") }
        }
        let partway = TreeLayout(tree: tree(), seed: "ash", growIn: 0.7)
        XCTAssertEqual(Array(points(stem(partway, "feature/low")).prefix(2)), Array(points(stem(full, "feature/low")).prefix(2)),
                       "a growing limb follows its full shape")
    }

    func testAGrowInRunsFromTheTrunkOutToTheTwigs() {
        // A long low limb, so the limbs carry on after the trunk has risen.
        let schedule = TreeLayout.growInSchedule(tree(lowCommits: 30))
        let low = schedule.stretch(of: "feature/low")!, sub = schedule.stretch(of: "feature/low-sub")!
        let high = schedule.stretch(of: "feature/high")!
        XCTAssertEqual(schedule.stretch(of: "main"), schedule.trunk)
        XCTAssertNil(schedule.stretch(of: "nowhere"))
        XCTAssertEqual(schedule.trunk.start, 0)
        XCTAssertLessThan(schedule.trunk.end, 1, "the limbs carry on after the trunk")
        // A limb starts when the rising trunk reaches its fork: the low one sooner than the high one.
        XCTAssertGreaterThan(low.start, 0)
        XCTAssertLessThan(low.start, high.start)
        XCTAssertLessThan(high.start, schedule.trunk.end)
        // The sub-branch starts two of its parent's thirty commits along it.
        XCTAssertEqual(sub.start, low.start + (low.end - low.start) * 2 / 30, accuracy: 1e-12)
        // They don't all finish together: the last stem finishes at the very end.
        let ends = [schedule.trunk, low, sub, high].map(\.end)
        XCTAssertEqual(ends.max()!, 1, accuracy: 1e-12)
        XCTAssertGreaterThan(Set(ends).count, 1)
        XCTAssertTrue(ends.allSatisfy { $0 <= 1 + 1e-12 })
    }

    func testEachStemGrowsSmoothlyThroughItsOwnStretch() {
        let full = TreeLayout(tree: tree(), seed: "ash"), schedule = full.schedule
        XCTAssertEqual(schedule, TreeLayout.growInSchedule(tree()))
        var previous: [String: Double] = [:]
        let steps = 400
        for step in 0...steps {
            let growIn = Double(step) / Double(steps)
            let layout = TreeLayout(tree: tree(), seed: "ash", growIn: growIn)
            for limb in tree().limbs {
                let stretch = schedule.stretch(of: limb.name)!, count = Double(max(limb.commits.count, 1))
                let grown = stem(layout, limb.name)?.grown ?? 0
                if growIn <= stretch.start { XCTAssertEqual(grown, 0, "\(limb.name) waits for its start") }
                if growIn >= stretch.end { XCTAssertEqual(grown, count, "\(limb.name) is grown by its end") }
                // No jumps: a step of the grow-in grows a limb by no more than its share of it.
                let most = count / (Double(steps) * (stretch.end - stretch.start)) + 1e-9
                XCTAssertLessThanOrEqual(grown - (previous[limb.name] ?? 0), most, "\(limb.name) at \(growIn)")
                XCTAssertGreaterThanOrEqual(grown, previous[limb.name] ?? 0)
                previous[limb.name] = grown
            }
        }
        XCTAssertEqual(previous, Dictionary(uniqueKeysWithValues: full.stems.dropFirst().map { ($0.name!, $0.grown) }))
    }

    func testTheScheduleIsTheLayoutsOwn() {
        // A fork past the trunk's tip is clamped to the tip, in the layout and the schedule alike.
        let stray = RepoTree.Limb(name: "past-the-tip", commits: commits("p", 3), parent: .trunk(node: 60), isCheckedOut: false)
        let tip = RepoTree.Limb(name: "at-the-tip", commits: commits("q", 3), parent: .trunk(node: 40), isCheckedOut: false)
        let tree = RepoTree(trunkName: "main", trunk: commits("t", 40), limbs: [stray, tip], isTrunkCheckedOut: false)
        let layout = TreeLayout(tree: tree, seed: "ash")
        XCTAssertEqual(stem(layout, "past-the-tip")?.scale, stem(layout, "at-the-tip")?.scale)
        XCTAssertEqual(layout.schedule.limbs[0], layout.schedule.limbs[1])
        XCTAssertEqual(stem(layout, "past-the-tip")?.nodes.first?.point, layout.stems[0].nodes.last?.point)
        for growIn in [0.0, 0.3, 0.8, 1] {
            XCTAssertEqual(TreeLayout(tree: tree, seed: "ash", growIn: growIn).schedule, layout.schedule,
                           "the same schedule, growing in or not")
        }
    }

    func testGrowInEasesInAndOut() {
        XCTAssertEqual(TreeLayout.growIn(0), 0)
        XCTAssertEqual(TreeLayout.growIn(1), 1)
        XCTAssertEqual(TreeLayout.growIn(2), 1)
        XCTAssertLessThan(TreeLayout.growIn(0.1), 0.1)
        XCTAssertGreaterThan(TreeLayout.growIn(0.9), 0.9)
    }
}
