import Foundation

/// What the repo-wide graph includes. The defaults suit a desktop background: a screenful of trunk
/// history and a handful of branches someone touched recently.
public struct RepoGraphOptions: Sendable, Equatable {
    /// How many first-parent trunk commits make up the spine (the oldest is the bottom anchor).
    public var trunkCommits: Int
    /// The most branch lanes to draw.
    public var maxBranches: Int
    /// Branches whose tip is older than this are left out — unless checked out in a worktree.
    public var maxAge: TimeInterval
    /// The most commits read per branch lane (longer lanes collapse to their tip when drawn).
    public var laneCommitLimit: Int

    public init(trunkCommits: Int = 24, maxBranches: Int = 6, maxAge: TimeInterval = 30 * 24 * 3600,
                laneCommitLimit: Int = 40) {
        self.trunkCommits = trunkCommits
        self.maxBranches = maxBranches
        self.maxAge = maxAge
        self.laneCommitLimit = laneCommitLimit
    }
}

extension Derivations {

    // <sha> US <shortsha> US <author> US <iso-date> US <parents> US <subject>, records split by NUL.
    private static let laneFormat = "%H%x1f%h%x1f%an%x1f%cI%x1f%P%x1f%s"

    /// One local branch as `for-each-ref` reports it.
    struct BranchRef: Equatable {
        let name: String
        let tip: String
        let committed: Date
        /// Checked out in some worktree (`%(worktreepath)` is set).
        let isCheckedOut: Bool
    }

    /// The repository's graph as a whole, not relative to any worktree: the trunk's recent
    /// first-parent history as the spine, and the recently active local branches as lanes forking
    /// off it (or off each other). Emits a `HistoryGraph` so `GraphLayout` lays it out unchanged.
    ///
    /// Read-only — never writes refs, never touches the index — and costs a fixed handful of `git`
    /// spawns plus one per branch drawn.
    public static func repoGraph(
        runner: GitRunning, options: RepoGraphOptions = RepoGraphOptions(), now: Date = Date()
    ) async throws -> HistoryGraph {
        let branches = try await branchRefs(runner: runner)
        guard let spine = try await spineRef(runner: runner, branches: branches) else { return .empty }

        // 1. The spine: trunk's last N first-parent commits, newest first. The oldest is the anchor
        // at the bottom, where lanes whose fork point lies further back join.
        let spineCommits = try await laneCommits(
            ["-n", "\(max(options.trunkCommits, 1))", spine.ref], runner: runner).map(\.node)
        guard let anchor = spineCommits.last else { return .empty }
        var drawn = Set(spineCommits.map(\.sha))
        let segments = spineCommits.count > 1
            ? [GraphSegment(kind: .trunk(branch: spine.label), commits: Array(spineCommits.dropLast()))]
            : []

        // 2. Which branches: those checked out in a worktree first, then the most recently committed,
        // within the age limit, up to the cap.
        let cutoff = now.addingTimeInterval(-options.maxAge)
        let candidates = branches
            .filter { $0.name != spine.label && ($0.isCheckedOut || $0.committed >= cutoff) }
            .sorted { a, b in
                if a.isCheckedOut != b.isCheckedOut { return a.isCheckedOut }
                return a.committed > b.committed
            }
            .prefix(max(options.maxBranches, 0))

        // 3. Each branch's commits not on the spine. Lanes claim commits fewest-first: a branch built
        // on another branch contains all of that branch's commits, so the base claims them and the
        // branch on top keeps only its own, forking from the base's tip — a chain stacks into one
        // line rather than two parallel copies.
        var unique: [(branch: BranchRef, commits: [(node: CommitNode, parent: String?)])] = []
        for branch in candidates {
            let commits = try await laneCommits(
                ["-n", "\(max(options.laneCommitLimit, 1))", branch.tip, "^\(spine.tip)"], runner: runner)
            unique.append((branch, commits))
        }
        unique.sort { a, b in
            a.commits.count != b.commits.count ? a.commits.count < b.commits.count : a.branch.committed < b.branch.committed
        }

        var lanes: [GraphSegment] = []
        var pointers: [String: [String]] = [:]
        for (branch, commits) in unique {
            // The branch's own run is everything newer than the first commit another lane (or the
            // spine) already drew; that commit is where it forks.
            let own = commits.prefix { !drawn.contains($0.node.sha) }
            if own.isEmpty {
                // Nothing of its own: a ref pill on its tip — if the tip is on screen at all.
                if drawn.contains(branch.tip) { pointers[branch.tip, default: []].append(branch.name) }
                continue
            }
            let forkBase = own.count < commits.count ? commits[own.count].node.sha : own.last?.parent
            lanes.append(GraphSegment(kind: .revealed(branch: branch.name), commits: own.map(\.node),
                                      forkBase: forkBase))
            drawn.formUnion(own.map(\.node.sha))
        }

        return HistoryGraph(
            meetingCommit: anchor,
            segments: segments,
            trunkAhead: nil,
            revealedLanes: lanes,
            revealedPointers: pointers,
            branchesBetween: 0,
            isEmpty: false,
            isDetached: false,
            isOnTrunk: false,
            hasUncommittedChanges: false,
            checkedOutBranches: Set(branches.filter(\.isCheckedOut).map(\.name)))
    }

    // MARK: - Helpers

    /// Local branches, most recently committed first.
    static func branchRefs(runner: GitRunning) async throws -> [BranchRef] {
        // Space-separated; the worktree path goes last because it may itself contain spaces (a SHA,
        // a unix time, and a refname never do).
        let out = try await runner.runChecked([
            "for-each-ref", "--sort=-committerdate",
            "--format=%(objectname) %(committerdate:unix) %(refname:short) %(worktreepath)", "refs/heads",
        ])
        var refs: [BranchRef] = []
        for record in (out.stdoutString ?? "").split(separator: "\n", omittingEmptySubsequences: true) {
            let f = record.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, let seconds = TimeInterval(f[1]) else { continue }
            refs.append(BranchRef(name: f[2], tip: f[0], committed: Date(timeIntervalSince1970: seconds),
                                  isCheckedOut: f.count == 4 && !f[3].isEmpty))
        }
        return refs
    }

    /// The ref the spine follows. The trunk as `resolveTrunk` finds it, but the *local* branch when
    /// trunk resolves to a remote one (`origin/main` → `main`): the background shows what's been
    /// committed here, not the last fetch. With no recognizable trunk, the branch checked out in the
    /// main worktree, else the most recent branch, else a detached HEAD. Nil for an empty repository.
    static func spineRef(runner: GitRunning, branches: [BranchRef]) async throws -> (ref: String, label: String, tip: String)? {
        var candidates: [String] = []
        if let trunk = try? await resolveTrunk(runner: runner) {
            if trunk.contains("/"), let local = trunk.split(separator: "/").last.map(String.init),
               branches.contains(where: { $0.name == local }) {
                candidates.append(local)
            }
            candidates.append(trunk)
        }
        let head = try await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"])
        if head.status == 0 { candidates.append(head.trimmedStdout) }
        if let recent = branches.first { candidates.append(recent.name) }
        candidates.append("HEAD")

        for ref in candidates {
            let tip = try await runner.run(["rev-parse", "--verify", "-q", "\(ref)^{commit}"])
            guard tip.status == 0 else { continue }
            return (ref, ref, tip.trimmedStdout)
        }
        return nil
    }

    /// First-parent commits for a `git log` selection, newest first, each with its first parent.
    static func laneCommits(_ selection: [String], runner: GitRunning) async throws -> [(node: CommitNode, parent: String?)] {
        let out = try await runner.runChecked(["log", "--first-parent", "-z", "--format=\(laneFormat)"] + selection)
        var result: [(node: CommitNode, parent: String?)] = []
        for record in (out.stdoutString ?? "").split(separator: "\0", omittingEmptySubsequences: true) {
            let f = record.split(separator: "\u{1f}", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6 else { continue }
            let parent = f[4].split(separator: " ").first.map(String.init)
            result.append((CommitNode(sha: f[0], shortSHA: f[1], author: f[2], date: f[3], subject: f[5]), parent))
        }
        return result
    }
}
