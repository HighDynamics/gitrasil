import Foundation

/// The tab status badge (design brief §2). Exactly one shows at a time; a clean worktree shows none.
/// Precedence is Conflicted > Modified > Behind.
public enum StatusBadge: String, Sendable, CaseIterable {
    case conflicted = "!"
    case modified = "M"
    case behind = "↓"
}

/// The raw booleans a status derivation produces from git, before precedence is applied.
public struct WorktreeStatusFacts: Sendable, Equatable {
    /// An operation (rebase/cherry-pick/merge) is paused with conflicts.
    public var inProgress: Bool
    /// Working tree has uncommitted changes (`status --porcelain` non-empty).
    public var dirty: Bool
    /// Trunk is ahead of the meeting commit (a rebase onto trunk is available).
    public var behind: Bool

    public init(inProgress: Bool = false, dirty: Bool = false, behind: Bool = false) {
        self.inProgress = inProgress
        self.dirty = dirty
        self.behind = behind
    }

    /// Collapse the facts to the single highest-priority badge, or nil when clean.
    public var badge: StatusBadge? {
        if inProgress { return .conflicted }
        if dirty { return .modified }
        if behind { return .behind }
        return nil
    }
}
