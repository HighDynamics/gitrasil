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

    public let worktreeURL: URL

    private let runner: GitRunning
    private let executor: WorktreeExecutor
    private let trunkOverride: String?
    private var watcher: DirectoryWatching?

    public init(worktreeURL: URL, trunkOverride: String? = nil) {
        self.worktreeURL = worktreeURL
        self.trunkOverride = trunkOverride
        self.runner = GitRunner(workdir: worktreeURL)
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
        let task = await executor.read(.snapshot) { runner in
            try await Derivations.worktreeSnapshot(runner: runner, trunkOverride: override)
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

    /// A view-only file diff for the given source (drives the file viewer).
    public func fileDiff(source: DiffSource, path: String) async throws -> FileDiff {
        let task = await executor.read(.custom("diff:\(path)")) { runner in
            try await Derivations.fileDiff(source: source, path: path, runner: runner)
        }
        return try await task.value
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
