import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The numbers that decide how many repositories stand where (docs/forest/PLAN.md), each one a default
/// that's easy to change: here, or for a run with an environment variable.
public struct ForestPolicy: Sendable, Equatable {
    /// The most repositories the plain orchard shows; more stand in rows (GITRASIL_FOREST_PLAIN).
    public var plainLimit = 12
    /// The most repositories the background shows at all (GITRASIL_BACKGROUND_MAX_PANES).
    public var paneLimit = 64
    /// The repositories the single tree holds whatever the display (GITRASIL_TREE_CAPACITY), else
    /// `treeCapacity(for:)`.
    public var fixedTreeCapacity: Int?

    public init(plainLimit: Int = 12, paneLimit: Int = 64, fixedTreeCapacity: Int? = nil) {
        self.plainLimit = plainLimit
        self.paneLimit = paneLimit
        self.fixedTreeCapacity = fixedTreeCapacity
    }

    public static let standard: ForestPolicy = {
        let environment = ProcessInfo.processInfo.environment
        func number(_ key: String) -> Int? { environment[key].flatMap { Int($0) }.map { max($0, 1) } }
        return ForestPolicy(plainLimit: number("GITRASIL_FOREST_PLAIN") ?? 12, paneLimit: number("GITRASIL_BACKGROUND_MAX_PANES") ?? 64,
                            fixedTreeCapacity: number("GITRASIL_TREE_CAPACITY"))
    }()

    /// What the "Repos on the Tree" setting may be (docs/tree-capacity/PLAN.md): the menu offers these steps, and a
    /// saved number anywhere in their range is kept. Fewer than four is no tree; more than the tallest display's
    /// automatic number (24) crowds the names off the boughs.
    public static let treeCapacitySteps = [4, 8, 12, 16, 20, 24]
    public static let treeCapacityRange = 4...24

    /// This policy with the user's chosen number of repositories on the tree (`BackgroundSettings.treeCapacity`;
    /// nil, Automatic, leaves it be). A number from the environment (GITRASIL_TREE_CAPACITY) wins, for test runs.
    public func choosing(treeCapacity chosen: Int?) -> ForestPolicy {
        guard fixedTreeCapacity == nil, let chosen, Self.treeCapacityRange.contains(chosen) else { return self }
        var policy = self
        policy.fixedTreeCapacity = chosen
        return policy
    }

    /// The most repositories shown with the Forest off: a dozen, or fewer when the single tree is set to hold
    /// fewer (the cut is the pins' order, as for a dozen). The setting's number, not the display's.
    public func shownWithoutForest(singleTree: Bool) -> Int {
        singleTree ? min(plainLimit, fixedTreeCapacity ?? plainLimit) : plainLimit
    }

    /// How many repositories one tree holds before it stops reading well. The tree is as tall as the
    /// screen allows and its crown isn't wider than that, so the room for names grows with the display's
    /// height, not its width: 12 on a laptop's 900 points, 20 from 1440 up (an ultrawide or a 5K).
    public func treeCapacity(for size: CGSize) -> Int {
        if let fixedTreeCapacity { return fixedTreeCapacity }
        let grown = 12 + (Double(size.height) - 900) / 540 * 8
        return min(max(Int(grown.rounded()), 8), 24)
    }

    /// The repositories the single tree holds on a display of `size`: the most recently active ones.
    /// Indices into `entries`.
    public func onTree(_ entries: [(id: String, lastActive: Date)], size: CGSize) -> Set<Int> {
        Set(Self.rank(entries).prefix(treeCapacity(for: size)))
    }

    /// The order repositories stand in: the most recently active first, by the local day of the last commit
    /// (so two commits in a day don't swap places), then by name. Indices into `entries`. `calendar` says
    /// where a day begins and ends: the user's, unless a test pins one.
    public static func rank(_ entries: [(id: String, lastActive: Date)], calendar: Calendar = .current) -> [Int] {
        let days = entries.map { calendar.startOfDay(for: $0.lastActive) }
        return entries.indices.sorted { a, b in
            days[a] != days[b] ? days[a] > days[b] : entries[a].id < entries[b].id
        }
    }
}
