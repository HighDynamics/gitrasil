import Foundation

/// One commit in the simplified history graph. Metadata only — enough to render a node and its
/// detail. Merge commits never appear here: every walk is first-parent, so a branch's history
/// collapses to its mainline (topology doc / engineering notes).
public struct CommitNode: Sendable, Equatable {
    public let sha: String
    public let shortSHA: String
    public let author: String
    /// Committer date, ISO-8601 (`%cI`). Kept as a string in the core; the UI formats it.
    public let date: String
    public let subject: String

    public init(sha: String, shortSHA: String, author: String, date: String, subject: String) {
        self.sha = sha
        self.shortSHA = shortSHA
        self.author = author
        self.date = date
        self.subject = subject
    }
}

/// A contiguous run of commits belonging to one branch, in ancestry order (newest first).
/// Commits are grouped by branch and never interleaved by timestamp across branches.
public struct GraphSegment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The current worktree's own commits. Drawn in the identity color; never truncated.
        case currentWorktree
        /// An intermediate branch between cw and trunk. Grey, labeled, truncatable.
        case intermediate(branch: String)
        /// Trunk's ahead-commits, drawn as a separate grey lane forking from the meeting commit.
        /// Grey, labeled, truncatable.
        case trunkAhead(branch: String)
        /// A branch the user revealed via "show other branches" — a cherry-pick source. Grey,
        /// labeled, truncatable.
        case revealed(branch: String)
    }

    /// Segments longer than this collapse to their tip by default (cw is exempt).
    public static let truncationThreshold = 5

    public let kind: Kind
    /// The full run, newest first. Always complete — truncation is a *view* concern, so the UI's
    /// expand/collapse state survives re-derives instead of being reset on every FSEvents tick.
    public let commits: [CommitNode]

    /// For a forking lane (trunk-ahead or revealed), the SHA of the commit its oldest commit forks
    /// from — where its lane rejoins the graph. `nil` for the cw spine and intermediates.
    public let forkBase: String?

    public init(kind: Kind, commits: [CommitNode], forkBase: String? = nil) {
        self.kind = kind
        self.commits = commits
        self.forkBase = forkBase
    }

    /// cw is never truncated; other segments truncate when longer than the threshold.
    public var isTruncatable: Bool {
        switch kind {
        case .currentWorktree: return false
        case .intermediate, .trunkAhead, .revealed: return commits.count > Self.truncationThreshold
        }
    }

    /// How many commits are hidden when this segment is shown collapsed (tip only).
    public var hiddenCount: Int { isTruncatable ? commits.count - 1 : 0 }

    /// The commits shown when collapsed by default: just the tip for a truncatable segment,
    /// otherwise the whole run. (Expanding to `commits` is UI state.)
    public var collapsedCommits: [CommitNode] { isTruncatable ? Array(commits.prefix(1)) : commits }

    /// The branch label to draw at this segment, if any.
    public var branchLabel: String? {
        switch kind {
        case .currentWorktree: return nil
        case .intermediate(let b), .trunkAhead(let b), .revealed(let b): return b
        }
    }
}

/// The derived, immutable structure of a worktree's simplified history graph. Part of the
/// larger `WorktreeSnapshot`; produced by `Derivations.historyGraph` and rendered as-is.
public struct HistoryGraph: Sendable, Equatable {
    /// The anchor — where cw, trunk, and any intermediate branches converge (`merge-base`).
    /// Always shown, never truncated. `nil` only for an empty repo.
    public let meetingCommit: CommitNode?

    /// Segments from tip toward base, in display (top-to-bottom) order: the cw segment first,
    /// then each intermediate branch down toward the meeting commit. Empty segments are omitted.
    public let segments: [GraphSegment]

    /// Trunk's ahead-commits as a separate grey fork lane off the meeting commit, when trunk is
    /// ahead; `nil` when trunk is not ahead.
    public let trunkAhead: GraphSegment?

    /// Branches the user revealed via "show other branches" — additional grey lanes whose commits
    /// are cherry-pick sources (design brief §5).
    public let revealedLanes: [GraphSegment]

    /// How many intermediate branches sit between cw and trunk (drives the "N between" pill).
    public let branchesBetween: Int

    /// Empty repository (no commits yet) → the "No commits yet" state.
    public let isEmpty: Bool

    /// cw is in detached HEAD → the tab shows `[HEAD]` with no branch name; mutations disabled.
    public let isDetached: Bool

    /// cw's checked-out branch *is* the trunk — a degenerate, no-divergence state.
    public let isOnTrunk: Bool

    /// Working tree has uncommitted changes → the tip renders as an open circle.
    public let hasUncommittedChanges: Bool

    public init(
        meetingCommit: CommitNode?,
        segments: [GraphSegment],
        trunkAhead: GraphSegment?,
        revealedLanes: [GraphSegment] = [],
        branchesBetween: Int,
        isEmpty: Bool,
        isDetached: Bool,
        isOnTrunk: Bool,
        hasUncommittedChanges: Bool
    ) {
        self.meetingCommit = meetingCommit
        self.segments = segments
        self.trunkAhead = trunkAhead
        self.revealedLanes = revealedLanes
        self.branchesBetween = branchesBetween
        self.isEmpty = isEmpty
        self.isDetached = isDetached
        self.isOnTrunk = isOnTrunk
        self.hasUncommittedChanges = hasUncommittedChanges
    }

    /// The empty-repository graph.
    public static let empty = HistoryGraph(
        meetingCommit: nil, segments: [], trunkAhead: nil, revealedLanes: [], branchesBetween: 0,
        isEmpty: true, isDetached: false, isOnTrunk: false, hasUncommittedChanges: false)
}
