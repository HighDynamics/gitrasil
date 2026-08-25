import Foundation

/// The commit detail panel's content (design brief §5): metadata plus the files the commit
/// touched. For a range selection, `commit` is the range tip and `files` is the union across the
/// range (with net change types).
public struct CommitDetail: Sendable, Equatable {
    public let commit: CommitNode
    /// Full commit message (subject + body); empty body collapses to just the subject.
    public let fullMessage: String
    public let files: [FileChange]
    /// For a range selection: the number of commits in the span (1 for a single commit).
    public let commitCount: Int

    public init(commit: CommitNode, fullMessage: String, files: [FileChange], commitCount: Int = 1) {
        self.commit = commit
        self.fullMessage = fullMessage
        self.files = files
        self.commitCount = commitCount
    }
}
