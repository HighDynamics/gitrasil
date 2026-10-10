import XCTest
import GitrasilCore
@testable import GitrasilWallpaper

/// How many repositories stand on the single tree and where the rest go (docs/tree-capacity/PLAN.md).
@MainActor
final class TreeCapacityTests: XCTestCase {

    private let laptop = CGSize(width: 1440, height: 900)
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// `count` repositories, pinned in the order p00, p01, …; p00 is the oldest, the last the newest.
    private func panes(_ count: Int) -> [Pane] {
        (0..<count).map { index in
            let name = String(format: "p%02d", index)
            let date = now.addingTimeInterval(Double(index - count) * 3 * day)
            let tree = RepoTree(trunkName: "main", trunk: [RepoTree.Commit(sha: name, date: date)], limbs: [], isTrunkCheckedOut: false)
            return Pane(id: "/repos/\(name)", name: name, seed: name, tree: tree)
        }
    }

    private func landscape(forest: ForestMode = .auto, capacity: Int? = nil, ranking: [String: Date] = [:]) -> Landscape {
        Landscape(style: .make(.chalk, dark: false), now: now, size: laptop, shuffle: 0, trunkGrowIn: nil, forest: forest,
                  policy: ForestPolicy().choosing(treeCapacity: capacity), ranking: ranking)
    }

    private func names(_ panes: [Pane]) -> [String] { panes.map(\.name) }

    func testTheDefaultKeepsTheDisplaysNumberOnTheTree() {
        let scene = landscape().scene(panes(30), arrangement: .singleTree)
        XCTAssertEqual(scene.tree.count, 12, "a dozen on a 900 pt display, as before the setting")
        XCTAssertEqual(scene.forest.count, 18)
        let tall = Landscape(style: .make(.chalk, dark: false), now: now, size: CGSize(width: 3440, height: 1440), shuffle: 0,
                             trunkGrowIn: nil, forest: .auto, policy: ForestPolicy().choosing(treeCapacity: nil))
        XCTAssertEqual(tall.scene(panes(30), arrangement: .singleTree).tree.count, 20)
    }

    func testAChosenNumberIsHowManyStayOnTheTree() {
        for capacity in ForestPolicy.treeCapacitySteps {
            let scene = landscape(capacity: capacity).scene(panes(40), arrangement: .singleTree)
            XCTAssertEqual(scene.tree.count, capacity)
            XCTAssertEqual(scene.forest.count, 40 - capacity, "the rest stand in the forest")
        }
    }

    func testTheMostRecentlyActiveStayAndTheRestGoToTheForestInPinOrder() {
        let scene = landscape(capacity: 8).scene(panes(20), arrangement: .singleTree)
        XCTAssertEqual(names(scene.tree), (12..<20).map { String(format: "p%02d", $0) }, "the newest eight, in pin order")
        XCTAssertEqual(names(scene.forest), (0..<12).map { String(format: "p%02d", $0) })
    }

    func testTheFrozenRankingDecidesNotTheLatestCommit() {
        // p00 has the oldest commit, but the ranking taken at launch had it the newest: it stays on the tree.
        let ranking = ["/repos/p00": now.addingTimeInterval(day)]
        let scene = landscape(capacity: 4, ranking: ranking).scene(panes(10), arrangement: .singleTree)
        XCTAssertEqual(names(scene.tree), ["p00", "p07", "p08", "p09"])
    }

    func testEnoughRoomPutsEveryoneOnTheTree() {
        let scene = landscape(capacity: 16).scene(panes(16), arrangement: .singleTree)
        XCTAssertEqual(scene.tree.count, 16)
        XCTAssertTrue(scene.forest.isEmpty)
    }

    func testWithoutTheForestTheTreeHoldsAllThatThePaneLimitShows() {
        // The pane limit cuts what's shown before the tree sees it, so the tree isn't split: 8 chosen shows 8, no
        // chosen number shows a dozen, and more than a dozen can't show without the Forest.
        for (capacity, shown) in [(8, 8), (nil, 12), (24, 12)] as [(Int?, Int)] {
            let settings = BackgroundSettings(storage: MemorySettings())
            settings.arrangement = .singleTree
            settings.treeCapacity = capacity
            XCTAssertEqual(BackgroundModel.paneLimit(for: settings), shown)
            let scene = landscape(forest: .off, capacity: capacity).scene(panes(40).prefix(shown).map { $0 }, arrangement: .singleTree)
            XCTAssertEqual(scene.tree.count, shown, "capacity \(capacity.map(String.init) ?? "automatic")")
            XCTAssertTrue(scene.forest.isEmpty)
        }
    }

    func testTheOrchardIgnoresTheSetting() {
        let scene = landscape(capacity: 4).scene(panes(10), arrangement: .orchard)
        XCTAssertTrue(scene.tree.isEmpty)
        XCTAssertTrue(scene.forest.isEmpty, "ten fit the orchard's plots")
    }

    // MARK: What a change of settings does

    private typealias Choices = SettingsReaction.Choices

    private func react(from old: Choices, to new: Choices, limit: Int? = nil, shown: Int, ready: Int? = nil,
                       screens: [CGSize]? = nil) -> SettingsReaction {
        SettingsReaction.to(new, after: old, limit: limit ?? old.paneLimit, shown: shown, ready: ready ?? shown,
                            screens: screens ?? [laptop])
    }

    func testNothingChangedGrowsNothing() {
        let same = Choices(arrangement: .singleTree, forest: .auto, treeCapacity: 8)
        XCTAssertEqual(react(from: same, to: same, shown: 40), SettingsReaction(limit: nil, growth: nil))
    }

    func testANewCapacityGrowsTheSceneOnceWhenTheSplitMoves() {
        let old = Choices(arrangement: .singleTree, forest: .auto, treeCapacity: nil)
        let reaction = react(from: old, to: Choices(arrangement: .singleTree, forest: .auto, treeCapacity: 8), shown: 40)
        XCTAssertEqual(reaction, SettingsReaction(limit: nil, growth: .afterReading), "the limit is 64 either way; one regrow")
    }

    func testANewCapacityThatMovesNothingGrowsNothing() {
        // Six repositories all stand on the tree whether it holds 12 or 8; and a laptop's tree holds 12 either way.
        let old = Choices(arrangement: .singleTree, forest: .auto, treeCapacity: nil)
        let eight = Choices(arrangement: .singleTree, forest: .auto, treeCapacity: 8)
        XCTAssertNil(react(from: old, to: eight, shown: 6).growth)
        XCTAssertNil(react(from: old, to: Choices(arrangement: .singleTree, forest: .auto, treeCapacity: 12), shown: 40).growth)
        // The orchard has no tree to hold them.
        let orchard = Choices(arrangement: .orchard, forest: .auto, treeCapacity: nil)
        XCTAssertEqual(react(from: orchard, to: Choices(arrangement: .orchard, forest: .auto, treeCapacity: 4), shown: 40),
                       SettingsReaction(limit: nil, growth: nil))
    }

    func testTheSplitCountsOnEveryDisplay() {
        let old = Choices(arrangement: .singleTree, forest: .auto, treeCapacity: nil)
        let sixteen = Choices(arrangement: .singleTree, forest: .auto, treeCapacity: 16)
        let tall = CGSize(width: 3440, height: 1440)
        // 14 repositories: a laptop's tree holds 12 and then 14, a tall display's 14 and then 14.
        XCTAssertEqual(react(from: old, to: sixteen, shown: 14, screens: [laptop]).growth, .afterReading)
        XCTAssertEqual(react(from: old, to: sixteen, shown: 14, screens: [laptop, tall]).growth, .afterReading)
        XCTAssertNil(react(from: old, to: sixteen, shown: 14, screens: [tall]).growth)
    }

    func testFewerOnTheTreeWithoutTheForestDropsRepositoriesAndGrowsOnce() {
        let old = Choices(arrangement: .singleTree, forest: .off, treeCapacity: nil)
        let reaction = react(from: old, to: Choices(arrangement: .singleTree, forest: .off, treeCapacity: 8), shown: 12)
        XCTAssertEqual(reaction, SettingsReaction(limit: 8, growth: .afterReading))
    }

    func testMoreOnTheTreeWithoutTheForestOnlyReadsTheNewOnes() {
        let old = Choices(arrangement: .singleTree, forest: .off, treeCapacity: 8)
        let reaction = react(from: old, to: Choices(arrangement: .singleTree, forest: .off, treeCapacity: nil), shown: 8)
        XCTAssertEqual(reaction, SettingsReaction(limit: 12, growth: nil), "they grow in as they arrive")
    }

    func testFlippingTheArrangementUnderADozenWithoutTheForestGrowsOnce() {
        let orchard = Choices(arrangement: .orchard, forest: .off, treeCapacity: 8)
        let tree = Choices(arrangement: .singleTree, forest: .off, treeCapacity: 8)
        XCTAssertEqual(react(from: orchard, to: tree, shown: 12), SettingsReaction(limit: 8, growth: .fromTheGround),
                       "the tree holds 8: four go, and one grow-in from the ground, not two")
        XCTAssertEqual(react(from: tree, to: orchard, shown: 8), SettingsReaction(limit: 12, growth: .fromTheGround))
    }

    func testTheForestComingAndGoingReadsMoreOrFewerAndGrowsOnce() {
        let off = Choices(arrangement: .singleTree, forest: .off, treeCapacity: nil)
        let on = Choices(arrangement: .singleTree, forest: .auto, treeCapacity: nil)
        XCTAssertEqual(react(from: off, to: on, shown: 12), SettingsReaction(limit: 64, growth: .afterReading))
        XCTAssertEqual(react(from: on, to: off, shown: 40), SettingsReaction(limit: 12, growth: .afterReading))
    }

    // MARK: How many are shown

    func testThePaneLimitWithoutTheForestIsADozenUnlessTheTreeHoldsFewer() {
        let settings = BackgroundSettings(storage: MemorySettings())
        settings.arrangement = .singleTree
        XCTAssertEqual(BackgroundModel.paneLimit(for: settings), 12, "the default is as it was")
        settings.treeCapacity = 8
        XCTAssertEqual(BackgroundModel.paneLimit(for: settings), 8)
        settings.treeCapacity = 24
        XCTAssertEqual(BackgroundModel.paneLimit(for: settings), 12, "more than a dozen needs the Forest")
        settings.arrangement = .orchard
        settings.treeCapacity = 4
        XCTAssertEqual(BackgroundModel.paneLimit(for: settings), 12, "the orchard has no tree to hold them")
    }

    func testThePaneLimitWithTheForestIsSixtyFourWhateverTheTreeHolds() {
        let settings = BackgroundSettings(storage: MemorySettings())
        settings.showsForest = true
        settings.arrangement = .singleTree
        for capacity in [nil, 4, 12, 24] {
            settings.treeCapacity = capacity
            XCTAssertEqual(BackgroundModel.paneLimit(for: settings), 64)
        }
    }
}
