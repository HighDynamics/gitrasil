import SwiftUI
import GitrasilCore

/// The last banner plan a window made, kept until anything it was planned from changes. Planning
/// measures every banner against the whole crown, so it's too slow to redo on every redraw (a growth
/// starting or ending, a grow-in, the hourly tick).
final class PlanCache {
    struct Key: Equatable {
        // swiftlint:disable:next nesting - a helper of Key alone, nowhere else to put it
        struct Tree: Equatable {
            let id: String
            let tree: RepoTree?
        }

        let dark: Bool
        /// Each medium writes names in its own hand, so their banners are sized differently.
        let medium: Medium
        let size: CGSize
        let now: Date
        /// The trees' layout seed: a reshuffle moves every limb, and its banner with it.
        let shuffle: Int
        let arrangement: Arrangement
        let forest: ForestMode
        /// How many repositories the tree holds, when it is set (`ForestPolicy.fixedTreeCapacity`).
        let treeCapacity: Int?
        /// Which repositories stand on the tree and which in the forest.
        let ranking: [String: Date]
        let branchNames: Bool
        let repoNames: Bool
        let trees: [Tree]
    }

    private var key: Key?
    private var plan = BannerPlan()

    func plan(for key: Key, make: () -> BannerPlan) -> BannerPlan {
        if key != self.key {
            plan = make()
            self.key = key
        }
        return plan
    }
}

/// Where things sit on the screen, shared by the ground and every tree so they meet.
enum Composition {
    /// The ground line: high enough off the bottom to clear the Dock's usual reach.
    static func groundY(_ height: CGFloat) -> CGFloat { height - max(96, height * 0.13) }
    /// Clear of the menu bar.
    static let top: CGFloat = 44
    /// The height a full-grown tree is drawn for, crown included, in tree units (`TreeLayout`).
    static let nominalHeight = 1.45
    /// An orchard plot's width in tree units: the trees share one scale, so each is drawn as big as
    /// its own history makes it, and a crown a little wider than its plot reaches into the next.
    static let plotWidth = 1.3
}
