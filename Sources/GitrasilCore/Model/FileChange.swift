import Foundation

/// How a file changed in a commit or range. Covers git's full status set including renames and
/// copies (design brief §5 lists A/M/D; git also emits R/C, which the panel must handle).
public enum FileChangeKind: Sendable, Equatable {
    case added
    case modified
    case deleted
    case renamed(from: String)
    case copied(from: String)

    /// Single-letter tag for the file list.
    public var letter: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        }
    }
}

/// One file touched by a commit or range, tagged by change type.
public struct FileChange: Sendable, Equatable {
    /// The current (new) path.
    public let path: String
    public let kind: FileChangeKind

    public init(path: String, kind: FileChangeKind) {
        self.path = path
        self.kind = kind
    }

    /// The prior path for a rename/copy, else nil.
    public var previousPath: String? {
        switch kind {
        case .renamed(let from), .copied(let from): return from
        default: return nil
        }
    }
}
