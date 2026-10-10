import AppKit
import Foundation
import Observation
import GitrasilCore

/// The whole background: one pane per repository the pins show (`PinnedRepositories.shown`, at most
/// `paneLimit(for:)`), kept in step with them as pins and pinned folders change, and the settings for how
/// they're shown (an orchard or a single tree, banners, gusts).
@MainActor
@Observable
final class BackgroundModel {

    /// The panes on screen, in pin order.
    private(set) var panes: [WallpaperModel] = []

    /// The clock commit ages are measured against. Ticks hourly so old commits keep fading on an
    /// idle desktop; a graph change redraws with the current time anyway.
    private(set) var now = Date()

    /// The most repositories shown: a dozen (`ForestPolicy.plainLimit`), or with the Forest on as many as
    /// the policy allows, past a dozen standing in the forest.
    static func paneLimit(for settings: BackgroundSettings) -> Int {
        let policy = ForestPolicy.standard
        return settings.forest == .off ? policy.plainLimit : policy.paneLimit
    }

    /// When each repository (by path) last had a commit, as it stood at launch and at the first hourly
    /// tick after each midnight: what the forest and the single tree rank by. Frozen in between, so a
    /// commit grows its limb but never moves a tree; a repository pinned later is added as it arrives.
    private(set) var ranking: [String: Date] = [:]
    private var rankedOn = Calendar.current.startOfDay(for: Date())

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
    /// How long a whole-scene grow-in waits for `count` repositories: 2.5 s, and 0.15 s more for each past
    /// four, since at launch they read five at a time (`GitGate`), so sixty-four take a few seconds and
    /// would otherwise arrive one by one after the scene had started growing.
    static func settleLimit(for count: Int) -> TimeInterval { 2.5 + 0.15 * Double(max(count - 4, 0)) }
    private var wait = GrowInWait()

    let pins: PinnedRepositories
    let settings: BackgroundSettings
    /// Now and then a gust through the banners, while the background is on screen.
    @ObservationIgnored let breeze = Breeze()

    var isVisible = true {
        didSet {
            for pane in panes { pane.isVisible = isVisible }
            breeze.isVisible = isVisible
            if !isVisible { growIns = [:]; trunkGrowIn = nil; wait.cancel(); lateArrivals?.cancel(); lateSince = nil }
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
                self?.reRankAfterMidnight()
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
        let forest = settings.forest
        let names = (settings.showsBranchNames, settings.showsRepoNames, settings.gusts)
        withObservationTracking {
            _ = (settings.arrangement, settings.medium, settings.showsBranchNames, settings.showsRepoNames, settings.gusts,
                 settings.layoutSeed, settings.forest)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.settings.arrangement != arrangement {
                    logEvent("arrangement: \(self.settings.arrangement.rawValue)")
                    self.growInFromTheGround()
                }
                if self.settings.forest != forest {
                    logEvent("forest: \(self.settings.forest.rawValue)")
                    // More (or fewer) repositories are shown: read the new ones, then everything grows again.
                    self.pins.limit = Self.paneLimit(for: self.settings)
                    self.reconcile()
                    self.regrow()
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
                pane.startInBackground()
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
    /// after `settleLimit(for:)` with the trees there are. Meanwhile only the ground shows.
    func regrow() {
        guard isVisible else { return }
        switch wait.start(allSettled: panes.allSatisfy(\.isSettled)) {
        case .growNow:
            growInFromTheGround()
        case .wait(let round):
            Task {
                try? await Task.sleep(for: .seconds(Self.settleLimit(for: panes.count)))
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
        lateArrivals?.cancel()
        lateSince = nil
        takeRanking()
        let now = Date()
        if settings.arrangement == .singleTree, ready.count > 1 {
            trunkGrowIn = now
            growIns = startTimes(from: now.addingTimeInterval(Self.trunkDuration * 0.85))
        } else {
            growIns = startTimes(from: now)
        }
        finishGrowingIn()
    }

    /// The trees that stand in front (on the single tree, or in the orchard's plain plots) grow in together;
    /// past them the rest follow in a wave, a tree every `waveStep` in ranking order from `waveLead` on,
    /// so no more than a score are ever growing at once: the forest builds up behind the tree instead of
    /// every layer redrawing on the same frames.
    static let waveLead: TimeInterval = 1.0
    static let waveStep: TimeInterval = 0.12
    static let waveSpan: TimeInterval = 4.0

    /// How many trees grow in together before the wave: what the single tree holds on the display that
    /// holds most (so no tree on any display waits for the wave), or the orchard's plain plots. None
    /// wave when the Forest is off.
    private var waveFrom: Int {
        let policy = ForestPolicy.standard
        guard settings.forest != .off else { return .max }
        guard settings.arrangement == .singleTree else { return policy.plainLimit }
        let sizes = NSScreen.screens.map(\.frame.size)
        return (sizes.isEmpty ? [CGSize(width: 1440, height: 900)] : sizes).map { policy.treeCapacity(for: $0) }.max() ?? policy.plainLimit
    }

    /// When each tree starts growing in, for a whole-scene grow-in whose first trees start at `base`.
    private func startTimes(from base: Date) -> [URL: Date] {
        let ordered = rankedPanes(ranking), from = waveFrom
        guard ordered.count > from else { return Dictionary(uniqueKeysWithValues: ordered.map { ($0.repoURL, base) }) }
        let step = min(Self.waveStep, Self.waveSpan / Double(ordered.count - from))
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { index, pane in
            (pane.repoURL, index < from ? base : base.addingTimeInterval(Self.waveLead + Double(index - from) * step))
        })
    }

    /// Rank every repository as it stands now.
    private func takeRanking() {
        ranking = Dictionary(panes.compactMap { pane in pane.tree.map { (pane.repoURL.path, $0.lastActive) } },
                             uniquingKeysWith: { first, _ in first })
        rankedOn = Calendar.current.startOfDay(for: Date())
    }

    /// The panes with a tree, the most recently active first as `ranking` has it: ranked as the view ranks
    /// them (`ForestPolicy.rank` on each pane's seed), so the trees that grow in first are the ones that
    /// stand in front.
    private func rankedPanes(_ ranking: [String: Date]) -> [WallpaperModel] {
        let candidates = zip(panes, PinnedRepositories.seeds(panes.map(\.repoURL))).filter { $0.0.tree != nil }
        let entries = candidates.map { (id: $0.1, lastActive: ranking[$0.0.repoURL.path] ?? $0.0.tree?.lastActive ?? .distantPast) }
        return ForestPolicy.rank(entries).map { candidates[$0].0 }
    }

    /// The first hourly tick after midnight takes the ranking again; if it put the repositories in a
    /// new order the trees stand again from the ground, as when the layout changes.
    private func reRankAfterMidnight() {
        guard Calendar.current.startOfDay(for: Date()) > rankedOn, !isAwaitingTrees else { return }
        let before = rankedPanes(ranking).map(\.repoURL)
        takeRanking()
        guard rankedPanes(ranking).map(\.repoURL) != before else { return }
        logEvent("midnight: the ranking changed, the trees stand again")
        growInFromTheGround()
    }

    /// A pane's first tree: just pinned, or just started. In the orchard it grows in on its own plot.
    /// In the single tree every bough moves to make room for it, so they all grow again from the
    /// crotch (from the ground, when it's the second and the single tree is only now forming).
    private func treeArrived(_ url: URL) {
        guard isVisible else { return }
        guard !isAwaitingTrees else { return paneSettled() }
        // A repository pinned now ranks on its own history; the others keep their places.
        if ranking[url.path] == nil, let tree = panes.first(where: { $0.repoURL == url })?.tree { ranking[url.path] = tree.lastActive }
        let now = Date()
        switch (settings.arrangement, ready.count) {
        case (.singleTree, 2):
            growInFromTheGround()
            return
        case (.singleTree, 3...):
            // Every limb moves, so they all grow again: once, when the trees stop arriving.
            growIns[url] = now.addingTimeInterval(Self.lateQuiet + Self.lateLimit)
            growLate()
        case (.orchard, (ForestPolicy.standard.plainLimit + 1)...) where settings.forest != .off:
            // The rows pack again around it, so the same.
            growIns[url] = now.addingTimeInterval(Self.lateQuiet + Self.lateLimit)
            growLate()
        default:
            growIns[url] = now
        }
        finishGrowingIn()
    }

    /// Trees that arrive after the scene has begun growing (a repository pinned, or one that read slowly)
    /// move every other tree, so they grow in again together: once the arrivals pause for `lateQuiet`, or
    /// `lateLimit` after the first, not once for each (which at sixty-four repositories is sixty-four
    /// plans and grow-ins). Until then the late tree waits unseen.
    static let lateQuiet: TimeInterval = 0.6
    static let lateLimit: TimeInterval = 3.0
    private var lateArrivals: Task<Void, Never>?
    private var lateSince: Date?

    private func growLate() {
        let since = lateSince ?? Date()
        lateSince = since
        lateArrivals?.cancel()
        let wait = Date().timeIntervalSince(since) < Self.lateLimit ? Self.lateQuiet : 0
        lateArrivals = Task {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, isVisible else { return }
            lateSince = nil
            logEvent("late arrivals: the trees grow again together")
            let now = Date()
            // Boughs waiting on a rising trunk keep waiting.
            let base = settings.arrangement == .singleTree
                ? trunkGrowIn.map { max($0.addingTimeInterval(Self.trunkDuration * 0.85), now) } ?? now : now
            growIns = startTimes(from: base)
            finishGrowingIn()
        }
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
