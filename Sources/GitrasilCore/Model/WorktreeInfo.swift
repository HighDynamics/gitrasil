import Foundation

/// One entry from `git worktree list` — a checkout of the repository on disk. The repository's
/// original checkout is the *main* worktree; each `git worktree add` creates a *linked* one. The
/// app shows one tab per worktree (README: "one tab = one worktree").
public struct WorktreeInfo: Sendable, Identifiable, Hashable {
    /// Absolute path to the worktree directory. Also the stable identity (its `id`).
    public let path: URL
    /// HEAD commit SHA, or nil for a bare repository (which has no working tree).
    public let head: String?
    /// Short branch name, or nil when detached or bare.
    public let branch: String?
    /// The bare repository entry (no working tree) — never shown as a worktree tab.
    public let isBare: Bool
    /// HEAD is detached (no branch checked out).
    public let isDetached: Bool
    /// The worktree is locked (`git worktree lock`) — removal is blocked until unlocked.
    public let isLocked: Bool
    /// True for the repository's original checkout (the first entry `git worktree list` reports).
    public let isMain: Bool

    public var id: URL { path }

    /// The directory name — the tab's short label when there's no better one.
    public var name: String { path.lastPathComponent }

    public init(path: URL, head: String?, branch: String?, isBare: Bool,
                isDetached: Bool, isLocked: Bool, isMain: Bool) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isMain = isMain
    }
}
