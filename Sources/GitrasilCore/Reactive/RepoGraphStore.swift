import Foundation
import Observation

/// The observable store behind one repository on the desktop background: it publishes the
/// repo-wide graph (`Derivations.repoGraph`) and keeps it live at as little cost as possible.
///
/// - It watches only the repository's common git dir, and only ref paths in it (`HEAD`,
///   `packed-refs`, `refs/…`, each worktree's `HEAD`) — never working trees, the index, or objects,
///   so builds and editor saves cost nothing.
/// - It waits for changes to **settle** before deriving: every ref event restarts a quiet-period
///   timer, so a burst (a rebase, or a scripted checkout/commit/checkout) is one derive.
/// - Before the full derive it takes a one-spawn ref fingerprint and skips the derive when nothing
///   the graph depends on moved.
/// - It publishes only when the graph actually changed.
/// - While paused (the desktop is hidden) it derives nothing; one catch-up derive runs on resume.
@MainActor
@Observable
public final class RepoGraphStore {

    /// The latest graph, or nil before the first successful derive.
    public private(set) var graph: RepoGraph?

    /// A human-readable message from the last failed derive, or nil.
    public private(set) var lastError: String?

    /// How many full derives have run (the fingerprint gate skips the rest). For tests and logging.
    public private(set) var deriveCount = 0

    /// While true, ref changes are noted but not derived; clearing it runs one catch-up refresh.
    public var isPaused = false {
        didSet {
            guard oldValue != isPaused, !isPaused, missedChange else { return }
            missedChange = false
            refsChanged()
        }
    }

    public let repositoryURL: URL

    private let runner: GitRunning
    private let executor: WorktreeExecutor
    private let options: RepoGraphOptions
    private let settle: Duration
    private var watcher: DirectoryWatching?
    private var settleTask: Task<Void, Never>?
    private var fingerprint: String?
    private var missedChange = false

    /// - Parameters:
    ///   - settle: the quiet period a burst of ref changes must end with before one derive runs.
    public init(repositoryURL: URL, options: RepoGraphOptions = RepoGraphOptions(),
                settle: Duration = .seconds(1)) {
        self.repositoryURL = repositoryURL
        self.options = options
        self.settle = settle
        // GIT_OPTIONAL_LOCKS=0 keeps every read lock-free, so our own git calls never write into the
        // directory we watch.
        self.runner = GitRunner(workdir: repositoryURL, extraEnvironment: GitRunner.appEnvironment)
        self.executor = WorktreeExecutor(runner: runner)
    }

    /// Derive the first graph, then start watching. Call once.
    public func start() async {
        await refresh()
        await installWatcher()
    }

    /// Stop watching and drop any pending derive.
    public func stop() {
        watcher?.stop()
        watcher = nil
        settleTask?.cancel()
        settleTask = nil
    }

    /// Re-derive now (no settle). Skipped when the ref fingerprint is unchanged.
    public func refresh() async {
        let options = self.options
        let known = graph == nil ? nil : fingerprint
        let task = await executor.read(.graph) { runner -> (fingerprint: String, graph: RepoGraph?) in
            let print = try await Derivations.refFingerprint(runner: runner)
            if print == known { return (print, nil) }
            return (print, try await Derivations.repoGraph(runner: runner, options: options))
        }
        do {
            let result = try await task.value
            lastError = nil
            guard let fresh = result.graph else { return }   // nothing the graph depends on moved
            fingerprint = result.fingerprint
            deriveCount += 1
            if fresh != graph { graph = fresh }
        } catch is CancellationError {
            // Superseded by a newer derive; the winner publishes.
        } catch {
            lastError = String(describing: error)
        }
    }

    /// A ref changed on disk: restart the settle timer (or note it while paused).
    func refsChanged() {
        if isPaused {
            missedChange = true
            return
        }
        settleTask?.cancel()
        settleTask = Task { [weak self, settle] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Whether a changed path inside a git dir can affect the graph: refs, packed refs, and HEADs
    /// (the repository's and each linked worktree's). Index, objects, `FETCH_HEAD` and friends can't.
    /// A `.lock` file counts as its target, since git writes refs through one. Reflogs (`logs/…`)
    /// don't: they're written alongside the ref itself. A false positive only costs a fingerprint
    /// check; a false negative misses a change, so the tests lean on suffixes, not the whole path.
    public nonisolated static func isRefPath(_ path: String) -> Bool {
        let p = path.hasSuffix(".lock") ? String(path.dropLast(".lock".count)) : path
        if p.hasSuffix("/logs/HEAD") || p.contains("/logs/refs/") { return false }
        return p.hasSuffix("/HEAD") || p.hasSuffix("/packed-refs") || p.contains("/refs/")
    }

    private func installWatcher() async {
        guard watcher == nil,
              let common = try? await runner.runChecked(["rev-parse", "--git-common-dir"]).trimmedStdout,
              !common.isEmpty else { return }
        let commonURL = URL(fileURLWithPath: common, relativeTo: repositoryURL).standardizedFileURL
        let watcher = FSEventsWatcher(paths: [commonURL.path], latency: 0.3,
                                      filter: { RepoGraphStore.isRefPath($0) }) { [weak self] in
            Task { @MainActor in self?.refsChanged() }
        }
        self.watcher = watcher
        watcher.start()
    }
}

extension Derivations {

    /// Everything the repo-wide graph depends on that can change without a commit's content
    /// changing, in one spawn: every ref's target (and symbolic target, e.g. `origin/HEAD`) and the
    /// worktree a branch is checked out in.
    public static func refFingerprint(runner: GitRunning) async throws -> String {
        try await runner.runChecked([
            "for-each-ref", "--format=%(objectname) %(refname) %(symref) %(worktreepath)",
        ]).stdoutString ?? ""
    }
}
