import CoreGraphics
import GitrasilCore

/// What the background does when the settings that decide which repositories are shown, and where, change
/// (docs/tree-capacity/PLAN.md): read more or fewer of them, and grow the scene again once, and only if
/// something on screen moves.
struct SettingsReaction: Equatable {

    /// The settings that decide it.
    struct Choices: Equatable {
        var arrangement: Arrangement
        var forest: ForestMode
        var treeCapacity: Int?

        /// The policy these choices make.
        var policy: ForestPolicy { ForestPolicy.standard.choosing(treeCapacity: treeCapacity) }

        /// The most repositories shown: a dozen (`ForestPolicy.plainLimit`), or with the Forest on as many as the
        /// policy allows. A single tree set to hold fewer than a dozen shows no more than that without the Forest.
        var paneLimit: Int {
            forest == .off ? policy.shownWithoutForest(singleTree: arrangement == .singleTree) : policy.paneLimit
        }
    }

    /// How the whole scene grows again.
    enum Growth: Equatable {
        /// At once, from the bare ground (a new arrangement).
        case fromTheGround
        /// Once every pane has read its tree (`BackgroundModel.regrow`).
        case afterReading
    }

    /// The new limit on the repositories shown, when it moved: the panes are matched to it before the scene grows.
    var limit: Int?
    var growth: Growth?

    /// The reaction to `new` choices after `old` ones, with `limit` the pane limit now, `shown` panes on the screen,
    /// `ready` of them with a tree, and the sizes of the displays the tree stands on.
    static func to(_ new: Choices, after old: Choices, limit: Int, shown: Int, ready: Int, screens: [CGSize]) -> SettingsReaction {
        let newLimit = new.paneLimit
        // Repositories dropped move every tree that's left; ones added arrive as trees and grow in as they do.
        let dropped = newLimit != limit && shown > newLimit
        let growth: Growth?
        if new.arrangement != old.arrangement {
            growth = .fromTheGround
        } else if new.forest != old.forest || dropped || movesTrees(new, after: old, ready: ready, screens: screens) {
            growth = .afterReading
        } else {
            growth = nil
        }
        return SettingsReaction(limit: newLimit == limit ? nil : newLimit, growth: growth)
    }

    /// Whether a new tree capacity changes how `ready` repositories are split between the tree and the forest on
    /// any display: only in the single tree, and only with the Forest on (off, the tree holds everyone shown).
    private static func movesTrees(_ new: Choices, after old: Choices, ready: Int, screens: [CGSize]) -> Bool {
        guard new.treeCapacity != old.treeCapacity, new.arrangement == .singleTree, new.forest != .off else { return false }
        return screens.contains { min(ready, old.policy.treeCapacity(for: $0)) != min(ready, new.policy.treeCapacity(for: $0)) }
    }
}
