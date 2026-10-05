import Foundation
import Observation
import GitrasilCore

/// One repository on the wallpaper: bridges its `RepoGraphStore` to the view. The store already
/// settles bursts and publishes only real graph changes; this adds the pulse — the branch tips that
/// moved in a change ring briefly; otherwise nothing ticks.
@MainActor
@Observable
final class WallpaperModel {

    /// The graph being drawn, or nil before the first derive.
    private(set) var graph: HistoryGraph?

    /// When the pulse began, while it's running; nil when idle (the animation clock is paused).
    private(set) var pulseStart: Date?

    /// The commits the running pulse rings: the tips of branches that moved or appeared.
    private(set) var pulseTips: Set<String> = []

    /// The repository's folder and display name.
    let repoURL: URL
    let repoName: String

    /// Why there's nothing to draw (the folder is gone, or git can't read it), or nil.
    var problem: String? {
        if !FileManager.default.fileExists(atPath: repoURL.path) { return "This folder is missing." }
        return graph == nil && store.lastError != nil ? "Git can’t read this repository." : nil
    }

    static let pulseDuration: TimeInterval = 1.6

    /// False while the window is fully covered (a full-screen app, another Space's windows on top):
    /// the store stops deriving until it's visible again, and no animation runs.
    var isVisible = true {
        didSet {
            store.isPaused = !isVisible
            if !isVisible { pulseStart = nil }
        }
    }

    private let store: RepoGraphStore
    private var redraws = 0

    init(repoURL: URL) {
        self.repoURL = repoURL
        self.repoName = repoURL.lastPathComponent
        self.store = RepoGraphStore(repositoryURL: repoURL)
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
        guard let fresh = store.graph, fresh != graph else { return }
        let moved = Self.tips(of: fresh).filter { name, sha in graph.map { Self.tips(of: $0)[name] != sha } ?? false }
        graph = fresh
        redraws += 1
        let rows = GraphLayout.rows(for: fresh, expanded: false)
        log("\(repoName): redraw #\(redraws) (derive #\(store.deriveCount)): \(rows.count) rows, "
            + "\(Set(rows.map(\.lane)).count) lanes, moved \(moved.keys.sorted())")
        if !moved.isEmpty, isVisible { pulse(Set(moved.values)) }
    }

    /// Each drawn branch's tip commit, by branch name: the spine's tip, each lane's, and each pill's.
    static func tips(of graph: HistoryGraph) -> [String: String] {
        var tips: [String: String] = [:]
        for segment in graph.segments + graph.revealedLanes {
            if let name = segment.branchLabel, let tip = segment.commits.first?.sha { tips[name] = tip }
        }
        for (sha, names) in graph.revealedPointers { for name in names { tips[name] = sha } }
        return tips
    }

    private func pulse(_ shas: Set<String>) {
        let start = Date()
        pulseStart = start
        pulseTips = shas
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
