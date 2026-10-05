import Foundation
import Observation
import GitrasilCore

/// Bridges the app's reactive `WorktreeStore` to the wallpaper. The store republishes a snapshot on
/// every FSEvents tick; the wallpaper only cares about the graph, so this republishes — and the view
/// only redraws — when the graph actually changed. A moved HEAD also starts a short pulse animation;
/// otherwise nothing ticks.
@MainActor
@Observable
final class WallpaperModel {

    /// The graph being drawn, or nil before the first derive.
    private(set) var graph: HistoryGraph?

    /// When the HEAD pulse began, while it's running; nil when idle (the animation clock is paused).
    private(set) var pulseStart: Date?

    /// The repository's display name.
    let repoName: String

    static let pulseDuration: TimeInterval = 1.6
    /// Revealing every branch of a big repo would be unreadable; cap the lanes for the spike.
    static let maxRevealed = 6

    /// False while the window is fully covered (a full-screen app, another Space's windows on top):
    /// updates are still taken, but no animation runs.
    var isVisible = true {
        didSet { if !isVisible { pulseStart = nil } }
    }

    private let store: WorktreeStore
    private var redraws = 0

    init(repoURL: URL) {
        self.repoName = repoURL.lastPathComponent
        self.store = WorktreeStore(worktreeURL: repoURL)
    }

    func start() async {
        observe()
        await store.start()
    }

    /// Re-arm Observation tracking on the store's snapshot (one-shot, so re-armed on every change).
    private func observe() {
        withObservationTracking {
            _ = store.snapshot
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.snapshotDidChange()
                self.observe()
            }
        }
    }

    private func snapshotDidChange() {
        guard let fresh = store.snapshot?.graph else { return }
        guard fresh != graph else {
            log("snapshot republished, graph unchanged — no redraw")
            return
        }
        let oldHead = graph?.segments.first?.commits.first?.sha ?? graph?.meetingCommit?.sha
        let newHead = fresh.segments.first?.commits.first?.sha ?? fresh.meetingCommit?.sha
        graph = fresh
        redraws += 1
        let rows = GraphLayout.rows(for: fresh, expanded: false)
        log("redraw #\(redraws): \(rows.count) rows, \(Set(rows.map(\.lane)).count) lanes, "
            + "head \(newHead.map { String($0.prefix(7)) } ?? "-"), revealed \(store.revealedBranches)")
        if oldHead != nil, oldHead != newHead, isVisible { pulse() }
        Task { await revealNewBranches() }
    }

    /// The derivation is worktree-relative: a repo sitting on trunk draws only its meeting commit.
    /// Reveal the repo's other local branches (up to the cap) so they fan out as lanes, and pick up
    /// branches created later on the next change.
    private func revealNewBranches() async {
        guard let available = try? await store.availableBranches() else { return }
        for branch in available where !store.revealedBranches.contains(branch) {
            guard store.revealedBranches.count < Self.maxRevealed else { break }
            await store.reveal(branch)
        }
    }

    private func pulse() {
        let start = Date()
        pulseStart = start
        Task {
            try? await Task.sleep(for: .seconds(Self.pulseDuration))
            if pulseStart == start { pulseStart = nil }
        }
    }

    func log(_ message: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        print("[\(stamp)] \(message)")
        fflush(stdout)
    }
}
