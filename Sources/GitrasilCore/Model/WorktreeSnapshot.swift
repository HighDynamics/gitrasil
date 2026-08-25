import Foundation

/// What branch identity a worktree tab shows (design brief §1).
public enum BranchIdentity: Sendable, Equatable {
    /// A normal checked-out branch.
    case branch(String)
    /// Detached HEAD — the tab shows `detached @ <sha>` instead of a branch name.
    case detached(shortSHA: String)

    public var name: String? {
        if case .branch(let n) = self { return n } else { return nil }
    }
}

/// A halted local operation, detected from the worktree's git dir (engineering notes →
/// in-progress detection). Drives the Conflicted badge and the continue/abort bar; because the
/// user may continue or abort from the terminal, this is derived from the filesystem, not from
/// whichever button was pressed.
public enum InProgressOperation: Sendable, Equatable {
    case rebase
    case cherryPick
    case merge
}

/// The derived, immutable state of a single worktree — everything a worktree tab renders from.
/// Produced by `Derivations.worktreeSnapshot` and published as-is to the (future) SwiftUI store;
/// the UI never mutates it, and every git change flows back in as a fresh snapshot
/// (architecture decision #2, derive-and-publish).
public struct WorktreeSnapshot: Sendable, Equatable {
    /// The tab's branch (or detached) identity.
    public let branch: BranchIdentity

    /// The raw status booleans (dirty / behind / in-progress) behind the badge — kept so the UI
    /// can explain *why* a badge shows and connect e.g. the amber badge to the dirty state.
    public let statusFacts: WorktreeStatusFacts

    /// The simplified history graph.
    public let graph: HistoryGraph

    /// A halted operation, if any (continue/abort bar visible while non-nil).
    public let inProgress: InProgressOperation?

    public init(
        branch: BranchIdentity,
        statusFacts: WorktreeStatusFacts,
        graph: HistoryGraph,
        inProgress: InProgressOperation?
    ) {
        self.branch = branch
        self.statusFacts = statusFacts
        self.graph = graph
        self.inProgress = inProgress
    }

    /// The single highest-priority badge to show on the tab, or nil when clean.
    public var badge: StatusBadge? { statusFacts.badge }

    /// Whether the worktree is in detached HEAD.
    public var isDetached: Bool {
        if case .detached = branch { return true } else { return false }
    }
}
