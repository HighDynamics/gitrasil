import Foundation

/// A working-tree file's git status, for explorer decorations (design brief §7). Quieter and
/// coarser than a commit's `FileChangeKind`: it answers "what's pending on disk right now."
public enum WorkingFileStatus: Sendable, Equatable {
    case modified
    case added
    case deleted
    case renamed
    case untracked
    case conflicted

    /// Single-letter decoration for the filename.
    public var letter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        case .conflicted: return "!"
        }
    }
}
