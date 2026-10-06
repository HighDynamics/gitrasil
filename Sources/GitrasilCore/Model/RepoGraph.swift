import Foundation

/// A repository's history as the background draws it (`Derivations.repoGraph`): the trunk's recent
/// first-parent history, and the recently active branches forking off it or off each other. Every walk is first-parent, so merges collapse to their branch's mainline. `RepoTree`
/// reorganizes it by where each branch forks.
public struct RepoGraph: Sendable, Equatable {

    public struct Commit: Sendable, Equatable {
        public let sha: String
        /// The committer date.
        public let date: Date
        public let subject: String

        public init(sha: String, date: Date, subject: String) {
            self.sha = sha
            self.date = date
            self.subject = subject
        }
    }

    /// A branch with its own commits: the ones not on the trunk or on another branch drawn before it.
    public struct Branch: Sendable, Equatable {
        public let name: String
        /// Newest first.
        public let commits: [Commit]
        /// The commit its oldest commit forks from (on the trunk, another branch, or older than
        /// anything drawn), if it has a parent.
        public let forkBase: String?

        public init(name: String, commits: [Commit], forkBase: String?) {
            self.name = name
            self.commits = commits
            self.forkBase = forkBase
        }
    }

    /// The branch (or ref) the trunk follows; nil for an empty repository.
    public let trunkName: String?
    /// The trunk's recent first-parent commits, newest first. The oldest is where branches whose
    /// fork lies further back join.
    public let trunk: [Commit]
    public let branches: [Branch]
    /// Branches with no commits of their own, keyed by the drawn commit their tip sits on.
    public let buds: [String: [String]]
    /// Branches checked out in some worktree of the repository.
    public let checkedOutBranches: Set<String>

    public init(trunkName: String?, trunk: [Commit], branches: [Branch], buds: [String: [String]] = [:],
                checkedOutBranches: Set<String> = []) {
        self.trunkName = trunkName
        self.trunk = trunk
        self.branches = branches
        self.buds = buds
        self.checkedOutBranches = checkedOutBranches
    }

    /// No commits yet.
    public var isEmpty: Bool { trunk.isEmpty }

    public static let empty = RepoGraph(trunkName: nil, trunk: [], branches: [])
}
