import XCTest
@testable import GitrasilCore

final class YggdrasilLayoutTests: XCTestCase {

    private func commits(_ prefix: String, _ count: Int) -> [RepoTree.Commit] {
        (0..<count).map { RepoTree.Commit(sha: "\(prefix)\($0)", date: Date(timeIntervalSince1970: Double($0))) }
    }

    private func tree(_ prefix: String, trunk: Int = 30, limbCommits: Int = 4) -> RepoTree {
        let limbs = [
            RepoTree.Limb(name: "\(prefix)/low", commits: commits("\(prefix)l", limbCommits), parent: .trunk(node: 6), isCheckedOut: false),
            RepoTree.Limb(name: "\(prefix)/sub", commits: commits("\(prefix)s", 2), parent: .limb(index: 0, node: 2), isCheckedOut: false),
            RepoTree.Limb(name: "\(prefix)/high", commits: commits("\(prefix)h", 3), parent: .trunk(node: trunk - 2), isCheckedOut: true),
        ]
        return RepoTree(trunkName: "main", trunk: commits("\(prefix)t", trunk), limbs: limbs, isTrunkCheckedOut: false)
    }

    private func layout(ashLimbCommits: Int = 4) -> YggdrasilLayout {
        YggdrasilLayout(repos: [.init(name: "ash", tree: tree("a", limbCommits: ashLimbCommits)),
                                .init(name: "elm", tree: tree("e", trunk: 12)),
                                .init(name: "oak", tree: tree("o", trunk: 60))])
    }

    private func points(_ layout: YggdrasilLayout, bough: Int) -> [[CGPoint]] {
        layout.boughs[bough].layout.stems.map { $0.nodes.map(\.point) }
    }

    func testEachRepositoryIsABoughFromTheCrotchFannedInPinOrder() {
        let layout = layout()
        XCTAssertEqual(layout.boughs.map(\.name), ["ash", "elm", "oak"])
        XCTAssertEqual(layout.trunk.nodes.first?.point, .zero)
        let crotch = layout.trunk.nodes.last!.point
        let headings = layout.boughs.map(\.planting.heading)
        XCTAssertEqual(headings, headings.sorted(), "left to right")
        XCTAssertLessThan(headings[0], 0)
        XCTAssertGreaterThan(headings[2], 0)
        for bough in layout.boughs {
            let foot = bough.layout.stems[0].nodes[0].point
            XCTAssertLessThan(hypot(foot.x - crotch.x, foot.y - crotch.y), 0.05, "\(bough.name) leaves the crotch")
            XCTAssertGreaterThan(bough.layout.stems[0].tip!.point.y, foot.y, "\(bough.name) rises")
        }
    }

    func testABoughStraightensAsItRises() {
        let left = layout().boughs[0].layout.stems[0]
        XCTAssertLessThan(left.nodes.first!.heading, left.nodes.last!.heading, "leans out, then bends back up")
    }

    func testOuterBoughsGrowMostLimbsOutward() {
        let limbs = (0..<9).map { RepoTree.Limb(name: "b\($0)", commits: commits("c\($0)", 2), parent: .trunk(node: 8 + $0 * 3), isCheckedOut: false) }
        let tree = RepoTree(trunkName: "main", trunk: commits("t", 40), limbs: limbs, isTrunkCheckedOut: false)
        XCTAssertGreaterThan(TreeLayout.sides(tree, outward: -1).filter { $0 < 0 }.count, 5)
        XCTAssertGreaterThan(TreeLayout.sides(tree, outward: 1).filter { $0 > 0 }.count, 5)
    }

    func testACommitInOneRepositoryLeavesTheOtherBoughsAlone() {
        let before = layout(ashLimbCommits: 4), after = layout(ashLimbCommits: 5)
        XCTAssertEqual(points(after, bough: 1), points(before, bough: 1))
        XCTAssertEqual(points(after, bough: 2), points(before, bough: 2))
        XCTAssertEqual(after.trunk.nodes.map(\.point), before.trunk.nodes.map(\.point))
        XCTAssertEqual(after.boughs[0].layout.stems[1].nodes.count, 6, "ash's limb grew a step")
    }

    func testTheSharedTrunkCarriesEveryBough() {
        let layout = layout()
        let feet = layout.boughs.map { $0.layout.stems[0].nodes[0].width }
        XCTAssertGreaterThan(layout.trunk.nodes.last!.width, feet.max()!)
        XCTAssertGreaterThan(layout.trunk.nodes.first!.width, layout.trunk.nodes.last!.width)
    }

    func testAnUprightPlantingIsTheTreeOnItsOwn() {
        let a = TreeLayout(tree: tree("a"), seed: "ash")
        let b = TreeLayout(tree: tree("a"), seed: "ash", planting: .upright)
        XCTAssertEqual(a.stems.map(\.nodes), b.stems.map(\.nodes))
    }
}
