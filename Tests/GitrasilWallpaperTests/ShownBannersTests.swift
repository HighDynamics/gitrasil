import XCTest
import SwiftUI
import GitrasilCore
@testable import GitrasilWallpaper

/// How far each name has faded in as the trees grow in (`WallpaperView.shownBanners`).
@MainActor
final class ShownBannersTests: XCTestCase {

    private let date = Date(timeIntervalSince1970: 1000)

    /// A plan with a pennant on each of `panes`' trees, painted in that order; the `hidden` ones are behind
    /// what's painted in front of them.
    private func plan(_ panes: [String], hidden: Set<String>) -> BannerPlan {
        var plan = BannerPlan()
        plan.places = Dictionary(uniqueKeysWithValues: panes.enumerated().map { ($1, $0) })
        let hook = CGPoint(x: 100, y: 100), stretch = limbStretch()
        plan.banners = panes.map { pane in
            let banner = BannerLayout.Banner(id: "\(pane)\u{1F}main", tip: hook, hook: hook,
                                             rect: BannerLayout.pennant(at: hook, side: 1, size: CGSize(width: 60, height: 20)), side: 1)
            return BannerPlan.Hanging(banner: banner, pane: pane, stem: "main", stretch: stretch,
                                      name: "main", ink: .black, alpha: 1, fontSize: 12, hiddenFrom: hidden.contains(pane) ? 0 : nil)
        }
        return plan
    }

    /// A low limb's stretch of its tree's grow-in: its name is all there well before the end.
    private func limbStretch() -> TreeLayout.Stretch {
        func commits(_ prefix: String, _ count: Int) -> [RepoTree.Commit] {
            (0..<count).map { RepoTree.Commit(sha: "\(prefix)\($0)", date: Date(timeIntervalSince1970: Double($0))) }
        }
        let tree = RepoTree(trunkName: "main", trunk: commits("t", 160),
                            limbs: [RepoTree.Limb(name: "low", commits: commits("l", 2), parent: .trunk(node: 10), isCheckedOut: false)],
                            isTrunkCheckedOut: false)
        let stretch = TreeLayout(tree: tree, seed: "ash").schedule.stretch(of: "low")!
        XCTAssertEqual(stretch.nameShown(at: 0.5), 1)
        return stretch
    }

    /// Each pane's pennant as shown with the trees `growingIn` this far, by pane.
    private func shown(_ plan: BannerPlan, growingIn: [String: Double]) -> [String: Double] {
        let panes = plan.places.keys.sorted().map { WallpaperModel(repoURL: URL(fileURLWithPath: $0)) }
        return WallpaperView.shownBanners(plan, panes: panes, at: date) { url, _ in growingIn[url.path] }
            .reduce(into: [:]) { $0[String($1.key.split(separator: "\u{1F}")[0])] = $1.value }
    }

    func testAHiddenNameWaitsForTheTreesInFrontOfItsOwn() {
        let plan = plan(["/back", "/middle", "/front"], hidden: ["/middle"])
        XCTAssertEqual(shown(plan, growingIn: ["/back": 0.9, "/middle": 0.9, "/front": 0.9])["/middle"], 0,
                       "the tree in front still has leaves to come where it would show holes")
        XCTAssertEqual(shown(plan, growingIn: ["/middle": 0.96, "/front": 0.96])["/middle"] ?? -1, 0.5, accuracy: 1e-9,
                       "it fades in as the tree in front finishes")
        XCTAssertEqual(shown(plan, growingIn: ["/back": 0, "/middle": 0.95])["/middle"], 1,
                       "a tree behind it can't make holes in it, so it doesn't wait for that")
        XCTAssertEqual(shown(plan, growingIn: ["/back": 0.95, "/front": 0])["/back"], 1, "a name in view doesn't wait")
    }

    func testAHiddenNameAlreadyShownStaysWhenATreeArrivesLate() {
        let plan = plan(["/middle", "/front", "/late"], hidden: ["/middle"])
        XCTAssertEqual(shown(plan, growingIn: ["/middle": 0.96, "/front": 0.99, "/late": 0])["/middle"] ?? -1, 0.875, accuracy: 1e-9,
                       "it waits for the tree in front that began before it, not the one only now beginning")
        XCTAssertEqual(shown(plan, growingIn: ["/middle": 0, "/front": 0, "/late": 0])["/middle"], 0,
                       "trees beginning together wait for each other")
    }
}
