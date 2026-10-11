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
            RepoTree.Limb(name: "feature/high", commits: commits("h", 4), parent: .trunk(node: 36), isCheckedOut: true)
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
            RepoTree.Limb(name: "stray", commits: commits("x", 2), parent: .limb(index: 9, node: 0), isCheckedOut: false)
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

    func testAReshuffleMovesTheLimbsButKeepsTheBranching() {
        let first = TreeLayout(tree: tree(), seed: "ash")
        XCTAssertEqual(TreeLayout(tree: tree(), seed: "ash", shuffle: 0).stems.map(\.nodes), first.stems.map(\.nodes),
                       "seed 0 is the shape the names alone give")
        let a = TreeLayout(tree: tree(), seed: "ash", shuffle: 4242), b = TreeLayout(tree: tree(), seed: "ash", shuffle: 4242)
        XCTAssertEqual(a.stems.map(\.nodes), b.stems.map(\.nodes), "the same seed, the same shape")
        let c = TreeLayout(tree: tree(), seed: "ash", shuffle: 77)
        for other in [a, c] {
            XCTAssertEqual(other.stems.map(\.name), first.stems.map(\.name))
            XCTAssertEqual(other.stems.map(\.nodes.count), first.stems.map(\.nodes.count))
            XCTAssertEqual(other.stems.map(\.fork?.node), first.stems.map(\.fork?.node), "each limb leaves where it did")
            XCTAssertNotEqual(points(stem(other, "main")), points(stem(first, "main")), "the trunk sways differently")
            XCTAssertNotEqual(points(stem(other, "feature/low")), points(stem(first, "feature/low")))
        }
        XCTAssertNotEqual(points(stem(a, "feature/low")), points(stem(c, "feature/low")))
        XCTAssertEqual(TreeLayout(tree: tree(), seed: "ash", growIn: 1, shuffle: 77).stems.map(\.nodes), c.stems.map(\.nodes),
                       "it grows in to the shape it settles in")
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
        let limbs = (0..<8).map {
            RepoTree.Limb(name: "b\($0)", commits: commits("c\($0)", 2), parent: .trunk(node: 10 + $0 * 3), isCheckedOut: false)
        }
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

    func testANameFadesInAsItsStemReachesItsTip() {
        let long = TreeLayout.Stretch(start: 0.2, end: 0.7)
        XCTAssertEqual(long.nameShown(at: 0.5), 0, "hidden while the stem grows")
        XCTAssertEqual(long.nameShown(at: 0.7 - TreeLayout.Stretch.nameFade / 2), 0.5, accuracy: 1e-12)
        XCTAssertEqual(long.nameShown(at: 0.7), 1, "whole as the stem reaches its tip")
        XCTAssertEqual(long.nameShown(at: 1), 1)
        let short = TreeLayout.Stretch(start: 0.9, end: 0.92)
        XCTAssertEqual(short.nameShown(at: 0.9), 0)
        XCTAssertEqual(short.nameShown(at: 0.91), 0.5, accuracy: 1e-9, "a short stem's name fades over all of it")
        XCTAssertEqual(short.nameShown(at: 0.92), 1)
    }

    func testGrowInEasesInAndOut() {
        XCTAssertEqual(TreeLayout.growIn(0), 0)
        XCTAssertEqual(TreeLayout.growIn(1), 1)
        XCTAssertEqual(TreeLayout.growIn(2), 1)
        XCTAssertLessThan(TreeLayout.growIn(0.1), 0.1)
        XCTAssertGreaterThan(TreeLayout.growIn(0.9), 0.9)
    }

    // MARK: Tips

    /// A tree like a long-lived repository's: a 200-commit trunk, limbs from one commit to a dozen, a
    /// limb with a sub-limb leaving at its very last commit, a bud, and a limb at the trunk's tip.
    private func thicket() -> RepoTree {
        let limbs = [
            RepoTree.Limb(name: "one", commits: commits("a", 1), parent: .trunk(node: 60), isCheckedOut: false),
            RepoTree.Limb(name: "long", commits: commits("b", 12), parent: .trunk(node: 80), isCheckedOut: false),
            RepoTree.Limb(name: "long-sub", commits: commits("c", 3), parent: .limb(index: 1, node: 12), isCheckedOut: false),
            RepoTree.Limb(name: "bud", commits: [], parent: .trunk(node: 40), isCheckedOut: false),
            RepoTree.Limb(name: "mid", commits: commits("d", 5), parent: .trunk(node: 140), isCheckedOut: true),
            RepoTree.Limb(name: "at-the-tip", commits: commits("e", 2), parent: .trunk(node: 200), isCheckedOut: false)
        ]
        return RepoTree(trunkName: "main", trunk: commits("t", 200), limbs: limbs, isTrunkCheckedOut: true)
    }

    /// A stem's width at its very end, as drawn: the tapered tip.
    private func tipWidth(_ stem: TreeLayout.Stem) -> Double {
        (stem.curve.last?.width ?? 0) * stem.tipTaper.factor(distanceToTip: 0)
    }

    /// The stem's end is a point: under 0.002 of the trunk's height (2 pt on a tree drawn a thousand
    /// points tall), where its untapered end was 3–10.
    private func assertPoint(_ stem: TreeLayout.Stem, _ message: String = "", line: UInt = #line) {
        XCTAssertLessThan(tipWidth(stem), 0.002, message, line: line)
    }

    func testTheTaperEasesInAndEndsInAPoint() {
        let taper = TreeLayout.TipTaper(stemLength: 1) { _ in 0.01 }
        XCTAssertGreaterThan(taper.length, 0)
        XCTAssertEqual(taper.factor(distanceToTip: taper.length), 1, accuracy: 1e-12)
        XCTAssertEqual(taper.factor(distanceToTip: taper.length * 3), 1, "full width before it starts")
        XCTAssertLessThan(taper.factor(distanceToTip: 0), 0.05, "a fine point at the end")
        XCTAssertGreaterThan(taper.factor(distanceToTip: 0), 0, "never quite nothing")
        XCTAssertGreaterThan(taper.factor(distanceToTip: taper.length * 0.97), 0.995, "no corner where it starts")
        var last = 0.0
        for step in 0...40 {
            let f = taper.factor(distanceToTip: taper.length * Double(step) / 40)
            XCTAssertGreaterThanOrEqual(f, last, "narrower the nearer the end")
            last = f
        }
    }

    func testALimbForkingInsideItsParentsTaperFlaresIntoTheThinWoodThatsThere() {
        let limbs = [
            RepoTree.Limb(name: "parent", commits: commits("p", 5), parent: .trunk(node: 30), isCheckedOut: false),
            RepoTree.Limb(name: "child", commits: commits("c", 3), parent: .limb(index: 0, node: 4), isCheckedOut: false),
            RepoTree.Limb(name: "at-the-end", commits: commits("e", 2), parent: .limb(index: 0, node: 5), isCheckedOut: false)
        ]
        let layout = TreeLayout(tree: RepoTree(trunkName: "main", trunk: commits("t", 60), limbs: limbs, isTrunkCheckedOut: false),
                                seed: "ash")
        let parent = stem(layout, "parent")!
        for (name, node) in [("child", 4), ("at-the-end", 5)] {
            let child = stem(layout, name)!, fork = child.fork!
            let wood = parent.nodes[node]
            XCTAssertEqual(fork.node, node)
            XCTAssertEqual(fork.width, wood.width * parent.taperFactor(at: wood.point), accuracy: 1e-12)
            XCTAssertLessThan(fork.width, wood.width, "\(name) forks in the taper, where the parent is narrower than its nodes say")
            // What the child's base flares to is bounded by the wood drawn there, not the wood that
            // would have been (it was 1.5× the parent's drawn width before).
            let own = child.nodes[0].width
            let flared = TreeLayout.collarWidth(at: 0, own: own, parentWidth: fork.width, angle: 0.8)
            XCTAssertLessThanOrEqual(flared, max(own, fork.width) + 1e-12, name)
        }
        XCTAssertEqual(stem(layout, "at-the-end")!.fork!.width, parent.nodes[5].width * TreeLayout.TipTaper.point, accuracy: 1e-9,
                       "a limb leaving at the very end leaves a point")
        // A fork well back from the end, and a trunk's, are as wide as the pipe model says.
        let long = TreeLayout(tree: thicket(), seed: "ash")
        XCTAssertEqual(stem(long, "one")!.fork!.width, long.stems[0].nodes[60].width, accuracy: 1e-12)
        XCTAssertEqual(stem(long, "long-sub")!.fork!.width, stem(long, "long")!.nodes[12].width * TreeLayout.TipTaper.point, accuracy: 1e-9)
        XCTAssertEqual(long.stems[0].taperFactor(at: long.stems[0].curve[0].point), 1, accuracy: 1e-12, "a trunk's foot is untouched")
        XCTAssertEqual(stem(long, "at-the-tip")!.fork!.width, long.stems[0].nodes[200].width * TreeLayout.TipTaper.point, accuracy: 1e-9)
    }

    func testAStemWithNothingGrownYetHasNoTaperAndDoesNotTrap() {
        let tree = thicket()
        // Growing in from nothing: every limb (and the trunk) has an empty curve, and some a single point.
        let start = TreeLayout(tree: tree, seed: "ash", growIn: 0)
        XCTAssertTrue(start.stems.contains { $0.curve.isEmpty }, "the layout does hand out empty stems at 0")
        for growIn in [0.0, 0.0001, 0.02] {
            for stem in TreeLayout(tree: tree, seed: "ash", growIn: growIn).stems where stem.curve.count < 2 {
                XCTAssertEqual(stem.tipTaper.length, 0)
                XCTAssertEqual(stem.tipTaper.factor(distanceToTip: 0), 1, "no taper to apply")
                XCTAssertEqual(stem.taperFactor(at: .zero), 1)
            }
        }
    }

    func testEveryStemEndsInAFinePointNarrowerThanTheLayoutsFloor() {
        let layout = TreeLayout(tree: thicket(), seed: "ash")
        // The pipe model's narrowest: a limb's last node is never below this.
        let floor = TreeLayout.width(weight: 0.5)
        for stem in layout.stems {
            XCTAssertTrue(stem.tapersToTip, stem.name ?? "?")
            XCTAssertGreaterThan(stem.curve.last?.width ?? 0, floor * 0.99, "the layout's own widths keep their floor (\(stem.name ?? "?"))")
            assertPoint(stem, "\(stem.name ?? "?") ends in a point")
        }
    }

    func testAShortLimbIsAThornPointedOverMostOfItsLength() {
        let layout = TreeLayout(tree: thicket(), seed: "ash")
        for name in ["one", "bud"] {
            let short = stem(layout, name)!
            let length = zip(short.curve, short.curve.dropFirst()).reduce(0.0) {
                $0 + hypot($1.1.point.x - $1.0.point.x, $1.1.point.y - $1.0.point.y)
            }
            XCTAssertGreaterThan(short.tipTaper.length, length * 0.6, "\(name) narrows over most of its length")
            XCTAssertLessThanOrEqual(short.tipTaper.length, length * 0.85 + 1e-12, "but keeps a base")
            let halfway = short.curve[short.curve.count / 2].width
                * short.tipTaper.factor(distanceToTip: length / 2)
            XCTAssertLessThan(halfway, short.curve[0].width, "\(name) is already narrower than its base halfway out")
        }
    }

    func testAWideTrunkTopTapersOverALongerStretchThanAFineTwig() {
        let layout = TreeLayout(tree: thicket(), seed: "ash")
        let trunk = layout.stems[0], floor = TreeLayout.width(weight: 0.5)
        XCTAssertGreaterThan(trunk.curve.last!.width, floor, "the trunk's top is wider than a limb's end")
        XCTAssertGreaterThan(trunk.tipTaper.length, TreeLayout.TipTaper.reach * trunk.curve.last!.width,
                             "it's asked where the taper would start, and that's wider than at the tip")
        assertPoint(trunk)
    }

    func testALimbWithASubLimbAtItsEndStillEndsInAPoint() {
        let layout = TreeLayout(tree: thicket(), seed: "ash")
        let long = stem(layout, "long")!
        XCTAssertGreaterThan(long.curve.last!.width, TreeLayout.width(weight: 0.5) * 1.5, "carries its sub-limb to the end")
        assertPoint(long)
    }

    func testAStemStillGrowingTapersToWhereItHasGot() {
        let tree = thicket()
        func length(_ stem: TreeLayout.Stem) -> Double {
            zip(stem.curve, stem.curve.dropFirst()).reduce(0.0) { $0 + hypot($1.1.point.x - $1.0.point.x, $1.1.point.y - $1.0.point.y) }
        }
        let finished = TreeLayout(tree: tree, seed: "ash")
        for growIn in [0.1, 0.35, 0.6, 0.85] {
            let layout = TreeLayout(tree: tree, seed: "ash", growIn: growIn)
            for stem in layout.stems where stem.curve.count >= 2 {
                let name = "\(stem.name ?? "?") at \(growIn)"
                assertPoint(stem, "\(name) is cut at a width the finished stem only has there")
                // The taper is sized to the stem as grown so far, not the finished one: it never
                // outruns what's there, and the cut wood is wider than the point it's tapered to.
                XCTAssertLessThanOrEqual(stem.tipTaper.length, TreeLayout.TipTaper.share * length(stem) + 1e-12, name)
                XCTAssertEqual(tipWidth(stem), TreeLayout.TipTaper.point * stem.curve.last!.width, accuracy: 1e-12, name)
                if let whole = finished.stems.first(where: { $0.name == stem.name }), stem.curve.count < whole.curve.count {
                    XCTAssertLessThan(length(stem), length(whole), name)
                    XCTAssertLessThan(stem.tipTaper.length, length(whole), name)
                }
            }
        }
        // A limb a few commits into growing new ones, as the model grows it.
        let partway = TreeLayout(tree: tree, seed: "ash", grown: ["long": 4.5])
        let long = stem(partway, "long")!, whole = stem(finished, "long")!
        XCTAssertEqual(long.grown, 4.5)
        assertPoint(long)
        XCTAssertGreaterThan(long.tipTaper.length, 0)
        XCTAssertLessThan(length(long), length(whole), "cut part way")
        XCTAssertGreaterThan(long.curve.last!.width, whole.curve.last!.width, "nearer the base, so thicker where it's cut")
        XCTAssertLessThanOrEqual(long.tipTaper.length, TreeLayout.TipTaper.share * length(long) + 1e-12)
    }

    func testTheTaperLeavesTheLayoutAlone() {
        // It's applied as the wood is drawn: the nodes and curves are the pipe model's, as before.
        let layout = TreeLayout(tree: thicket(), seed: "ash")
        for stem in layout.stems { XCTAssertEqual(stem.curve.last, stem.nodes.last) }
        XCTAssertEqual(stem(layout, "mid")?.nodes.last?.width ?? 0, TreeLayout.width(weight: 0.5), accuracy: 1e-12,
                       "a childless limb still ends at the pipe model's floor")
        // Each stem's last node as the layout places it without the taper (recorded from the node code,
        // limbs' curl and elbows included, seed "ash"): x, y, width, heading.
        let reference: [String: (x: Double, y: Double, width: Double, heading: Double)] = [
            "main": (-0.02418423723063762, 1.0, 0.009474613391789283, -0.19116934729886464),
            "one": (0.1184200771269034, 0.288733800889022, 0.0051698484809835, 1.3379967982619327),
            "long": (0.4720518518086952, 0.661936017598704, 0.010057480512225277, 0.6705170358624362),
            "long-sub": (0.6347697016896418, 0.7509732445725454, 0.0051698484809835, 0.6830558486255242),
            "bud": (-0.043428361378252955, 0.26641045365687754, 0.0051698484809835, -1.0922475979199362),
            "mid": (-0.2720834821981477, 0.6131224741529162, 0.0051698484809835, -0.5128087524281576),
            "at-the-tip": (-0.058727177320739225, 1.1109655372818492, 0.0051698484809835, -0.13301953209843087)
        ]
        XCTAssertEqual(Set(layout.stems.compactMap(\.name)), Set(reference.keys))
        for (name, expected) in reference {
            guard let last = stem(layout, name)?.nodes.last else { return XCTFail("no \(name)") }
            XCTAssertEqual(last.point.x, expected.x, accuracy: 1e-9, name)
            XCTAssertEqual(last.point.y, expected.y, accuracy: 1e-9, name)
            XCTAssertEqual(last.width, expected.width, accuracy: 1e-9, name)
            XCTAssertEqual(last.heading, expected.heading, accuracy: 1e-9, name)
        }
    }

    func testASharedTrunkEndsInItsBoughsNotAPoint() {
        let repo = YggdrasilLayout.Repo(name: "ash", tree: thicket())
        let layout = YggdrasilLayout(repos: [repo, YggdrasilLayout.Repo(name: "elm", tree: tree())])
        XCTAssertFalse(layout.trunk.tapersToTip)
        for bough in layout.boughs { XCTAssertTrue(bough.layout.stems[0].tapersToTip, "a bough's trunk is a tree's and ends in a point") }
    }

    // MARK: Bending

    func testABoughsBendIsSeededByItsName() {
        let ash = TreeLayout.Bend("ash", shuffle: 0, side: 1, length: 1.2)
        XCTAssertEqual(ash, TreeLayout.Bend("ash", shuffle: 0, side: 1, length: 1.2), "the same name bends the same")
        XCTAssertNotEqual(ash, TreeLayout.Bend("elm", shuffle: 0, side: 1, length: 1.2))
        XCTAssertNotEqual(ash, TreeLayout.Bend("ash", shuffle: 7, side: 1, length: 1.2), "a reshuffle bends it afresh")
        let most = (TreeLayout.boughCurl.upperBound + TreeLayout.boughWave.upperBound) * .pi / 180
        var ups = 0
        let names = (0..<200).map { "repo\($0)" }
        for name in names {
            // Too short for an elbow.
            let bend = TreeLayout.Bend(name, shuffle: 0, side: 1, length: 0.3)
            XCTAssertTrue(bend.elbows.isEmpty, name)
            let degrees = abs(bend.curl) * 180 / .pi
            XCTAssertTrue(TreeLayout.boughCurl.contains(degrees), name)
            XCTAssertTrue(TreeLayout.boughWave.contains(abs(bend.wave) * 180 / .pi), name)
            for t in stride(from: 0.0, through: 1, by: 0.05) { XCTAssertLessThanOrEqual(abs(bend.turn(at: t)), most + 1e-12) }
            for length in [0.3, 1.0, 1.8] {
                let long = TreeLayout.Bend(name, shuffle: 0, side: 1, length: length)
                XCTAssertEqual(long.turn(at: 0), 0)
                XCTAssertEqual(long.turn(at: 0.001), 0, accuracy: 1e-4, "level at the foot")
                XCTAssertEqual(long.curl, bend.curl, "its length only adds elbows")
            }
            if bend.curl < 0 { ups += 1 }
            // A bough leaning left bends the mirror way.
            let left = TreeLayout.Bend(name, shuffle: 0, side: -1, length: 1.8), right = TreeLayout.Bend(name, shuffle: 0, side: 1, length: 1.8)
            XCTAssertEqual(left.curl, -right.curl, accuracy: 1e-12)
            XCTAssertEqual(left.elbows.map(\.turn), right.elbows.map { -$0.turn })
        }
        XCTAssertGreaterThan(ups, names.count / 2, "most boughs curl up toward the light")
        XCTAssertLessThan(ups, names.count, "and a few down")
    }

    func testALongerBoughHasMoreElbows() {
        let names = (0..<200).map { "repo\($0)" }
        func elbows(_ length: Double) -> [[TreeLayout.Elbow]] {
            names.map { TreeLayout.Bend($0, shuffle: 0, side: 1, length: length).elbows }
        }
        XCTAssertTrue(elbows(0.3).allSatisfy(\.isEmpty), "a short bough stays simple")
        let counts = [0.45, 1.0, 1.4, 1.8].map { length in elbows(length).reduce(0) { $0 + $1.count } }
        XCTAssertEqual(counts, counts.sorted(), "the longer, the more")
        XCTAssertGreaterThan(counts[3], counts[0] * 3)
        var back = 0, pairs = 0, whole = 0, all = 0
        for joints in elbows(1.8) {
            XCTAssertTrue((1...TreeLayout.mostElbows).contains(joints.count))
            XCTAssertEqual(joints.map(\.at), joints.map(\.at).sorted(), "in order along it")
            for elbow in joints {
                XCTAssertGreaterThan(elbow.at, 0)
                XCTAssertLessThanOrEqual(elbow.at, TreeLayout.elbowReach)
                XCTAssertLessThanOrEqual(abs(elbow.turn) * 180 / .pi, TreeLayout.boughElbow.upperBound + 1e-9)
                all += 1
                if TreeLayout.boughElbow.contains(abs(elbow.turn) * 180 / .pi) { whole += 1 }
            }
            for (a, b) in zip(joints, joints.dropFirst()) {
                pairs += 1
                if a.turn * b.turn < 0 { back += 1 }
            }
        }
        XCTAssertGreaterThan(back, pairs / 2, "an elbow mostly turns back the other way from the last")
        XCTAssertLessThan(back, pairs, "but not always")
        XCTAssertGreaterThan(whole, all * 3 / 4, "most elbows turn as far as they were seeded to")
    }

    func testNoBoughTurnsPastTheCapAnywhereAlongIt() {
        let most = TreeLayout.boughTurn * .pi / 180
        var worst = 0.0
        for index in 0..<600 {
            for length in stride(from: 0.4, through: 2.2, by: 0.2) {
                for side in [1.0, -1.0] {
                    let bend = TreeLayout.Bend("repo\(index)", shuffle: index % 3, side: side, length: length)
                    for t in stride(from: 0.0, through: 1, by: 0.002) { worst = max(worst, abs(bend.turn(at: t))) }
                }
            }
        }
        XCTAssertLessThanOrEqual(worst, most + 1e-9, "worst \(worst * 180 / .pi)°")
    }

    func testABoughsElbowsStayPutAsItGrowsLonger() {
        for index in 0..<300 {
            let name = "repo\(index)"
            var last: [TreeLayout.Elbow] = [], lastLength = 0.0
            for length in stride(from: 0.3, through: 2.2, by: 0.05) {
                let elbows = TreeLayout.Bend(name, shuffle: 0, side: 1, length: length).elbows
                XCTAssertGreaterThanOrEqual(elbows.count, last.count, "\(name) at \(length): it keeps the elbows it had")
                // Each that was there is the same distance out from the foot.
                for (before, now) in zip(last, elbows) {
                    XCTAssertEqual(before.at * lastLength, now.at * length, accuracy: 1e-9, "\(name) at \(length)")
                    XCTAssertEqual(before.span * lastLength, now.span * length, accuracy: 1e-9)
                    XCTAssertEqual(before.knot, now.knot, "\(name) at \(length): and keeps its knot")
                }
                last = elbows
                lastLength = length
            }
        }
    }

    func testAnElbowTurnsSmoothlyAndThickensTheWoodAtItsJoint() {
        let elbow = TreeLayout.Elbow(at: 0.5, span: 0.05, turn: 0.5)
        let bend = TreeLayout.Bend(curl: 0, wave: 0, elbows: [elbow])
        XCTAssertEqual(bend.turn(at: 0.4), 0, accuracy: 1e-12, "nothing before it")
        XCTAssertEqual(bend.turn(at: 0.6), 0.5, accuracy: 1e-12, "and all of it after: it carries on its new way")
        var last = 0.0
        for t in stride(from: 0.45, through: 0.55, by: 0.001) {
            let turn = bend.turn(at: t)
            XCTAssertGreaterThanOrEqual(turn, last - 1e-12)
            XCTAssertLessThan(turn - last, 0.5 * 0.001 / 0.05 * 1.5 + 1e-9, "a turn, not a kink")
            last = turn
        }
        XCTAssertEqual(bend.knuckle(at: 0.5), TreeLayout.knuckle(0.5), accuracy: 1e-12, "thickest at the joint")
        XCTAssertGreaterThan(TreeLayout.knuckle(0.5), 1)
        XCTAssertLessThanOrEqual(TreeLayout.knuckle(0.5), 1 + TreeLayout.knuckleWidth.upperBound)
        XCTAssertEqual(bend.knuckle(at: 0.3), 1, accuracy: 1e-6, "and only there")
        XCTAssertEqual(TreeLayout.knuckle(0), 1)
    }

    func testAnElbowHeadingDownNeverTakesABoughBelowItsPlanting() {
        for heading in [1.2, 1.7, -1.2, -1.9] {
            // Turning down, on its side.
            let way = heading < 0 ? -1.0 : 1
            let down = TreeLayout.Bend(curl: 0.3 * way, wave: 0, elbows: [.init(at: 0.3, span: 0.05, turn: 0.6 * way),
                                                                          .init(at: 0.6, span: 0.05, turn: 0.6 * way)])
            let points = TreeLayout.bough(heading: heading, length: 1.5, straighten: 0, bend: down)
            let lowest = max(abs(heading), .pi / 2)
            for (a, b) in zip(points, points.dropFirst()) {
                let h = atan2(b.x - a.x, b.y - a.y)
                XCTAssertLessThanOrEqual(abs(h), lowest + 1e-6, "leaning \(heading)")
                XCTAssertGreaterThan(h * heading, 0, "it stays on its side")
            }
        }
    }

    func testALimbsElbowsAreSeededAndComeWithItsLength() {
        let names = (0..<300).map { "feature/\($0)" }
        XCTAssertEqual(TreeLayout.elbow(of: "feature/low", shuffle: 0, step: 5, after: 0),
                       TreeLayout.elbow(of: "feature/low", shuffle: 0, step: 5, after: 0))
        var found = 0
        for name in names {
            for step in 1..<TreeLayout.limbElbowFrom { XCTAssertEqual(TreeLayout.elbow(of: name, shuffle: 0, step: step, after: 0), 0) }
            for step in TreeLayout.limbElbowFrom..<(TreeLayout.limbElbowFrom + 10) {
                let elbow = TreeLayout.elbow(of: name, shuffle: 0, step: step, after: 0)
                guard elbow != 0 else { continue }
                found += 1
                XCTAssertTrue(TreeLayout.limbElbow.contains(abs(elbow) * 180 / .pi), name)
            }
        }
        let share = Double(found) / Double(names.count * 10)
        XCTAssertEqual(share, TreeLayout.limbElbowChance, accuracy: 0.04, "now and then, so a long limb has more")
    }

    func testABentBoughStillLeavesAtItsPlantingsHeading() {
        let heading = 1.4, length = 0.8
        let bend = TreeLayout.Bend(curl: -0.2, wave: 0.1)
        let straight = TreeLayout.bough(heading: heading, length: length)
        let bent = TreeLayout.bough(heading: heading, length: length, bend: bend)
        XCTAssertEqual(bent.count, straight.count)
        let first = atan2(bent[1].x - bent[0].x, bent[1].y - bent[0].y)
        XCTAssertEqual(first, atan2(straight[1].x - straight[0].x, straight[1].y - straight[0].y), accuracy: 1e-5,
                       "it leaves as its planting says")
        XCTAssertEqual(first, heading, accuracy: 0.01)
        XCTAssertLessThan(hypot(bent[3].x - straight[3].x, bent[3].y - straight[3].y), 1e-6, "and only bends further out")
        let a = bent[bent.count - 2], b = bent[bent.count - 1], c = straight[straight.count - 2], d = straight[straight.count - 1]
        XCTAssertEqual(atan2(b.x - a.x, b.y - a.y) - atan2(d.x - c.x, d.y - c.y), bend.turn(at: 1), accuracy: 0.01,
                       "by its tip it's turned by its bend")
    }

    func testALimbCurlsItsOwnSeededWay() {
        XCTAssertEqual(TreeLayout.curl(of: "feature/low", shuffle: 0), TreeLayout.curl(of: "feature/low", shuffle: 0))
        let curls = (0..<100).map { TreeLayout.curl(of: "feature/\($0)", shuffle: 0) }
        for curl in curls { XCTAssertTrue(TreeLayout.limbCurl.contains(abs(curl) * 180 / .pi)) }
        XCTAssertTrue(curls.contains { $0 > 0 } && curls.contains { $0 < 0 }, "either way")
    }
}

// MARK: Knots

extension TreeLayoutTests {
    func testSomeElbowsHaveAKnotSeededByTheirName() {
        var elbows = 0, knotted = 0
        for index in 0..<400 {
            let bend = TreeLayout.Bend("repo\(index)", shuffle: 0, side: 1, length: 1.6)
            XCTAssertEqual(bend.elbows.map(\.knot), TreeLayout.Bend("repo\(index)", shuffle: 0, side: 1, length: 1.6).elbows.map(\.knot))
            for elbow in bend.elbows {
                elbows += 1
                if elbow.knot > 0 {
                    knotted += 1
                    XCTAssertTrue(TreeLayout.knotSize.contains(elbow.knot))
                }
            }
        }
        XCTAssertEqual(Double(knotted) / Double(elbows), TreeLayout.boughKnotChance, accuracy: 0.05, "\(knotted) of \(elbows)")
        // A limb's, at its elbows.
        let sizes = (0..<2000).compactMap { TreeLayout.knot(of: "limb\($0)", shuffle: 0, step: 4) }
        XCTAssertEqual(Double(sizes.count) / 2000, TreeLayout.limbKnotChance, accuracy: 0.04)
        XCTAssertTrue(sizes.allSatisfy(TreeLayout.knotSize.contains))
        XCTAssertEqual(TreeLayout.knot(of: "limb7", shuffle: 0, step: 4), TreeLayout.knot(of: "limb7", shuffle: 0, step: 4))
    }

    func testAStemsKnotsSwellItsJointsAndStayPutAsItGrowsIn() {
        let limbs = (0..<30).map {
            RepoTree.Limb(name: "limb\($0)", commits: commits("l\($0)", 12), parent: .trunk(node: 20 + $0 * 6), isCheckedOut: false)
        }
        let tree = RepoTree(trunkName: "main", trunk: commits("t", 200), limbs: limbs, isTrunkCheckedOut: false)
        let full = TreeLayout(tree: tree, seed: "ash")
        let knots = full.stems.dropFirst().flatMap(\.knots)
        XCTAssertGreaterThan(knots.count, 10, "plenty of limbs, so some knots")
        for stem in full.stems.dropFirst() {
            for knot in stem.knots {
                let name = "\(stem.name ?? "?") at \(knot.index)"
                XCTAssertTrue(stem.curve.indices.dropFirst().contains(knot.index), name)
                XCTAssertTrue(TreeLayout.knotSize.contains(knot.size), name)
                XCTAssertEqual(abs(knot.side), 1, name)
                XCTAssertGreaterThan(stem.curve[knot.index].width, stem.curve[knot.index - 1].width, "\(name): at a swollen joint")
            }
        }
        for growIn in [0.3, 0.6, 0.9] {
            let partway = TreeLayout(tree: tree, seed: "ash", growIn: growIn)
            for stem in partway.stems {
                let whole = full.stems.first { $0.name == stem.name }!
                XCTAssertEqual(stem.knots, whole.knots.filter { $0.index < stem.curve.count }, "\(stem.name ?? "?") at \(growIn)")
            }
        }
    }
}
