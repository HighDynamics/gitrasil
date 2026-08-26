import Foundation
import Observation

/// The observable, per-worktree store (architecture decision #2, derive-and-publish).
///
/// Git-on-disk is the single source of truth; this store holds a derived, immutable
/// `WorktreeSnapshot` that the UI renders and never mutates. Every change — a manual refresh, an
/// FSEvents notification, or (later) a mutation completing — flows back in as a *fresh* snapshot
/// re-derived through the `WorktreeExecutor`, whose `.snapshot` read coalesces bursts so only the
/// newest re-derive wins.
@MainActor
@Observable
public final class WorktreeStore {

    /// The latest derived snapshot, or nil before the first successful derive.
    public private(set) var snapshot: WorktreeSnapshot?

    /// A human-readable message from the last failed derive, or nil.
    public private(set) var lastError: String?

    /// True while a re-derive is in flight (drives the light refresh affordance, §11).
    public private(set) var isRefreshing = false

    /// A message from the last failed/blocked mutation (dirty tree, git failure, nothing to undo),
    /// shown as a dismissible banner. Cleared by `dismissMutationError()` or a successful mutation.
    public private(set) var mutationError: String?

    /// Branches the user has revealed in the graph (cherry-pick/rebase sources, design brief §5).
    public private(set) var revealedBranches: Set<String> = []

    public let worktreeURL: URL

    private let runner: GitRunning
    private let executor: WorktreeExecutor
    private let trunkOverride: String?
    private var watcher: DirectoryWatching?

    public init(worktreeURL: URL, trunkOverride: String? = nil) {
        self.worktreeURL = worktreeURL
        self.trunkOverride = trunkOverride
        // Never spawn an interactive editor for our own git commands (e.g. rebase --continue);
        // the user resolves conflicts in their own editor/terminal.
        self.runner = GitRunner(workdir: worktreeURL, extraEnvironment: [
            "GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true",
        ])
        self.executor = WorktreeExecutor(runner: runner)
    }

    /// Begin watching for changes and derive the first snapshot. Idempotent-ish: safe to call once
    /// per store lifetime.
    public func start() async {
        await refresh()
        await installWatcher()
    }

    /// Stop watching. Call when the tab/window closes.
    public func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Re-derive the snapshot from git-on-disk and publish it. Coalesced by the executor: a rapid
    /// series of calls resolves to a single newest re-derive.
    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let override = trunkOverride
        let revealed = Array(revealedBranches)
        let task = await executor.read(.snapshot) { runner in
            try await Derivations.worktreeSnapshot(
                runner: runner, trunkOverride: override, revealedBranches: revealed)
        }
        do {
            snapshot = try await task.value
            lastError = nil
        } catch is CancellationError {
            // Superseded by a newer re-derive; the winner will publish.
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: On-demand derivations (routed through the executor so they serialize with everything
    // else and coalesce with rapid re-selection).

    /// Files and metadata for a selected commit (drives the commit detail panel).
    public func commitDetail(sha: String) async throws -> CommitDetail {
        let task = await executor.read(.custom("detail:\(sha)")) { runner in
            try await Derivations.commitDetail(sha: sha, runner: runner)
        }
        return try await task.value
    }

    /// Metadata and the union of files for a selected contiguous range (drives the detail panel).
    public func rangeDetail(oldest: String, newest: String) async throws -> CommitDetail {
        let task = await executor.read(.custom("range:\(oldest):\(newest)")) { runner in
            try await Derivations.rangeDetail(oldest: oldest, newest: newest, runner: runner)
        }
        return try await task.value
    }

    /// Working-tree status decorations and the ignored-path set (drives the directory explorer).
    public func explorerData() async throws -> (status: [String: WorkingFileStatus], ignored: Set<String>) {
        let task = await executor.read(.custom("explorer")) { runner in
            async let status = Derivations.workingTreeStatus(runner: runner)
            async let ignored = Derivations.ignoredPaths(runner: runner)
            return try await (status, ignored)
        }
        return try await task.value
    }

    /// A view-only file diff for the given source (drives the file viewer).
    public func fileDiff(source: DiffSource, path: String) async throws -> FileDiff {
        let task = await executor.read(.custom("diff:\(path)")) { runner in
            try await Derivations.fileDiff(source: source, path: path, runner: runner)
        }
        return try await task.value
    }

    // MARK: Revealed branches (design brief §5, "show other branches")

    /// Reveal a branch in the graph and re-derive.
    public func reveal(_ branch: String) async {
        revealedBranches.insert(branch)
        await refresh()
    }

    /// Hide a previously-revealed branch.
    public func hide(_ branch: String) async {
        revealedBranches.remove(branch)
        await refresh()
    }

    /// Local branches that can be revealed — all except the current worktree's branch, the trunk,
    /// and the intermediate branches already shown in the graph.
    public func availableBranches() async throws -> [String] {
        let task = await executor.read(.custom("branches")) { runner in
            try await Derivations.localBranches(runner: runner)
        }
        let all = try await task.value
        var excluded = Set<String>()
        if let name = snapshot?.branch.name { excluded.insert(name) }
        if let trunk = snapshot?.trunkName { excluded.insert(trunk) }
        for segment in snapshot?.graph.segments ?? [] {
            if case .intermediate(let branch) = segment.kind { excluded.insert(branch) }
        }
        return all.filter { !excluded.contains($0) }
    }

    // MARK: Mutations (design brief §9)

    public func dismissMutationError() { mutationError = nil }

    /// Rebase the current branch onto a target ref (a branch tip or trunk).
    public func rebaseOnto(target: String) async {
        await mutate { runner, branch in
            _ = try await Mutations.rebaseOnto(target: target, branch: branch, runner: runner)
        }
    }

    /// Drop a contiguous range of the current branch's own commits.
    public func drop(oldest: String, newest: String) async {
        await mutate { runner, branch in
            _ = try await Mutations.drop(oldest: oldest, newest: newest, branch: branch, runner: runner)
        }
    }

    /// Cherry-pick a contiguous range from another branch into the current one.
    public func cherryPick(oldest: String, newest: String) async {
        await mutate { runner, branch in
            _ = try await Mutations.cherryPick(oldest: oldest, newest: newest, branch: branch, runner: runner)
        }
    }

    /// Continue the in-progress operation (from the continue/abort bar).
    public func continueOperation() async {
        guard let operation = snapshot?.inProgress else { return }
        await mutateNoBranch { runner in
            _ = try await Mutations.continueOperation(operation, runner: runner)
        }
    }

    /// Abort the in-progress operation.
    public func abortOperation() async {
        guard let operation = snapshot?.inProgress else { return }
        await mutateNoBranch { runner in
            try await Mutations.abortOperation(operation, runner: runner)
        }
    }

    /// Undo the last mutation (reset to the most recent backup ref).
    public func undo() async {
        await mutate { runner, branch in try await Mutations.undo(branch: branch, runner: runner) }
    }

    /// Run a mutation that needs the current branch name, then re-derive authoritatively — a
    /// mutation's completion drives the snapshot (arch decision #1), so the continue/abort bar and
    /// badges reflect real git state whether the mutation completed or paused on a conflict.
    private func mutate(_ operation: @Sendable @escaping (GitRunning, String) async throws -> Void) async {
        guard let branch = snapshot?.branch.name else {
            mutationError = MutationError.detachedHead.message
            return
        }
        await runMutation { runner in try await operation(runner, branch) }
    }

    private func mutateNoBranch(_ operation: @Sendable @escaping (GitRunning) async throws -> Void) async {
        await runMutation(operation)
    }

    private func runMutation(_ operation: @Sendable @escaping (GitRunning) async throws -> Void) async {
        isRefreshing = true
        let task = await executor.mutate { runner in try await operation(runner) }
        do {
            try await task.value
            mutationError = nil
        } catch let error as MutationError {
            mutationError = error.message
        } catch {
            mutationError = String(describing: error)
        }
        isRefreshing = false
        await refresh()   // authoritative re-derive after the mutation settles
    }

    private func installWatcher() async {
        guard watcher == nil else { return }
        var paths = [worktreeURL.path]
        // Also watch the worktree's own git dir and the common git dir (refs/HEAD/in-progress
        // markers), resolving them to absolute paths so linked worktrees are covered.
        if let gitDir = try? await Derivations.absoluteGitDir(runner: runner) { paths.append(gitDir) }
        if let common = try? await runner.runChecked(["rev-parse", "--git-common-dir"]).trimmedStdout {
            let url = URL(fileURLWithPath: common, relativeTo: worktreeURL).standardizedFileURL
            paths.append(url.path)
        }

        let unique = Array(Set(paths))
        let watcher = FSEventsWatcher(paths: unique) { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        self.watcher = watcher
        watcher.start()
    }
}
