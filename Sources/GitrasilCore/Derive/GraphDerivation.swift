import Foundation

extension Derivations {

    // Field-separated, NUL-terminated commit format for safe parsing:
    // <sha> US <shortsha> US <author> US <iso-date> US <subject>, records split by NUL (-z).
    private static let commitFormat = "%H%x1f%h%x1f%an%x1f%cI%x1f%s"

    /// Derive the simplified history graph for the current worktree (topology doc).
    ///
    /// Everything is a **first-parent** walk, so merge commits collapse to their branch's
    /// mainline. Commits are grouped into contiguous per-branch segments in ancestry order —
    /// never interleaved by time. Trunk's ahead-commits, when present, are a separate grey fork
    /// lane off the meeting commit, not a linear ancestor.
    ///
    /// - Parameters:
    ///   - runner: git access for this worktree.
    ///   - trunkOverride: optional per-repo trunk override (engineering notes → Trunk detection).
    public static func historyGraph(
        runner: GitRunning, trunkOverride: String? = nil, revealedBranches: [String] = []
    ) async throws -> HistoryGraph {
        // 1. Resolve cw's HEAD commit. If it doesn't resolve, the repo has no commits yet.
        let headResult = try await runner.run(["rev-parse", "--verify", "-q", "HEAD^{commit}"])
        guard headResult.status == 0 else { return .empty }
        let head = headResult.trimmedStdout

        // 2. Detached HEAD? (symbolic-ref fails when detached.)
        let symbolic = try await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"])
        let isDetached = symbolic.status != 0
        let cwBranch: String? = isDetached ? nil : symbolic.trimmedStdout

        // 3. Trunk and its tip.
        let trunk = try await resolveTrunk(runner: runner, override: trunkOverride)
        let trunkLocalName = String(trunk.split(separator: "/").last ?? Substring(trunk))
        let trunkTipResult = try await runner.run(["rev-parse", "--verify", "-q", "\(trunk)^{commit}"])
        let trunkTip = trunkTipResult.status == 0 ? trunkTipResult.trimmedStdout : nil

        // 4. Meeting commit (anchor).
        let meeting = try await mergeBase(trunk, head, runner: runner)
        let meetingNode = try await commit(meeting, runner: runner)

        // 5. cw's own commits (first-parent, meeting..head), never truncated.
        let cwCommits = try await commits(range: "\(meeting)..\(head)", runner: runner)

        // 6. Partition the cw-to-meeting chain into per-branch segments at intermediate branch tips.
        let branchTips = try await localBranchTips(
            runner: runner, excluding: [cwBranch, trunkLocalName].compactMap { $0 })
        let segments = partitionIntoSegments(cwCommits, branchTips: branchTips)
        let branchesBetween = segments.filter {
            if case .intermediate = $0.kind { return true } else { return false }
        }.count

        // 7. main-ahead fork lane, when trunk is ahead of the meeting commit.
        var trunkAhead: GraphSegment?
        if let trunkTip, trunkTip != meeting {
            let aheadCommits = try await commits(range: "\(meeting)..\(trunkTip)", runner: runner)
            if !aheadCommits.isEmpty {
                // Trunk's ahead-commits fork from the meeting commit.
                trunkAhead = GraphSegment(kind: .trunkAhead(branch: trunkLocalName),
                                          commits: aheadCommits, forkBase: meeting)
            }
        }

        // 8. Revealed branches (cherry-pick sources): each branch's commits ahead of its merge-base
        // with cw, as its own grey lane.
        var revealedLanes: [GraphSegment] = []
        // A revealed branch whose tip already sits on the graph has no commits of its own; it's kept
        // as a ref pill on that commit (revealedPointers) rather than dropped.
        var revealedPointers: [String: [String]] = [:]
        // Exclude anything already drawn: cw, the trunk lane, and each revealed lane processed so
        // far — so a commit shared between lanes appears once, in the first lane that claims it.
        var revealedExcludes = [head]
        if let trunkTip { revealedExcludes.append(trunkTip) }
        for name in revealedBranches {
            let tipResult = try await runner.run(["rev-parse", "--verify", "-q", "\(name)^{commit}"])
            guard tipResult.status == 0 else { continue }
            let tip = tipResult.trimmedStdout
            let commits = try await commits(tip: tip, excluding: revealedExcludes, runner: runner)
            revealedExcludes.append(tip)
            if !commits.isEmpty {
                // The lane forks from the first-parent of its oldest commit (which may sit in
                // another lane — e.g. a branch off an advanced main rejoins at main's tip).
                let oldest = commits[commits.count - 1].sha
                let parentResult = try await runner.run(["rev-parse", "--verify", "-q", "\(oldest)^"])
                let forkBase = parentResult.status == 0 ? parentResult.trimmedStdout : nil
                // Partition at intermediary branch tips, mirroring the cw spine, so history that
                // actually belongs to an intermediary branch isn't drawn as if this branch owned it:
                // the branch's own commits form the top (.revealed) segment, each intermediary below
                // becomes its own labeled .intermediate segment. They chain into one lane.
                revealedLanes.append(contentsOf: partitionRevealedLane(
                    commits, branch: name, branchTips: branchTips, baseForkBase: forkBase))
            } else {
                // No unique commits — the branch points at a commit already drawn (its own tip).
                revealedPointers[tip, default: []].append(name)
            }
        }

        // 9. Working-tree dirtiness (open-circle hint at the tip).
        let dirty = try await isDirty(runner: runner)

        return HistoryGraph(
            meetingCommit: meetingNode,
            segments: segments,
            trunkAhead: trunkAhead,
            revealedLanes: revealedLanes,
            revealedPointers: revealedPointers,
            branchesBetween: branchesBetween,
            isEmpty: false,
            isDetached: isDetached,
            isOnTrunk: cwBranch != nil && cwBranch == trunkLocalName,
            hasUncommittedChanges: dirty)
    }

    // MARK: - Helpers

    /// Split cw's first-parent commit list (newest→oldest) into contiguous segments. The run above
    /// the first intermediate branch tip is cw's; each branch tip begins a new labeled segment that
    /// runs down to the next tip (or the meeting commit). Empty segments are dropped.
    static func partitionIntoSegments(_ cwCommits: [CommitNode], branchTips: [String: String]) -> [GraphSegment] {
        var result: [GraphSegment] = []
        var currentKind: GraphSegment.Kind = .currentWorktree
        var current: [CommitNode] = []

        for (index, commit) in cwCommits.enumerated() {
            // A branch tip starts a new segment — except at index 0 (that's cw's own tip, even if
            // another branch happens to point at the same commit).
            if index > 0, let branch = branchTips[commit.sha] {
                if !current.isEmpty { result.append(GraphSegment(kind: currentKind, commits: current)) }
                currentKind = .intermediate(branch: branch)
                current = [commit]
            } else {
                current.append(commit)
            }
        }
        if !current.isEmpty { result.append(GraphSegment(kind: currentKind, commits: current)) }
        return result
    }

    /// Partition a revealed branch's unique commits (newest→oldest) at intermediary branch tips,
    /// mirroring `partitionIntoSegments` for the cw spine. The top run is the branch's own commits
    /// (`.revealed`); each branch tip below (skipping the branch's own tip at index 0) starts an
    /// `.intermediate` segment. Segments are returned bottom→top with `forkBase` set — the bottom
    /// forks from `baseForkBase`, each upper segment from the tip of the segment below it — so the
    /// lane builder chains them into a single lane.
    static func partitionRevealedLane(
        _ commits: [CommitNode], branch: String, branchTips: [String: String], baseForkBase: String?
    ) -> [GraphSegment] {
        var runs: [(kind: GraphSegment.Kind, commits: [CommitNode])] = []
        var kind: GraphSegment.Kind = .revealed(branch: branch)
        var current: [CommitNode] = []
        for (index, commit) in commits.enumerated() {
            if index > 0, let tipBranch = branchTips[commit.sha] {
                if !current.isEmpty { runs.append((kind, current)) }
                kind = .intermediate(branch: tipBranch)
                current = [commit]
            } else {
                current.append(commit)
            }
        }
        if !current.isEmpty { runs.append((kind, current)) }

        var out: [GraphSegment] = []
        for (i, run) in runs.enumerated() {
            let forkBase = i + 1 < runs.count ? runs[i + 1].commits.first?.sha : baseForkBase
            out.append(GraphSegment(kind: run.kind, commits: run.commits, forkBase: forkBase))
        }
        return out.reversed()   // bottom→top, so the bottom creates the lane and upper runs continue it
    }

    /// Map of full-SHA → local branch short-name for branch tips, excluding the given names
    /// (cw's own branch and the trunk). When several branches point at one commit, the
    /// lexicographically-first name wins, for deterministic labeling.
    static func localBranchTips(runner: GitRunning, excluding: [String]) async throws -> [String: String] {
        // NB: for-each-ref's format language does not support the `%x1f` escape that `git log`
        // does. A space separator is safe — neither a full SHA nor a refname contains a space.
        let out = try await runner.runChecked(
            ["for-each-ref", "--format=%(objectname) %(refname:short)", "refs/heads"])
        let excludeSet = Set(excluding)
        var tips: [String: String] = [:]
        for record in (out.stdoutString ?? "").split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = record.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let sha = String(fields[0]); let name = String(fields[1])
            if excludeSet.contains(name) { continue }
            if let existing = tips[sha], existing <= name { continue }
            tips[sha] = name
        }
        return tips
    }

    /// All local branch short names (for the "show other branches" picker).
    public static func localBranches(runner: GitRunning) async throws -> [String] {
        let out = try await runner.runChecked(["for-each-ref", "--format=%(refname:short)", "refs/heads"])
        return (out.stdoutString ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// First-parent commits in a range (`A..B`), newest first, merges collapsed to mainline.
    static func commits(range: String, runner: GitRunning) async throws -> [CommitNode] {
        let out = try await runner.runChecked(["log", "--first-parent", "-z", "--format=\(commitFormat)", range])
        return parseCommits(out.stdoutString ?? "")
    }

    /// First-parent commits reachable from `tip` but not from any `excluding` ref, newest first.
    static func commits(tip: String, excluding: [String], runner: GitRunning) async throws -> [CommitNode] {
        var args = ["log", "--first-parent", "-z", "--format=\(commitFormat)", tip]
        args.append(contentsOf: excluding.map { "^\($0)" })
        let out = try await runner.runChecked(args)
        return parseCommits(out.stdoutString ?? "")
    }

    /// Metadata for a single commit.
    static func commit(_ ref: String, runner: GitRunning) async throws -> CommitNode {
        let out = try await runner.runChecked(["log", "-1", "-z", "--format=\(commitFormat)", ref])
        guard let node = parseCommits(out.stdoutString ?? "").first else {
            throw GitError.commandFailed(args: ["log", "-1", ref], status: 0, stderr: "no commit parsed")
        }
        return node
    }

    static func parseCommits(_ text: String) -> [CommitNode] {
        var nodes: [CommitNode] = []
        for record in text.split(separator: "\0", omittingEmptySubsequences: true) {
            let f = record.split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5 else { continue }
            nodes.append(CommitNode(sha: f[0], shortSHA: f[1], author: f[2], date: f[3], subject: f[4]))
        }
        return nodes
    }
}
