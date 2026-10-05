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

    /// Branches the user has revealed in the graph, in reveal order (cherry-pick/rebase sources,
    /// design brief §5). Order is preserved so a lane placed on screen never moves when a later
    /// branch is revealed — the graph assigns lanes in this order.
    public private(set) var revealedBranches: [String] = []

    public let worktreeURL: URL

    private let runner: GitRunning
    private let executor: WorktreeExecutor
    private let trunkOverride: String?
    private var watcher: DirectoryWatching?

    public init(worktreeURL: URL, trunkOverride: String? = nil) {
        self.worktreeURL = worktreeURL
        self.trunkOverride = trunkOverride
        // GIT_OPTIONAL_LOCKS=0 (in the shared appEnvironment) makes our frequent reads (git status
        // on every refresh) truly read-only: without it, status takes the optional index lock to
        // refresh the stat cache — and after a reset --hard (undo) or rebase, files share the index's
        // second-granularity mtime and stay "racy", so status re-locks on every call. The transient
        // .git/index.lock create/delete lands in the watched git dir, firing FSEvents → refresh →
        // status → lock, a self-sustaining ~100% CPU loop while the app looks idle. Mutations still
        // take their real (non-optional) locks, so history edits are unaffected.
        self.runner = GitRunner(workdir: worktreeURL, extraEnvironment: GitRunner.appEnvironment)
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
        let revealed = revealedBranches
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

    // MARK: Revealed branches (design brief §5, "show other branches")

    /// Reveal a branch in the graph (appended in reveal order) and re-derive.
    public func reveal(_ branch: String) async {
        if !revealedBranches.contains(branch) { revealedBranches.append(branch) }
        await refresh()
    }

    /// Hide a previously-revealed branch.
    public func hide(_ branch: String) async {
        revealedBranches.removeAll { $0 == branch }
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
