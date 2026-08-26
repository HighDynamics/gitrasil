import Foundation

extension Derivations {

    /// Assemble the full `WorktreeSnapshot` — the one immutable value the reactive store publishes.
    /// Folds the history graph, status facts, branch identity, and in-progress operation together.
    public static func worktreeSnapshot(
        runner: GitRunning, trunkOverride: String? = nil, revealedBranches: [String] = []
    ) async throws -> WorktreeSnapshot {
        let graph = try await historyGraph(
            runner: runner, trunkOverride: trunkOverride, revealedBranches: revealedBranches)
        let trunkRef = try? await resolveTrunk(runner: runner, override: trunkOverride)

        // In-progress operation (filesystem markers in the worktree's own git dir).
        let gitDir = try await absoluteGitDir(runner: runner)
        let operation = inProgressOperation(gitDir: gitDir)

        // Branch identity. During a rebase, git detaches HEAD onto the commit being replayed, so
        // restore the original branch label from the rebase state — the tab should keep naming the
        // branch it's rebasing, not flip to `detached` (matches the paused-rebase mockup).
        var branch = try await branchIdentity(runner: runner)
        if case .detached = branch, operation == .rebase, let original = rebaseOntoBranchName(gitDir: gitDir) {
            branch = .branch(original)
        }

        // Behind = trunk is ahead of the meeting commit, which the graph already expresses as a
        // trunk-ahead fork lane.
        let behind = graph.trunkAhead != nil
        let facts = WorktreeStatusFacts(
            inProgress: operation != nil,
            dirty: graph.hasUncommittedChanges,
            behind: behind)

        return WorktreeSnapshot(branch: branch, statusFacts: facts, graph: graph,
                                inProgress: operation, trunkRef: trunkRef)
    }

    // MARK: - Branch identity

    /// The worktree's branch, or detached-HEAD identity.
    public static func branchIdentity(runner: GitRunning) async throws -> BranchIdentity {
        let symbolic = try await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"])
        if symbolic.status == 0 {
            return .branch(symbolic.trimmedStdout)
        }
        // Detached: fall back to the short SHA. (On an unborn branch symbolic-ref still resolves,
        // so we only reach here when genuinely detached.)
        let short = try await runner.runChecked(["rev-parse", "--short", "HEAD"])
        return .detached(shortSHA: short.trimmedStdout)
    }

    // MARK: - In-progress operation

    /// Standalone convenience: resolve the git dir and check for a halted operation.
    public static func inProgressOperation(runner: GitRunning) async throws -> InProgressOperation? {
        let gitDir = try await absoluteGitDir(runner: runner)
        return inProgressOperation(gitDir: gitDir)
    }

    /// Absolute path to the worktree's own git dir (for a linked worktree, `.git/worktrees/<name>`).
    static func absoluteGitDir(runner: GitRunning) async throws -> String {
        try await runner.runChecked(["rev-parse", "--absolute-git-dir"]).trimmedStdout
    }

    /// Detect a halted operation from the marker files/dirs in the worktree's git dir. Rebase is
    /// checked first (a conflicted pick leaves `rebase-merge/`); then cherry-pick, then merge.
    static func inProgressOperation(gitDir: String) -> InProgressOperation? {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: gitDir + "/" + name) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("MERGE_HEAD") { return .merge }
        return nil
    }

    /// The branch a paused rebase is replaying, read from `rebase-merge/head-name` (or the
    /// `rebase-apply` variant). Returns the short branch name, or nil if unreadable.
    static func rebaseOntoBranchName(gitDir: String) -> String? {
        for sub in ["rebase-merge/head-name", "rebase-apply/head-name"] {
            guard let contents = try? String(contentsOfFile: gitDir + "/" + sub, encoding: .utf8) else { continue }
            let ref = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
            return ref.isEmpty ? nil : ref
        }
        return nil
    }
}
