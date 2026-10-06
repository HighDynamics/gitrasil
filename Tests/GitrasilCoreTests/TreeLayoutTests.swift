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
}
