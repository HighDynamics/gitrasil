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

    func testWithoutTheForestEveryoneShownStaysOnTheTree() {
        // The pane limit has already cut what's shown (`paneLimit`): the tree isn't split.
        let scene = landscape(forest: .off, capacity: 8).scene(panes(12), arrangement: .singleTree)
        XCTAssertEqual(scene.tree.count, 12)
        XCTAssertTrue(scene.forest.isEmpty)
    }

    func testTheOrchardIgnoresTheSetting() {
        let scene = landscape(capacity: 4).scene(panes(10), arrangement: .orchard)
        XCTAssertTrue(scene.tree.isEmpty)
        XCTAssertTrue(scene.forest.isEmpty, "ten fit the orchard's plots")
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
