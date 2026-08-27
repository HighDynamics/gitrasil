import Foundation
import Observation

/// The repository-level store: one window = one repository, one tab = one worktree (README).
///
/// It enumerates the repository's worktrees, owns a `WorktreeStore` per worktree (created lazily on
/// first selection, each with its own git runner and FSEvents watcher), tracks which tab is
/// selected, and assigns a stable identity-color index per worktree so the UI can color the tab,
/// header, and graph spine consistently. A watcher on the common git dir keeps the worktree list
/// live when worktrees are added or removed — including from the embedded terminal.
@MainActor
@Observable
public final class RepositoryStore {

    /// The repository's worktrees (bare entries excluded — they have no working tree, no tab), in
    /// git's own order: the main worktree first, then linked worktrees.
    public private(set) var worktrees: [WorktreeInfo] = []

    /// The selected worktree's path, or nil before the first enumeration.
    public private(set) var selectedPath: URL?

    /// A human-readable message from the last failed worktree enumeration, or nil.
    public private(set) var lastError: String?

    /// A message from the last failed create/remove action, shown as a dismissible banner.
    public private(set) var actionError: String?

    private let anchorURL: URL
    private let runner: GitRunning

    private var stores: [URL: WorktreeStore] = [:]
    private var colorIndexByPath: [URL: Int] = [:]
    private var nextColorIndex = 0
    private var watcher: DirectoryWatching?

    /// - Parameter anchorURL: a path inside the repository (the directory the user opened). Its own
    ///   worktree is selected first when it resolves to one.
    public init(anchorURL: URL) {
        self.anchorURL = anchorURL.standardizedFileURL
        self.runner = GitRunner(workdir: anchorURL, extraEnvironment: GitRunner.appEnvironment)
    }

    /// Enumerate worktrees, select one, and begin watching for add/remove. Safe to call once.
    public func start() async {
        await refreshWorktrees()
        if selectedPath == nil {
            // Prefer the worktree the user actually opened; otherwise the main worktree.
            let opened = worktrees.first { $0.path == anchorURL }
            selectedPath = (opened ?? worktrees.first)?.path
        }
        if let selectedPath { _ = store(for: selectedPath) }   // pre-create, not during view body
        await installWatcher()
    }

    /// Stop the repository watcher and every per-worktree store's watcher.
    public func stop() {
        watcher?.stop()
        watcher = nil
        for store in stores.values { store.stop() }
    }

    /// Select a worktree tab.
    public func select(_ path: URL) {
        guard worktrees.contains(where: { $0.path == path }) else { return }
        selectedPath = path
        _ = store(for: path)   // pre-create so the view body only reads an existing store
    }

    public func dismissActionError() { actionError = nil }

    // MARK: Create / remove (design brief §5 write side)

    /// Create a worktree — a new branch off `base`, or a checkout of the existing branch `base` — at
    /// `path`, recording the selected worktree as its origin. On success re-enumerates and selects it.
    public func createWorktree(newBranch: String?, base: String, at path: URL) async {
        let source = worktrees.first { $0.path == selectedPath }?.branch
        do {
            try await Mutations.addWorktree(at: path, newBranch: newBranch, base: base, source: source, runner: runner)
            actionError = nil
            await refreshWorktrees()
            if let created = worktrees.first(where: { $0.path.resolvingSymlinksInPath() == path.resolvingSymlinksInPath() }) {
                select(created.path)
            }
        } catch let error as MutationError {
            actionError = error.message
        } catch {
            actionError = String(describing: error)
        }
    }

    /// Remove a worktree. If it's the selected one, selection falls back to the main worktree.
    public func removeWorktree(_ info: WorktreeInfo, force: Bool = false) async {
        do {
            try await Mutations.removeWorktree(at: info.path, branch: info.branch, force: force, runner: runner)
            actionError = nil
            if selectedPath == info.path { selectedPath = worktrees.first { $0.isMain }?.path }
            await refreshWorktrees()
            if let selectedPath, worktrees.contains(where: { $0.path == selectedPath }) { _ = store(for: selectedPath) }
        } catch let error as MutationError {
            actionError = error.message
        } catch {
            actionError = String(describing: error)
        }
    }

    /// A sensible default directory for a new worktree: a sibling of the repository named
    /// `<repo>-<branch>` (branch slashes flattened to dashes).
    public func defaultWorktreePath(forBranch branch: String) -> URL {
        let mainPath = (worktrees.first { $0.isMain }?.path ?? anchorURL)
        let repoName = mainPath.lastPathComponent
        let slug = branch.replacingOccurrences(of: "/", with: "-")
        return mainPath.deletingLastPathComponent().appendingPathComponent("\(repoName)-\(slug)")
    }

    /// Local branches not currently checked out in any worktree — the candidates for a new worktree
    /// on an *existing* branch (git refuses to check a branch out twice).
    public func branchesAvailableForCheckout() async -> [String] {
        let all = await allLocalBranches()
        let checkedOut = Set(worktrees.compactMap(\.branch))
        return all.filter { !checkedOut.contains($0) }
    }

    /// All local branches (candidates for a new branch's base — you may branch off a checked-out one).
    public func allLocalBranches() async -> [String] {
        (try? await Derivations.localBranches(runner: runner)) ?? []
    }

    /// The selected worktree's branch (the default base / origin for a new worktree).
    public var currentBranch: String? { worktrees.first { $0.path == selectedPath }?.branch }

    /// The store for a worktree, created (and started) on first request. Returns a store whose
    /// snapshot is nil until its first derive completes; the worktree view already handles that.
    public func store(for path: URL) -> WorktreeStore {
        if let existing = stores[path] { return existing }
        let store = WorktreeStore(worktreeURL: path)
        stores[path] = store
        Task { await store.start() }
        return store
    }

    /// A stable identity-color index for a worktree, assigned on first sighting and preserved across
    /// refreshes so a tab never changes color when another worktree is added or removed.
    public func colorIndex(for path: URL) -> Int {
        colorIndexByPath[path] ?? 0
    }

    /// Re-enumerate worktrees. Publishes only when what the tab strip shows actually changed, drops
    /// stores for worktrees that disappeared, and keeps the selection valid.
    public func refreshWorktrees() async {
        do {
            let fresh = try await Derivations.worktrees(runner: runner).filter { !$0.isBare }
            lastError = nil
            // Compare on the fields the strip renders — not `head`, which moves on every commit in
            // any worktree and is shown only for detached ones. Otherwise every commit would
            // re-publish `worktrees` and re-render the tabs.
            guard fresh.map(Self.tabSignature) != worktrees.map(Self.tabSignature) else { return }

            for info in fresh where colorIndexByPath[info.path] == nil {
                colorIndexByPath[info.path] = nextColorIndex
                nextColorIndex += 1
            }

            let livePaths = Set(fresh.map(\.path))
            for (path, store) in stores where !livePaths.contains(path) {
                store.stop()
                stores.removeValue(forKey: path)
            }

            worktrees = fresh
            if let selectedPath, !livePaths.contains(selectedPath) {
                self.selectedPath = fresh.first?.path
                // Pre-create the reselected store here too, so the view body only reads an existing
                // store (never mutates `stores` during a view update).
                if let path = self.selectedPath { _ = store(for: path) }
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    /// What the tab strip actually distinguishes: identity, label, and — only when detached — the
    /// HEAD it displays. Deliberately excludes `head` for attached worktrees.
    private static func tabSignature(_ w: WorktreeInfo) -> String {
        "\(w.path.path)|\(w.branch ?? "")|\(w.isDetached)|\(w.isLocked)|\(w.isMain)|\(w.isDetached ? (w.head ?? "") : "")"
    }

    private func installWatcher() async {
        guard watcher == nil else { return }
        // The common git dir holds `worktrees/<name>` admin dirs; a worktree add/remove changes it.
        // `worktree list` is read-only and takes no locks, so re-enumerating on events can't feed a
        // write→event loop. FSEvents watches recursively; `refreshWorktrees` diffs before publishing.
        guard let common = try? await runner.runChecked(["rev-parse", "--git-common-dir"]).trimmedStdout,
              !common.isEmpty else { return }
        let commonURL = URL(fileURLWithPath: common, relativeTo: anchorURL).standardizedFileURL
        let watcher = FSEventsWatcher(paths: [commonURL.path]) { [weak self] in
            Task { @MainActor in await self?.refreshWorktrees() }
        }
        self.watcher = watcher
        watcher.start()
    }
}
