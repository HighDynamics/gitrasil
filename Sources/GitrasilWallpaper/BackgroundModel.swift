import Foundation
import Observation
import GitrasilCore

/// The whole background: one pane per repository the pins show (`PinnedRepositories.shown`, at most
/// `maxPanes`), kept in step with them as pins and pinned folders change, and the settings for how
/// they're shown (an orchard or a single tree, banners, gusts).
@MainActor
@Observable
final class BackgroundModel {

    /// The panes on screen, in pin order.
    private(set) var panes: [WallpaperModel] = []

    /// The clock commit ages are measured against. Ticks hourly so old commits keep fading on an
    /// idle desktop; a graph change redraws with the current time anyway.
    private(set) var now = Date()

    /// More than this side by side gets too narrow to read. (The forest spike lifts it for a run with
    /// GITRASIL_BACKGROUND_MAX_PANES.)
    static let maxPanes = ProcessInfo.processInfo.environment["GITRASIL_BACKGROUND_MAX_PANES"].flatMap { Int($0) }.map { max($0, 1) } ?? 4

    /// Trees growing in from nothing: when each pane's tree (or, in the single tree, its bough)
    /// started, and when the single tree's shared trunk did. Empty when nothing is growing in.
    private(set) var growIns: [URL: Date] = [:]
    private(set) var trunkGrowIn: Date?

    /// A tree, or a bough, grows in over this long; a shared trunk rises in `trunkDuration` first.
    nonisolated static let growInDuration: TimeInterval = 2.2
    nonisolated static let trunkDuration: TimeInterval = 0.8

    /// A whole-scene grow-in waiting for trees still being read (`regrow`): only the ground is drawn
    /// until every pane has its tree or a problem, or `settleLimit` has passed.
    var isAwaitingTrees: Bool { wait.isWaiting }
    static let settleLimit: TimeInterval = 2.5
    private var wait = GrowInWait()

    let pins: PinnedRepositories
    let settings: BackgroundSettings
    /// Now and then a gust through the banners, while the background is on screen.
    @ObservationIgnored let breeze = Breeze()

    var isVisible = true {
        didSet {
            for pane in panes { pane.isVisible = isVisible }
            breeze.isVisible = isVisible
            if !isVisible { growIns = [:]; trunkGrowIn = nil; wait.cancel() }
        }
    }

    private var clock: Timer?

    init(pins: PinnedRepositories, settings: BackgroundSettings) {
        self.pins = pins
        self.settings = settings
    }

    func start() {
        observePins()
        observeSettings()
        updateBreeze()
        breeze.start()
        reconcile()
        // The first trees grow in together, once they've all been read.
        regrow()
        clock = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.now = Date()
                for pane in self?.panes ?? [] { pane.tick() }
                // A pinned folder with more repositories than fit shows the most recently active.
                self?.pins.refresh()
            }
        }
    }

    /// Re-arm Observation tracking on the shown repositories (one-shot, so re-armed on every change).
    private func observePins() {
        withObservationTracking {
            _ = pins.shown
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reconcile()
                self.observePins()
            }
        }
    }

    /// Follow the settings (the view redraws on its own; it reads them): a new arrangement or layout
    /// seed grows in from the ground, and the breeze follows the banners and gusts (turning gusts on
    /// blows one at once, so it shows what it does).
    private func observeSettings() {
        let arrangement = settings.arrangement, medium = settings.medium, layoutSeed = settings.layoutSeed
        let names = (settings.showsBranchNames, settings.showsRepoNames, settings.gusts)
        withObservationTracking {
            _ = (settings.arrangement, settings.medium, settings.showsBranchNames, settings.showsRepoNames, settings.gusts,
                 settings.layoutSeed)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.settings.arrangement != arrangement {
                    logEvent("arrangement: \(self.settings.arrangement.rawValue)")
                    self.growInFromTheGround()
                }
                if self.settings.layoutSeed != layoutSeed {
                    logEvent("layout seed: \(self.settings.layoutSeed)")
                    self.regrow()
                }
                // A new medium just redraws (the view reads it); the trees don't grow again.
                if self.settings.medium != medium { logEvent("medium: \(self.settings.medium.rawValue)") }
                if (self.settings.showsBranchNames, self.settings.showsRepoNames, self.settings.gusts) != names {
                    logEvent("branch names \(self.settings.showsBranchNames ? "shown" : "hidden"), "
                             + "repository names \(self.settings.showsRepoNames ? "shown" : "hidden"), "
                             + "gusts \(self.settings.gusts ? "on" : "off")")
                }
                self.updateBreeze()
                if self.settings.gusts, !names.2 { self.breeze.blowNow() }
                self.observeSettings()
            }
        }
    }

    /// Gusts blow only while there are banners to sway and they're wanted.
    private func updateBreeze() {
        breeze.isEnabled = settings.gustsBlow
    }

    /// Match the panes to the repositories shown: keep the stores of repos still pinned, start new ones, stop
    /// the rest. Dropping one grows the whole scene again.
    private func reconcile() {
        let wanted = pins.shown
        var existing = Dictionary(panes.map { ($0.repoURL, $0) }, uniquingKeysWith: { a, _ in a })
        let next = wanted.map { url in
            existing.removeValue(forKey: url) ?? {
                let pane = WallpaperModel(repoURL: url)
                pane.isVisible = isVisible
                pane.onFirstTree = { [weak self] in self?.treeArrived(url) }
                pane.onFirstProblem = { [weak self] in self?.paneSettled() }
                Task { await pane.start() }
                return pane
            }()
        }
        for gone in existing.values { gone.stop() }
        if next.map(\.repoURL) != panes.map(\.repoURL) {
            panes = next
            logEvent("panes: \(panes.map(\.repoName))")
        }
        // A repository dropped: everything left moves, so it all grows again from the ground.
        if !existing.isEmpty, !panes.isEmpty { regrow() }
    }

    // MARK: Growing in

    /// The grow-in under way, as it stands: when each tree (or bough) and the shared trunk started.
    /// It keeps answering after the model has moved on (`Offscreen.frames` draws slower than it runs).
    struct GrowInClock {
        let growIns: [URL: Date]
        let trunk: Date?

        /// How far along `url`'s tree (or bough) is at `date`, eased; nil when it isn't growing in.
        func growIn(_ url: URL, at date: Date) -> Double? {
            growIns[url].map { TreeLayout.growIn(date.timeIntervalSince($0) / BackgroundModel.growInDuration) }
        }

        /// How far the shared trunk has risen at `date`, eased; nil when it isn't rising.
        func trunkGrowIn(at date: Date) -> Double? {
            trunk.map { TreeLayout.growIn(date.timeIntervalSince($0) / BackgroundModel.trunkDuration) }
        }

        /// When it began and when everything in it has grown; nil when nothing is growing in.
        var span: ClosedRange<Date>? {
            let starts = Array(growIns.values) + [trunk].compactMap { $0 }
            let ends = growIns.values.map { $0.addingTimeInterval(BackgroundModel.growInDuration) }
                + [trunk?.addingTimeInterval(BackgroundModel.trunkDuration)].compactMap { $0 }
            guard let start = starts.min(), let end = ends.max() else { return nil }
            return start...end
        }
    }

    var growInClock: GrowInClock { GrowInClock(growIns: growIns, trunk: trunkGrowIn) }

    /// How far along `url`'s tree (or bough) is in growing in at `date`, eased; nil when it isn't.
    /// Waiting for the scene's trees, nothing has grown.
    func growIn(_ url: URL, at date: Date) -> Double? {
        isAwaitingTrees ? 0 : growInClock.growIn(url, at: date)
    }

    /// How far the single tree's shared trunk has risen at `date`, eased; nil when it isn't rising.
    func trunkGrowIn(at date: Date) -> Double? {
        isAwaitingTrees ? 0 : growInClock.trunkGrowIn(at: date)
    }

    var isGrowingIn: Bool { !growIns.isEmpty || trunkGrowIn != nil }

    /// Panes with a tree to draw.
    private var ready: [WallpaperModel] { panes.filter { $0.tree != nil } }

    /// The whole scene grows again from the ground (at launch, when a repository is dropped, and from
    /// the menu's Watch Gitrasil Grow), all together, once every pane has its tree or a problem, or
    /// after `settleLimit` with the trees there are. Meanwhile only the ground shows.
    func regrow() {
        guard isVisible else { return }
        switch wait.start(allSettled: panes.allSatisfy(\.isSettled)) {
        case .growNow:
            growInFromTheGround()
        case .wait(let round):
            Task {
                try? await Task.sleep(for: .seconds(Self.settleLimit))
                if wait.timedOut(round: round) { growInFromTheGround() }
            }
        }
    }

    /// A pane finished its first read (with a tree or a problem): the scene grows once it was the
    /// last one a whole-scene grow-in was waiting for.
    private func paneSettled() {
        if wait.settled(allSettled: panes.allSatisfy(\.isSettled)) { growInFromTheGround() }
    }

    /// Everything grows again from the ground, as when the arrangement changes: in the single tree,
    /// the shared trunk rises first and the boughs follow from the crotch.
    private func growInFromTheGround() {
        guard isVisible else { return }
        let now = Date()
        if settings.arrangement == .singleTree, ready.count > 1 {
            trunkGrowIn = now
            let boughs = now.addingTimeInterval(Self.trunkDuration * 0.85)
            for pane in ready { growIns[pane.repoURL] = boughs }
        } else {
            for pane in ready { growIns[pane.repoURL] = now }
        }
        finishGrowingIn()
    }

    /// A pane's first tree: just pinned, or just started. In the orchard it grows in on its own plot.
    /// In the single tree every bough moves to make room for it, so they all grow again from the
    /// crotch (from the ground, when it's the second and the single tree is only now forming).
    private func treeArrived(_ url: URL) {
        guard isVisible else { return }
        guard !isAwaitingTrees else { return paneSettled() }
        let now = Date()
        switch (settings.arrangement, ready.count) {
        case (.singleTree, 2):
            growInFromTheGround()
            return
        case (.singleTree, 3...):
            // Boughs waiting on a rising trunk keep waiting.
            for pane in ready { growIns[pane.repoURL] = max(growIns[pane.repoURL] ?? now, now) }
        default:
            growIns[url] = now
        }
        finishGrowingIn()
    }

    /// Once every grow-in has run, back to drawing only on change.
    private func finishGrowingIn() {
        guard let last = growInClock.span?.upperBound else { return }
        Task {
            try? await Task.sleep(for: .seconds(max(last.timeIntervalSinceNow, 0) + 0.05))
            let now = Date()
            growIns = growIns.filter { $0.value.addingTimeInterval(Self.growInDuration) > now }
            if let trunk = trunkGrowIn, trunk.addingTimeInterval(Self.trunkDuration) <= now { trunkGrowIn = nil }
        }
    }
}

/// A line in the run log (stdout), stamped with the time.
func logEvent(_ message: String) {
    let stamp = Date().formatted(.dateTime.hour().minute().second())
    print("[\(stamp)] \(message)")
    fflush(stdout)
}
