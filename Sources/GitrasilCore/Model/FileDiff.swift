import Foundation

/// Which baseline a file diff is computed against (design brief §6, engineering notes → Diff
/// computation). The four sources differ only in the two endpoints git diffs.
public enum DiffSource: Sendable, Equatable {
    /// Explorer-opened: the branch's split anchor (meeting base) → working tree, incl. uncommitted.
    case explorer(meetingBase: String)
    /// Commit-opened: the diff a single commit introduced (its parent → the commit).
    case commit(sha: String, shortSHA: String)
    /// Range-opened: the aggregate/squashed diff across a contiguous range.
    case range(oldest: String, newest: String, newestShort: String)
    /// "Diff against…" override: an arbitrary commit → working tree.
    case against(ref: String)
}

/// A computed, view-only file diff: the unified-diff text git produced, plus render hints. We
/// render git's own output rather than diffing ourselves; heavy or binary cases hand off to an
/// external tool.
public struct FileDiff: Sendable, Equatable {
    public let path: String
    /// git's unified-diff text (empty when there is no change).
    public let unifiedText: String
    /// True when git reported a binary difference (no textual hunks to show).
    public let isBinary: Bool
    /// Human-readable source label, e.g. "base → working tree" or "parent → a1b2c3d".
    public let label: String

    public init(path: String, unifiedText: String, isBinary: Bool, label: String) {
        self.path = path
        self.unifiedText = unifiedText
        self.isBinary = isBinary
        self.label = label
    }

    /// No textual change (identical, or reverted within a range).
    public var isEmpty: Bool { !isBinary && unifiedText.isEmpty }
}
