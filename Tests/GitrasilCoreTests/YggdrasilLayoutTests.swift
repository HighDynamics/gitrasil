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
            RepoTree.Limb(name: "\(prefix)/high", commits: commits("\(prefix)h", 3), parent: .trunk(node: trunk - 2), isCheckedOut: true)
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
        let limbs = (0..<9).map {
            RepoTree.Limb(name: "b\($0)", commits: commits("c\($0)", 2), parent: .trunk(node: 8 + $0 * 3), isCheckedOut: false)
        }
        let tree = RepoTree(trunkName: "main", trunk: commits("t", 40), limbs: limbs, isTrunkCheckedOut: false)
        XCTAssertGreaterThan(TreeLayout.sides(tree, outward: -1).filter { $0 < 0 }.count, 5)
        XCTAssertGreaterThan(TreeLayout.sides(tree, outward: 1).filter { $0 > 0 }.count, 5)
    }

    func testACommitInOneRepositoryLeavesTheOtherBoughsAlone() {
        let before = layout(ashLimbCommits: 4), after = layout(ashLimbCommits: 5)
        XCTAssertEqual(points(after, bough: 1), points(before, bough: 1))
        XCTAssertEqual(after.trunk.nodes.map(\.point), before.trunk.nodes.map(\.point))
        // The shared trunk thickens a hair, and a bough as wide as the trunk (oak) stands against its edge, so
        // it settles by no more than half of that and keeps its shape.
        let thickened = Double(after.trunk.nodes[0].width - before.trunk.nodes[0].width)
        XCTAssertGreaterThan(thickened, 0)
        let (oakBefore, oakAfter) = (points(before, bough: 2).flatMap { $0 }, points(after, bough: 2).flatMap { $0 })
        XCTAssertEqual(oakBefore.count, oakAfter.count)
        let shift = zip(oakBefore, oakAfter).map { Double(hypot($0.x - $1.x, $0.y - $1.y)) }
        XCTAssertLessThanOrEqual(shift.max()!, thickened / 2 + 1e-9, "oak settles by less than the trunk thickened")
        XCTAssertLessThan(shift.max()! - shift.min()!, 1e-9, "oak moves as a whole")
        XCTAssertEqual(after.boughs[0].layout.stems[1].nodes.count, 6, "ash's limb grew a step")
    }

    func testAReshuffleMovesTheBoughsButKeepsThemInPinOrder() {
        let repos: [YggdrasilLayout.Repo] = [.init(name: "ash", tree: tree("a")), .init(name: "elm", tree: tree("e", trunk: 12)),
                                             .init(name: "oak", tree: tree("o", trunk: 60))]
        let first = layout()
        XCTAssertEqual(YggdrasilLayout(repos: repos, shuffle: 0).trunk.nodes, first.trunk.nodes)
        let a = YggdrasilLayout(repos: repos, shuffle: 4242), b = YggdrasilLayout(repos: repos, shuffle: 4242)
        XCTAssertEqual(a.trunk.nodes, b.trunk.nodes)
        for bough in 0..<3 { XCTAssertEqual(points(a, bough: bough), points(b, bough: bough), "the same seed, the same shape") }
        XCTAssertNotEqual(a.trunk.nodes.map(\.point), first.trunk.nodes.map(\.point), "the shared trunk sways differently")
        XCTAssertEqual(a.boughs.map(\.name), ["ash", "elm", "oak"])
        let headings = a.boughs.map(\.planting.heading)
        XCTAssertEqual(headings, headings.sorted(), "still fanned left to right in pin order")
        for bough in 0..<3 {
            XCTAssertNotEqual(points(a, bough: bough), points(first, bough: bough))
            XCTAssertEqual(a.boughs[bough].layout.stems.map(\.nodes.count), first.boughs[bough].layout.stems.map(\.nodes.count))
        }
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

    func testTheSharedTrunkRisesFirstThenTheBoughsGrowFromTheCrotch() {
        let repos: [YggdrasilLayout.Repo] = [.init(name: "ash", tree: tree("a"), growIn: 0), .init(name: "elm", tree: tree("e"), growIn: 0)]
        let rising = YggdrasilLayout(repos: repos, trunkGrowIn: 0.5)
        XCTAssertEqual(Double(rising.trunk.nodes.last!.point.y), YggdrasilLayout.crotchHeight / 2, accuracy: 1e-9)
        XCTAssertTrue(rising.boughs.allSatisfy { $0.layout.stems.allSatisfy { $0.nodes.count <= 1 } }, "the boughs wait")
        let full = layout()
        let grown = YggdrasilLayout(repos: [.init(name: "ash", tree: tree("a"), growIn: 1), .init(name: "elm", tree: tree("e", trunk: 12), growIn: 1),
                                            .init(name: "oak", tree: tree("o", trunk: 60), growIn: 1)], trunkGrowIn: 1)
        XCTAssertEqual(grown.trunk.nodes, full.trunk.nodes)
        for bough in 0..<3 { XCTAssertEqual(points(grown, bough: bough), points(full, bough: bough)) }
        XCTAssertEqual(grown.bounds, full.bounds)
    }

    // MARK: every base grows out of wood

    /// Repositories like a real pin list: mostly bare trunks of a few to fifty-odd commits, a few with branches.
    /// `huge` lists the repositories that dwarf the rest (hundreds of commits), standing where the fan is widest, say.
    private func repos(_ count: Int, huge: Set<Int> = []) -> [YggdrasilLayout.Repo] {
        let sizes = [1, 5, 12, 30, 56, 2, 20, 8]
        return (0..<count).map { index in
            let size = huge.contains(index) ? 400 : sizes[index % sizes.count]
            let wood = index % 6 == 5 ? tree("r\(index)", trunk: max(size, 6)) : RepoTree(
                trunkName: "main", trunk: commits("r\(index)t", size), limbs: [], isTrunkCheckedOut: false)
            return .init(name: "repo\(index)", tree: wood)
        }
    }

    /// The trunk's middle and width at height `y`, read straight off its nodes.
    private func trunkWood(at y: Double, in nodes: [TreeLayout.Node]) -> (x: Double, width: Double) {
        let i = nodes.indices.dropFirst().first { Double(nodes[$0].point.y) >= y } ?? nodes.count - 1
        let (a, b) = (nodes[i - 1], nodes[i])
        let f = (y - Double(a.point.y)) / (Double(b.point.y) - Double(a.point.y))
        return (Double(a.point.x) + (Double(b.point.x) - Double(a.point.x)) * f, Double(a.width) + (Double(b.width) - Double(a.width)) * f)
    }

    /// How far `point` is from the polyline through `curve`.
    private func distance(from point: CGPoint, to curve: [TreeLayout.Node]) -> Double {
        guard curve.count > 1 else { return curve.first.map { hypot($0.point.x - point.x, $0.point.y - point.y) } ?? .infinity }
        return zip(curve, curve.dropFirst()).map { a, b -> Double in
            let (dx, dy) = (b.point.x - a.point.x, b.point.y - a.point.y)
            let length = max(dx * dx + dy * dy, 1e-12)
            let t = min(max(((point.x - a.point.x) * dx + (point.y - a.point.y) * dy) / length, 0), 1)
            return hypot(a.point.x + dx * t - point.x, a.point.y + dy * t - point.y)
        }.min()!
    }

    func testEveryBoughStartsInsideTheSharedTrunkAtEveryCount() {
        for count in [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 16, 18, 20, 24, 28, 32, 48, 64] {
            // As pinned, and with the outermost boughs (then the middle one) huge beside the rest.
            let cases: [Set<Int>] = [[], [0, count - 1], [count / 2], [0]]
            for huge in cases {
                let layout = YggdrasilLayout(repos: repos(count, huge: huge), fit: .fitting(count: count))
                let crotch = layout.trunk.nodes.last!.point.y
                for bough in layout.boughs {
                    let base = bough.layout.stems[0].nodes[0]
                    let wood = trunkWood(at: Double(base.point.y), in: layout.trunk.nodes)
                    let message = "\(bough.name) of \(count), huge \(huge.sorted())"
                    XCTAssertGreaterThan(base.point.y, 0, message)
                    XCTAssertLessThanOrEqual(Double(base.point.y), Double(crotch), "\(message) isn't above the trunk's top")
                    // The whole base, not only its middle, is inside the trunk's width.
                    XCTAssertLessThanOrEqual(abs(Double(base.point.x) - wood.x) + Double(base.width) / 2, wood.width / 2 + 1e-9,
                                             "\(message) stands inside the trunk's width")
                }
            }
        }
    }

    func testEveryLimbStartsInsideItsParent() {
        for count in [1, 6, 12, 18, 20, 24, 32, 48, 64] {
            let layout = YggdrasilLayout(repos: repos(count), fit: .fitting(count: count))
            for bough in layout.boughs {
                for stem in bough.layout.stems where stem.level > 0 {
                    guard let base = stem.nodes.first, let fork = stem.fork, let parent = fork.parent else {
                        XCTFail("\(bough.name) \(stem.name ?? "") has no parent"); continue
                    }
                    let wood = bough.layout.stems[parent]
                    XCTAssertLessThan(distance(from: base.point, to: wood.nodes), max(wood.nodes[fork.node].width / 2, 1e-6),
                                      "\(bough.name) \(stem.name ?? "") grows out of \(wood.name ?? "its parent")")
                }
            }
        }
    }

    func testBoughsKeepToTheirSideOfTheTrunkAndTheirBasesStayPutWhileTheyGrowIn() {
        for count in [6, 12, 18, 20, 32, 48] {
            let layout = YggdrasilLayout(repos: repos(count), fit: .fitting(count: count))
            for bough in layout.boughs {
                // A tier, or a crown bough away from the middle of the fan: its tip is out on the side it leans to.
                let heading = bough.planting.heading
                guard abs(heading) > 20 * .pi / 180, let tip = bough.layout.stems[0].tip?.point else { continue }
                let middle = trunkWood(at: Double(bough.planting.foot.y), in: layout.trunk.nodes).x
                XCTAssertGreaterThan((Double(tip.x) - middle) * (heading < 0 ? -1 : 1), 0, "\(bough.name) of \(count) crosses the trunk")
            }
            // While the trunk is still rising (cut short of the crotch) the boughs' bases are where they will stand.
            let growing = YggdrasilLayout(repos: repos(count).map { .init(name: $0.name, tree: $0.tree, growIn: 0.5) }, trunkGrowIn: 0.3,
                                          fit: .fitting(count: count))
            XCTAssertLessThan(growing.trunk.nodes.last!.point.y, layout.trunk.nodes.last!.point.y, "the trunk is cut short")
            for (a, b) in zip(layout.boughs, growing.boughs) {
                XCTAssertEqual(a.layout.stems[0].nodes[0].point, b.layout.stems[0].nodes[0].point, "\(a.name) of \(count)")
            }
        }
    }

    // MARK: a tall trunk with tiers

    private func tall(_ count: Int) -> YggdrasilLayout { YggdrasilLayout(repos: repos(count), fit: .fitting(count: count)) }

    func testNoRepositoriesIsABareTrunk() {
        let layout = YggdrasilLayout(repos: [], fit: .fitting(count: 0))
        XCTAssertTrue(layout.boughs.isEmpty)
        XCTAssertEqual(layout.trunk.nodes.first?.point, .zero)
        XCTAssertFalse(layout.bounds.isNull)
    }

    func testARepositoryWithNoCommitsAmongTheTiersKeepsItsPlace() {
        var pinned = repos(12)
        pinned[2] = .init(name: "empty", tree: RepoTree(trunkName: "main", trunk: [], limbs: [], isTrunkCheckedOut: false))
        let layout = YggdrasilLayout(repos: pinned, fit: .fitting(count: 12))
        XCTAssertEqual(layout.boughs.map(\.name), pinned.map(\.name))
        XCTAssertTrue(layout.bounds.width.isFinite && layout.bounds.height.isFinite)
        let tiers = layout.boughs.prefix(YggdrasilLayout.Shape(count: 12).tiers).map(\.planting.foot.y)
        XCTAssertEqual(tiers, tiers.sorted(), "the tiers still climb in pin order")
    }

    func testAHandfulOfBoughsIsTheTreeAsItWas() {
        for count in 1...4 {
            let layout = tall(count)
            XCTAssertEqual(YggdrasilLayout.Shape(count: count).tiers, 0)
            XCTAssertEqual(layout.trunk.nodes.last!.point.y, YggdrasilLayout.crotchHeight, accuracy: 1e-12)
            let headings = layout.boughs.map(\.planting.heading)
            XCTAssertEqual(headings, headings.sorted(), "fanned left to right")
            for bough in layout.boughs {
                XCTAssertEqual(bough.planting.reach, 1, "\(bough.name) of \(count)")
                XCTAssertEqual(bough.planting.straighten, TreeLayout.boughStraighten, "\(bough.name) of \(count)")
                XCTAssertFalse(bough.planting.splay, "\(bough.name) of \(count)")
            }
        }
    }

    func testTheTrunkGrowsTallerWithMoreBoughs() {
        let heights = [4, 5, 8, 12, 20, 32].map { Double(tall($0).trunk.nodes.last!.point.y) }
        for (a, b) in zip(heights, heights.dropFirst()) { XCTAssertGreaterThan(b, a, "\(heights)") }
        XCTAssertGreaterThan(heights.last!, heights.first! * 3, "a big tree is mostly trunk: \(heights)")
        // It stops growing somewhere, so the frame doesn't shrink the tree without end.
        XCTAssertEqual(Double(tall(64).trunk.nodes.last!.point.y), heights.last!, accuracy: 1e-12)
    }

    func testABigTreesBoughsLeaveAllAlongTheTrunkAlternatelyLeftAndRight() {
        for count in [8, 12, 20, 32] {
            let layout = tall(count), shape = YggdrasilLayout.Shape(count: count)
            let top = Double(layout.trunk.nodes.last!.point.y)
            XCTAssertGreaterThan(shape.tiers, shape.crown, "\(count): most boughs are tiers")
            XCTAssertLessThanOrEqual(shape.crown, 6, "\(count): the crown stays small")
            let tiers = layout.boughs.prefix(shape.tiers).map(\.planting)
            let feet = tiers.map { Double($0.foot.y) / top }
            XCTAssertEqual(feet, feet.sorted(), "\(count): pin order from the bottom up")
            XCTAssertLessThan(feet.first!, 0.4, "\(count): the lowest a third of the way up")
            XCTAssertGreaterThan(feet.last!, 0.8, "\(count): the highest near the top")
            for (index, tier) in tiers.enumerated() {
                XCTAssertEqual(tier.heading < 0, index % 2 == 0, "\(count): tier \(index) alternates sides")
            }
            for bough in layout.boughs.suffix(shape.crown) {
                // Its head, at least: a spread crown's outer feet stand down it (`YggdrasilLayout.footDrop`).
                XCTAssertGreaterThan(Double(bough.planting.foot.y), top - 0.25, "\(count): \(bough.name) fans from the top")
            }
        }
    }

    func testTiersReachOutNearlyLevel() {
        for count in [8, 20, 32] {
            let layout = tall(count), shape = YggdrasilLayout.Shape(count: count)
            for bough in layout.boughs.prefix(shape.tiers) {
                let planting = bough.planting
                XCTAssertGreaterThan(abs(planting.heading), 75 * .pi / 180, "\(bough.name) of \(count) leaves nearly level")
                XCTAssertLessThan(abs(planting.heading), 95 * .pi / 180, "\(bough.name) of \(count) droops only a little")
                XCTAssertLessThan(planting.straighten, TreeLayout.boughStraighten / 2, "\(bough.name) of \(count) keeps its lean")
                XCTAssertGreaterThan(planting.reach, 1, "\(bough.name) of \(count) reaches further than its tree would")
                let foot = bough.layout.stems[0].nodes[0].point, tip = bough.layout.stems[0].tip!.point
                XCTAssertGreaterThan(abs(Double(tip.x - foot.x)), 2 * abs(Double(tip.y - foot.y)),
                                     "\(bough.name) of \(count) runs out much further than it rises")
            }
        }
    }

    func testABigTreeIsWiderThanTall() {
        for count in [12, 20, 32] {
            let layout = tall(count)
            XCTAssertGreaterThan(Double(layout.bounds.width), Double(layout.bounds.maxY), "\(count)")
        }
    }

    func testTheSharedTrunkTapersAsTheTiersLeaveIt() {
        let widths = tall(32).trunk.nodes.map { Double($0.width) }
        for (a, b) in zip(widths, widths.dropFirst()) { XCTAssertGreaterThanOrEqual(a, b - 1e-12) }
        XCTAssertGreaterThan(widths.first!, widths.last! * 1.5)
    }

    func testTheSharedTrunkThickensWithTheTree() {
        let widths = [12, 32, 64].map { tall($0).trunk.nodes[0].width }
        XCTAssertEqual(widths, widths.sorted(), "\(widths)")
        XCTAssertGreaterThan(widths.last!, widths.first! * 1.4)
    }

    func testATallTreeStaysSlim() {
        // Its boughs are thin, and its trunk only a little thicker than four boughs' fan, even with 64.
        let small = tall(4), big = tall(64)
        XCTAssertLessThanOrEqual(Double(big.trunk.nodes[0].width), Double(small.trunk.nodes[0].width) * 1.25)
        XCTAssertTrue(small.boughs.allSatisfy { $0.planting.girth == 1 })
        for bough in big.boughs {
            XCTAssertEqual(bough.planting.girth, YggdrasilLayout.boughGirth)
            let foot = TreeLayout.footWidth(repos(64)[Int(bough.name.dropFirst(4))!].tree)
            XCTAssertEqual(Double(bough.layout.stems[0].nodes[0].width), foot * YggdrasilLayout.boughGirth, accuracy: 1e-9,
                           bough.name)
        }
    }

    func testATallTreeIsTheSameEveryTime() {
        for count in [20, 48] {
            let a = YggdrasilLayout(repos: repos(count), shuffle: 7, fit: .fitting(count: count))
            let b = YggdrasilLayout(repos: repos(count), shuffle: 7, fit: .fitting(count: count))
            XCTAssertEqual(a.trunk.nodes, b.trunk.nodes)
            XCTAssertEqual(a.bounds, b.bounds)
            XCTAssertEqual(a.boughs.map(\.planting), b.boughs.map(\.planting))
            for bough in 0..<count { XCTAssertEqual(points(a, bough: bough), points(b, bough: bough), "\(count), bough \(bough)") }
        }
    }
}
