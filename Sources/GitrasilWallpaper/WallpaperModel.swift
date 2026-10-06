import Foundation
import Observation
import GitrasilCore

/// One repository on the wallpaper: bridges its `RepoGraphStore` to the view as a `RepoTree`. The
/// store already settles bursts and publishes only real graph changes; this adds the growth — limbs
/// that gained commits (or appeared) grow in over a moment; otherwise nothing ticks.
@MainActor
@Observable
final class WallpaperModel {

    /// The tree being drawn, or nil before the first derive.
    private(set) var tree: RepoTree?

    /// When the growth began, while it's running; nil when idle (the animation clock is paused).
    private(set) var growthStart: Date?

    /// The stems growing in the running growth, by name (`RepoTree.commitCounts` keys): the commits
    /// each had before, and has now.
    private(set) var growth: [String: Growth] = [:]

    struct Growth: Equatable {
        let from: Double
        let to: Double
    }

    /// The repository's folder and display name.
    let repoURL: URL
    let repoName: String

    /// Why there's nothing to draw (the folder is gone, or git can't read it), or nil.
    var problem: String? {
        if !FileManager.default.fileExists(atPath: repoURL.path) { return "This folder is missing." }
        return tree == nil && store.lastError != nil ? "Git can’t read this repository." : nil
    }

    static let growthDuration: TimeInterval = 1.8

    /// What a tree draws: a long stretch of trunk, so fork heights spread out, and enough branches to
    /// make a crown, including dormant ones (they draw as bare limbs).
    static let options = RepoGraphOptions(trunkCommits: 200, maxBranches: 14, maxAge: 120 * 24 * 3600,
                                          branchCommitLimit: 60)

    /// False while the window is fully covered (a full-screen app, another Space's windows on top):
    /// the store stops deriving until it's visible again, and no animation runs.
    var isVisible = true {
        didSet {
            store.isPaused = !isVisible
            if !isVisible { growthStart = nil }
        }
    }

    /// Called when the first tree arrives (the pane was just pinned, or the app just started), so the
    /// background can grow it in.
    var onFirstTree: (() -> Void)?

    private let store: RepoGraphStore
    private var redraws = 0

    init(repoURL: URL) {
        self.repoURL = repoURL
        self.repoName = repoURL.lastPathComponent
        self.store = RepoGraphStore(repositoryURL: repoURL, options: Self.options)
    }

    func start() async {
        observe()
        await store.start()
    }

    func stop() {
        store.stop()
    }

    /// Re-arm Observation tracking on the store's graph (one-shot, so re-armed on every change).
    private func observe() {
        withObservationTracking {
            _ = store.graph
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.graphDidChange()
                self.observe()
            }
        }
    }

    private func graphDidChange() {
        guard let graph = store.graph else { return }
        let fresh = RepoTree(graph: graph)
        guard fresh != tree else { return }
        let first = tree == nil
        let grew = tree.map { Self.growth(from: $0, to: fresh) } ?? [:]
        tree = fresh
        redraws += 1
        logEvent("\(repoName): redraw #\(redraws) (derive #\(store.deriveCount)): \(fresh.trunk.count) trunk commits, "
            + "\(fresh.limbs.count) limbs, grew \(grew.keys.sorted())")
        if !grew.isEmpty, isVisible { grow(grew) }
        if first { onFirstTree?() }
    }

    /// The stems with more commits than before (a new stem grows from nothing).
    static func growth(from old: RepoTree, to new: RepoTree) -> [String: Growth] {
        let before = old.commitCounts
        var growth: [String: Growth] = [:]
        for (name, count) in new.commitCounts {
            let from = before[name] ?? 0
            if count > from { growth[name] = Growth(from: Double(from), to: Double(count)) }
        }
        return growth
    }

    /// Commits grown in so far, by stem, at `date` in the running growth (eased); empty when idle.
    func grown(at date: Date) -> [String: Double] {
        guard let growthStart else { return [:] }
        let t = min(max(date.timeIntervalSince(growthStart) / Self.growthDuration, 0), 1)
        let eased = 1 - pow(1 - t, 3)
        return growth.mapValues { $0.from + ($0.to - $0.from) * eased }
    }

    private func grow(_ stems: [String: Growth]) {
        let start = Date()
        growthStart = start
        growth = stems
        Task {
            try? await Task.sleep(for: .seconds(Self.growthDuration))
            if growthStart == start { growthStart = nil }
        }
    }
}
