import Foundation

/// The repository's history as a tree: the trunk's first-parent history, and each drawn branch as a
/// limb growing off the trunk or off another limb. Built from the `RepoGraph`, so it carries the
/// same commits; it only reorganizes them by where each branch forks.
///
/// Node numbering, shared with `TreeLayout`: on every stem, node 0 is the base (the trunk's ground,
/// a limb's fork point) and node k is the k-th commit, oldest first.
public struct RepoTree: Sendable, Equatable {

    public struct Commit: Sendable, Equatable {
        public let sha: String
        public let date: Date

        public init(sha: String, date: Date) {
            self.sha = sha
            self.date = date
        }
    }

    /// Where a limb grows from.
    public enum Parent: Sendable, Equatable {
        /// The trunk, at node `node` (the trunk commit the branch forked from).
        case trunk(node: Int)
        /// Another limb (by index in `limbs`), at node `node`.
        case limb(index: Int, node: Int)
    }

    public struct Limb: Sendable, Equatable {
        public let name: String
        /// The branch's own commits (not on the trunk or another limb), oldest first. Empty for a bud:
        /// a branch whose tip sits on a commit already drawn.
        public let commits: [Commit]
        public let parent: Parent
        /// Checked out in some worktree.
        public let isCheckedOut: Bool

        public init(name: String, commits: [Commit], parent: Parent, isCheckedOut: Bool) {
            self.name = name
            self.commits = commits
            self.parent = parent
            self.isCheckedOut = isCheckedOut
        }

        public var isBud: Bool { commits.isEmpty }
    }

    /// The trunk's branch name, when it's known.
    public let trunkName: String?
    /// The trunk's drawn commits, oldest first.
    public let trunk: [Commit]
    /// Every limb, each after its parent.
    public let limbs: [Limb]
    public let isTrunkCheckedOut: Bool

    public init(trunkName: String?, trunk: [Commit], limbs: [Limb], isTrunkCheckedOut: Bool) {
        self.trunkName = trunkName
        self.trunk = trunk
        self.limbs = limbs
        self.isTrunkCheckedOut = isTrunkCheckedOut
    }

    /// The commits each stem shows, by name: the trunk's under its name (or "" when unnamed), each
    /// limb's under its branch. A bud counts as one, so it can grow in like any limb.
    public var commitCounts: [String: Int] {
        var counts = [trunkName ?? "": trunk.count]
        for limb in limbs { counts[limb.name] = max(limb.commits.count, 1) }
        return counts
    }
}

extension RepoTree {

    /// The tree in a repository's graph: its trunk, each branch a limb whose parent holds its fork
    /// commit, and each bud (a branch with no commits of its own) on the commit it points at. A fork
    /// older than anything drawn joins the trunk's oldest commit.
    public init(graph: RepoGraph) {
        let trunk = graph.trunk.reversed().map(Self.commit)
        let trunkName = graph.trunkName

        // Where every drawn commit sits.
        var location: [String: Parent] = [:]
        for (index, commit) in trunk.enumerated() { location[commit.sha] = .trunk(node: index + 1) }
        let branches = graph.branches.map { (name: $0.name, commits: $0.commits.reversed().map(Self.commit), forkBase: $0.forkBase) }
        for (branchIndex, branch) in branches.enumerated() {
            for (index, commit) in branch.commits.enumerated() {
                location[commit.sha] = .limb(index: branchIndex, node: index + 1)
            }
        }
        let base = Parent.trunk(node: trunk.isEmpty ? 0 : 1)

        // Order limbs so each follows its parent (they already mostly are: bases claim first).
        var order: [Int] = []
        var placed = Set<Int>()
        func place(_ index: Int, depth: Int = 0) {
            guard !placed.contains(index), depth < branches.count else { return }
            if let fork = branches[index].forkBase, case .limb(let parent, _) = location[fork], parent != index {
                place(parent, depth: depth + 1)
            }
            if placed.insert(index).inserted { order.append(index) }
        }
        branches.indices.forEach { place($0) }
        let newIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        func remap(_ parent: Parent?) -> Parent {
            switch parent {
            case .limb(let index, let node): return newIndex[index].map { .limb(index: $0, node: node) } ?? base
            case .trunk(let node): return .trunk(node: node)
            case nil: return base
            }
        }

        let checkedOut = graph.checkedOutBranches
        var limbs = order.map { index in
            Limb(name: branches[index].name, commits: branches[index].commits,
                 parent: remap(branches[index].forkBase.flatMap { location[$0] }),
                 isCheckedOut: checkedOut.contains(branches[index].name))
        }
        let buds = graph.buds.flatMap { sha, names in names.map { ($0, sha) } }.sorted { $0.0 < $1.0 }
        for (name, sha) in buds where name != trunkName {
            guard let at = location[sha] else { continue }
            limbs.append(Limb(name: name, commits: [], parent: remap(at), isCheckedOut: checkedOut.contains(name)))
        }

        self.init(trunkName: trunkName, trunk: trunk, limbs: limbs,
                  isTrunkCheckedOut: trunkName.map(checkedOut.contains) ?? false)
    }

    private static func commit(_ commit: RepoGraph.Commit) -> Commit {
        Commit(sha: commit.sha, date: commit.date)
    }
}
