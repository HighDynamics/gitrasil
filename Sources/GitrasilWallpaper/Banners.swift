import AppKit
import Observation
import SwiftUI
import GitrasilCore

// Names on hanging banners: each branch's on a small paper pennant tied to its tip by a thread that
// runs outward, clear of the crown, and in the single tree each repository's on a larger ribbon hung
// by two cords from its bough (`BannerLayout` places both). They're drawn as their own small views
// over the tree canvas, so a banner swaying in a gust moves its own layer and never redraws the tree.
// Unless every banner is drawn in view, what's painted in front of a banner's bough is cut out of it
// (`Occlusion`), so it hangs at its bough's depth.

/// Where every name hangs. Planned from the full-grown trees whenever they change, never per frame.
struct BannerPlan {

    struct Hanging: Equatable, Identifiable {
        let banner: BannerLayout.Banner
        /// The repository (its pane's id) and the stem (`RepoTree.commitCounts` key) it names.
        let pane: String
        let stem: String
        /// Its stem's stretch of a grow-in (`TreeLayout.schedule`): it fades in as the stem finishes.
        let stretch: TreeLayout.Stretch
        let name: String
        let ink: Color
        let alpha: Double
        let fontSize: CGFloat
        /// Its depth in the trees' paint order when something painted in front of it reaches its box
        /// (`Occlusion`); nil when nothing hides it.
        var hiddenFrom: Int?

        var id: String { banner.id }

        /// What its view covers: its tip, its thread and its pennant in every pose a gust swings it
        /// through (from dangling to nearly level, for one hanging from its bough), with room to sway.
        var box: CGRect {
            var box = banner.rect.union(CGRect(origin: banner.tip, size: .zero))
            if banner.droop > 0 {
                for step in 1...8 {
                    box = box.union(BannerLayout.turned(banner.rect, about: banner.hook, degrees: banner.side * banner.droop * Double(step) / 8))
                }
            }
            return box.insetBy(dx: -14, dy: -14)
        }
    }

    /// A repository's ribbon, in the single tree.
    struct Ribbon: Equatable, Identifiable {
        let ribbon: BannerLayout.Ribbon
        /// The repository it names: its pane's id, the name written on it, and its seed (`Pane.seed`).
        let pane: String
        let name: String
        let seed: String
        /// Its bough's stretch of a grow-in: it fades in as the bough finishes.
        let stretch: TreeLayout.Stretch
        let fontSize: CGFloat
        /// As a pennant's (`Hanging.hiddenFrom`).
        var hiddenFrom: Int?

        var id: String { ribbon.id }

        /// What its view covers: its cords and the ribbon, with room for its swing.
        var box: CGRect { ribbon.footprint.insetBy(dx: -10, dy: -10) }
    }

    /// The foliage painted in front of each tree, or each bough of the single tree: what a name could be
    /// lost behind (`Landscape.hidden`).
    struct Fronts {
        /// Each tree's or bough's foliage, in the order they're painted.
        var layers: [[CGRect]] = []
        /// Each repository's place in `layers`, by its pane's id.
        var places: [String: Int] = [:]

        /// What's painted in front of `pane`'s tree or bough, near `rect`.
        func rects(before pane: String, near rect: CGRect) -> [CGRect] {
            guard let place = places[pane], place + 1 < layers.count else { return [] }
            return layers[(place + 1)...].flatMap { $0.filter { $0.intersects(rect) } }
        }
    }

    var banners: [Hanging] = []
    var ribbons: [Ribbon] = []
    /// What hides the banners, when each hangs at its bough's depth; nil when all are drawn in view.
    var occlusion: Occlusion?
}

extension Landscape {

    /// A tree whose names are being placed: `allowance` is how many branch names may hang on it (nil for
    /// all; the forest layouts cut it).
    private struct Standing {
        let pane: String
        let stems: [TreeLayout.Stem]
        let schedule: TreeLayout.GrowInSchedule
        let frame: TreeFrame
        let allowance: Int?
        /// The repository's name when it has no ribbon of its own: its trunk's pennant carries it instead.
        var repoLabel: String?
    }

    /// Where the names hang over the trees as they stand (`panes` with their full trees): the branches'
    /// pennants and, in the single tree, the repositories' ribbons, each only if shown. `hanging` hangs
    /// the pennants from their boughs (`BannerLayout.place`); `occluded` hides each banner behind what's
    /// painted in front of its bough (`Occlusion`). Placement doesn't depend on `occluded`.
    func plan(_ panes: [Pane], arrangement: Arrangement, branchNames: Bool, repoNames: Bool, hanging: Bool = false,
              occluded: Bool = false) -> BannerPlan {
        var plan = BannerPlan()
        // Each tree by its pane's id.
        var trees: [Standing] = []
        var obstacles: [CGRect] = []
        var taken: [CGRect] = []
        var bounds = self.bounds
        // Each repository's depth in the trees' paint order, when banners hang at their boughs' depths.
        var depths: [String: Int] = [:]
        // The foliage painted in front of each repository's tree or bough, which can hide its banners.
        var fronts = BannerPlan.Fronts()
        let occlusion = occluded ? Occlusion() : nil
        if isSingleTree(panes, arrangement: arrangement) {
            let scene = scene(panes, arrangement: arrangement)
            let ready = scene.tree
            let (full, frame) = singleTree(ready, narrowed: !scene.forest.isEmpty)
            bounds = self.bounds(floor: frame.origin.y - Self.floor(treeHeight: CGFloat(full.bounds.maxY) * frame.scale))
            depths = occlusion.map { self.depths(full, of: ready, frame: frame, in: $0) } ?? [:]
            obstacles += crown([full.trunk], frame: frame)
            let crowns = full.boughs.map { crown($0.layout.stems, frame: frame) }
            for (pane, bough) in zip(ready, full.boughs) {
                trees.append(Standing(pane: pane.id, stems: bough.layout.stems, schedule: bough.layout.schedule, frame: frame,
                                      allowance: nil))
            }
            obstacles += crowns.joined()
            let ranks = Self.paintRanks(full), foliage = full.boughs.map { foliage($0.layout.stems, frame: frame) }
            let inFront = ranks.map { rank in zip(ranks, foliage).filter { $0.0 > rank }.flatMap(\.1) }
            let painted = ranks.indices.sorted { ranks[$0] < ranks[$1] }
            fronts.layers = painted.map { foliage[$0] }
            for (place, bough) in painted.enumerated() { fronts.places[ready[bough].id] = place }
            // The repositories' ribbons first, so they hang in the same places whether or not the
            // branches' pennants are shown; the pennants keep off them. Whether or not banners hang at
            // their boughs' depths, a ribbon keeps out from behind the boughs painted after its own.
            if repoNames {
                plan.ribbons = ribbons(Array(zip(ready, full.boughs)), fronts: inFront, frame: frame, obstacles: obstacles,
                                       bounds: bounds)
                taken = plan.ribbons.map(\.ribbon.footprint)
                label(&trees, without: plan.ribbons, of: ready)
            }
            // The forest behind the tree isn't named in the air: the pennants keep off its crowns.
            obstacles += forestCrowns(scene.forest, beside: full, frame: frame)
        } else {
            // Back to front, as they're painted (`drawPlanted`).
            for planted in orchard(panes).sorted(by: { ($0.forest?.line ?? 0) > ($1.forest?.line ?? 0) }) {
                if let occlusion {
                    let pane = panes[planted.index]
                    depths[pane.id] = occlusion.add(planted.full.stems, seeds: planted.full.stems.map { _ in pane.seed },
                                                    drawing: TreeDrawing(style: planted.forest?.style ?? style, now: now,
                                                                         frame: planted.frame),
                                                    groups: nil, foliage: nil).max() ?? occlusion.marks.count
                    // A tree in a row in front can hide a name too, where one couldn't keep off its crown.
                    fronts.places[pane.id] = fronts.layers.count
                    fronts.layers.append(foliage(planted.full.stems, frame: planted.frame))
                }
                trees.append(Standing(pane: panes[planted.index].id, stems: planted.full.stems, schedule: planted.full.schedule,
                                      frame: planted.frame,
                                      allowance: planted.forest.flatMap {
                                          ForestLayout.pennantAllowance(scale: planted.frame.scale, fade: $0.fade)
                                      }))
                obstacles += crown(planted.full.stems, frame: planted.frame)
            }
        }
        plan.occlusion = occlusion
        guard branchNames else { return Self.hidden(plan, depths: depths, fronts: fronts) }

        var requests: [(request: BannerLayout.Request, rank: (Bool, Bool, Date), hanging: (BannerLayout.Banner) -> BannerPlan.Hanging)] = []
        for tree in trees {
            let drawing = TreeDrawing(style: style, now: now, frame: tree.frame)
            let fontSize = max(10, (style.labelSize * tree.frame.detail).rounded())
            let font = style.labelMetricsFont(fontSize)
            // The trunk and checked-out branches first, then the most recently active, up to the allowance.
            var allowed: Set<String>?
            if let allowance = tree.allowance {
                let ranked = tree.stems.filter { $0.name != nil }.sorted { a, b in
                    if a.isTrunk != b.isTrunk { return a.isTrunk }
                    if a.isCheckedOut != b.isCheckedOut { return a.isCheckedOut }
                    return (a.commits.last?.date ?? .distantPast) > (b.commits.last?.date ?? .distantPast)
                }
                allowed = Set(ranked.prefix(allowance).compactMap(\.name))
            }
            for stem in tree.stems {
                guard let name = stem.name, let tip = stem.tip, allowed?.contains(name) ?? true else { continue }
                let shown = stem.isTrunk ? tree.repoLabel.map { "\($0) · \(name)" } ?? name : name
                let text = (shown as NSString).size(withAttributes: [.font: font])
                let size = CGSize(width: ceil(text.width) + Pennant.padding * 2 + Pennant.notch(height: text.height + 6),
                                  height: ceil(text.height) + 6)
                let point = tree.frame.point(tip.point)
                // Outward: away from the trunk's foot; straight above it, by the name.
                let dx = point.x - tree.frame.origin.x
                var rng = SeededRandom(name, -13)
                let outward: Double = abs(dx) > 8 ? (dx > 0 ? 1 : -1) : (rng.next() < 0.5 ? -1 : 1)
                let id = "\(tree.pane)\u{1F}\(name)"
                let ink = drawing.ink(stem), alpha = max(0.6, drawing.freshness(stem.commits.last))
                let stretch = tree.schedule.stretch(of: name) ?? tree.schedule.trunk
                requests.append((BannerLayout.Request(id: id, tip: point, outward: outward, size: size),
                                 (stem.isTrunk, stem.isCheckedOut, stem.commits.last?.date ?? .distantPast),
                                 { BannerPlan.Hanging(banner: $0, pane: tree.pane, stem: name, stretch: stretch, name: shown,
                                                      ink: ink, alpha: alpha, fontSize: fontSize) }))
            }
        }
        // The trunk and checked-out branches first, then the most recently active.
        requests.sort { a, b in
            if a.rank.0 != b.rank.0 { return a.rank.0 }
            if a.rank.1 != b.rank.1 { return a.rank.1 }
            return a.rank.2 > b.rank.2
        }
        let placed = BannerLayout.place(requests.map(\.request), obstacles: obstacles, taken: taken, bounds: bounds,
                                        hanging: hanging)
        let byID = Dictionary(requests.map { ($0.request.id, $0.hanging) }, uniquingKeysWith: { a, _ in a })
        plan.banners = placed.compactMap { banner in byID[banner.id].map { $0(banner) } }
        return Self.hidden(plan, depths: depths, fronts: fronts)
    }

    /// `plan` with each banner that something painted in front of its tree or bough reaches marked with
    /// its depth. A name that would be mostly lost behind the foliage in front of it (`fronts`;
    /// `mostlyHidden`) comes forward instead, drawn in front of everything, in a single tree or an orchard.
    static func hidden(_ plan: BannerPlan, depths: [String: Int], fronts: BannerPlan.Fronts) -> BannerPlan {
        var plan = plan
        guard let occlusion = plan.occlusion else { return plan }
        func behind(_ pane: String, _ box: CGRect, name: CGRect) -> Int? {
            guard let depth = depths[pane], occlusion.reaches(after: depth, into: box) else { return nil }
            return BannerLayout.share(of: name, under: fronts.rects(before: pane, near: name)) < mostlyHidden ? depth : nil
        }
        for index in plan.banners.indices {
            let hanging = plan.banners[index]
            plan.banners[index].hiddenFrom = behind(hanging.pane, hanging.box, name: hanging.banner.footprint)
        }
        for index in plan.ribbons.indices {
            let ribbon = plan.ribbons[index]
            plan.ribbons[index].hiddenFrom = behind(ribbon.pane, ribbon.box, name: ribbon.ribbon.rect)
        }
        return plan
    }

    /// How much of a name may be under the crown in front of its bough before it's drawn in front
    /// instead: hidden any more, it couldn't be read.
    static let mostlyHidden: CGFloat = 0.5

    /// A bough too short to hang a ribbon from keeps its name on its trunk's pennant.
    private func label(_ trees: inout [Standing], without ribbons: [BannerPlan.Ribbon], of panes: [Pane]) {
        let named = Set(ribbons.map(\.pane))
        let names = Dictionary(panes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for index in trees.indices where !named.contains(trees[index].pane) { trees[index].repoLabel = names[trees[index].pane] }
    }

    /// The crowns of the forest standing behind the single tree `full`, on screen.
    private func forestCrowns(_ forest: [Pane], beside full: YggdrasilLayout, frame: TreeFrame) -> [CGRect] {
        guard !forest.isEmpty else { return [] }
        return forestScene(forest, crown: CGFloat(full.bounds.width) * frame.scale).planted.flatMap {
            crown($0.full.stems, frame: $0.frame)
        }
    }

    /// The crown to keep pennants off, on screen: every stem's wood, and the leaves around each node
    /// and tip.
    private func crown(_ stems: [TreeLayout.Stem], frame: TreeFrame) -> [CGRect] {
        let leaf = style.leafSize * frame.detail
        var rects: [CGRect] = []
        func square(_ point: CGPoint, _ half: CGFloat) -> CGRect {
            CGRect(x: point.x - half, y: point.y - half, width: half * 2, height: half * 2)
        }
        for stem in stems {
            for node in stem.curve { rects.append(square(frame.point(node.point), node.width * frame.scale / 2 + 2)) }
            let leafy = stem.isTrunk ? stem.nodes.suffix(30) : stem.nodes.dropFirst()
            for node in leafy where !stem.commits.isEmpty || stem.isBud { rects.append(square(frame.point(node.point), leaf)) }
            if let tip = stem.tip, !stem.isTrunk || !stem.commits.isEmpty { rects.append(square(frame.point(tip.point), leaf * 1.5)) }
        }
        return rects
    }

    /// What a bough's wood and foliage cover, on screen, as far as its leaves, sprays and twigs reach:
    /// what it would hide of a banner behind it.
    private func foliage(_ stems: [TreeLayout.Stem], frame: TreeFrame) -> [CGRect] {
        let leaf = style.leafSize * frame.detail
        var rects: [CGRect] = []
        func square(_ point: CGPoint, _ half: CGFloat) -> CGRect {
            CGRect(x: point.x - half, y: point.y - half, width: half * 2, height: half * 2)
        }
        for stem in stems {
            // A bough's main has twigs along it (`TreeDrawing.twigs`).
            let twiggy = stem.isTrunk && !stem.commits.isEmpty
            for node in stem.curve {
                rects.append(square(frame.point(node.point), max(node.width * frame.scale / 2 + 2, twiggy ? leaf * 2 : 0)))
            }
            let leafy = stem.isTrunk ? stem.nodes.suffix(30) : stem.nodes.dropFirst()
            for node in leafy where !stem.commits.isEmpty || stem.isBud { rects.append(square(frame.point(node.point), leaf * 1.8)) }
            if let tip = stem.tip, !stem.isTrunk || !stem.commits.isEmpty { rects.append(square(frame.point(tip.point), leaf * 2.4)) }
        }
        return rects
    }

    /// Where banners may hang: under the menu bar, above the ground.
    private var bounds: CGRect { bounds(floor: Composition.groundY(size.height) - 8) }

    /// Where banners may hang over a single tree: under the menu bar, none lower than `floor`.
    private func bounds(floor: CGFloat) -> CGRect {
        CGRect(x: 6, y: Composition.top - 16, width: size.width - 12, height: floor - (Composition.top - 16))
    }

    /// How far above the ground the lowest banner on a single tree `treeHeight` tall may reach: a short
    /// front bough low on the trunk would otherwise hang its banner just above the ground.
    static func floor(treeHeight: CGFloat) -> CGFloat { max(48, treeHeight * 0.08) }

    /// Where along its bough a ribbon may hang besides the fit's stops (`Fit.ribbonStops`), as last
    /// resorts: further out, for a short bough low down whose stops are all too near the ground.
    static let fartherStops: [Double] = [0.66, 0.76, 0.86, 0.95]

    /// Each repository's ribbon, hung from the underside of its bough's first stretch, where it's
    /// still near the shared trunk, and out from behind the crown in front of its bough (`fronts`, one
    /// per bough) where it can.
    private func ribbons(_ boughs: [(pane: Pane, bough: YggdrasilLayout.Bough)], fronts: [[CGRect]], frame: TreeFrame,
                         obstacles: [CGRect], bounds: CGRect) -> [BannerPlan.Ribbon] {
        let treeFit = fit(for: boughs.count)
        let fontSize = max(14, (style.ribbonSize * frame.detail * treeFit.ribbonScale(count: boughs.count)).rounded())
        var requests: [BannerLayout.RibbonRequest] = []
        var panes: [String: (pane: Pane, stretch: TreeLayout.Stretch)] = [:]
        for ((pane, bough), front) in zip(boughs, fronts) {
            guard let stem = bough.layout.stems.first, stem.curve.count > 2 else { continue }
            let stops = treeFit.ribbonStops + Self.fartherStops.filter { $0 > (treeFit.ribbonStops.last ?? 0) }
            let anchors = stops.map { fraction -> CGPoint in
                let node = stem.curve[Int(Double(stem.curve.count - 1) * fraction)]
                let point = frame.point(node.point)
                return CGPoint(x: point.x, y: point.y + node.width * frame.scale / 2)
            }
            let id = "ribbon\u{1F}\(pane.id)"
            panes[id] = (pane, bough.layout.schedule.trunk)
            requests.append(.init(id: id, anchors: anchors, size: RibbonShape.size(pane.name, fontSize: fontSize, style: style),
                                  front: front))
        }
        return BannerLayout.hang(requests, obstacles: obstacles, bounds: bounds).compactMap { ribbon in
            panes[ribbon.id].map {
                BannerPlan.Ribbon(ribbon: ribbon, pane: $0.pane.id, name: $0.pane.name, seed: $0.pane.seed, stretch: $0.stretch,
                                  fontSize: fontSize)
            }
        }
    }
}

// MARK: - Wind

/// Now and then a gust: a few seconds in which the banners sway, then stillness. Only while it's
/// turned on and cheap to show: never while the background is covered, every display is asleep, or
/// the Mac is in Low Power Mode (battery power alone doesn't stop them). Between gusts only a one-shot
/// timer waits, and in those states not even that: it's re-armed when the background shows, a display
/// wakes or Low Power Mode ends. The one exception is the gust that turning gusts on asks for
/// (`blowNow`): Low Power Mode doesn't hold it back, since it was asked for, but there's nothing to show
/// while the background is covered or every display is asleep, so then it waits and blows the moment
/// that ends.
@MainActor
@Observable
final class Breeze {

    /// When the gust blowing now began; nil when it's still.
    private(set) var gustStart: Date?

    static let gustLength: TimeInterval = 7
    /// The pause between gusts, before its seeded jitter of up to a third either way.
    static let pause: TimeInterval = 45

    /// Whether gusts blow (the menu's setting, while banners hang). Turning it off stills them
    /// at once.
    var isEnabled = false {
        didSet { if isEnabled != oldValue { update() } }
    }

    /// Whether the background is on screen at all. Covering it stills a gust at once.
    var isVisible = true {
        didSet { if isVisible != oldValue { update() } }
    }

    /// GITRASIL_BACKGROUND_BREEZE=off keeps the banners still, whatever the setting.
    let isTurnedOff: Bool

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var count = 0
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var wakeCheck: Task<Void, Never>?

    /// The gust turning gusts on asked for hasn't blown yet: it's waiting for the background to show
    /// and a display to be awake. Only a flag, so nothing runs while it waits.
    @ObservationIgnored private var isOwed = false
    /// The gust blowing now is that one, so Low Power Mode (which stops the timer's gusts) doesn't still it.
    @ObservationIgnored private var isAsked = false

    /// What the Mac is doing: whether a display is awake, and whether it's in Low Power Mode. The Mac's
    /// own state, unless a test supplies another.
    private let isDisplayAwake: @MainActor () -> Bool
    private let isLowPowerMode: @MainActor () -> Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         isDisplayAwake: @escaping @MainActor () -> Bool = Breeze.isAnyDisplayAwake,
         isLowPowerMode: @escaping @MainActor () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }) {
        isTurnedOff = environment["GITRASIL_BACKGROUND_BREEZE"] == "off"
        self.isDisplayAwake = isDisplayAwake
        self.isLowPowerMode = isLowPowerMode
    }

    /// Whether a gust's timer is waiting. Never while gusts can't blow.
    var isArmed: Bool { timer != nil }

    /// Starts listening for what decides whether gusts may blow: displays sleeping and waking, the
    /// Mac waking and Low Power Mode.
    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.didWakeNotification] {
            let isWake = name != NSWorkspace.screensDidSleepNotification
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.update()
                    if isWake { self?.updateAfterWake() }
                }
            }))
        }
        observers.append((.default, NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }))
        update()
    }

    /// How hard it's blowing at `date`: rising and falling over the gust, 0 when still.
    func strength(at date: Date) -> Double {
        guard let gustStart else { return 0 }
        let t = date.timeIntervalSince(gustStart) / Self.gustLength
        guard t > 0, t < 1 else { return 0 }
        return pow(sin(.pi * t), 2)
    }

    /// A gust at once (gusts were just turned on): now if it can be seen, else the moment it can; the
    /// timer takes over after it (out of Low Power Mode).
    func blowNow() {
        guard isEnabled, !isTurnedOff else { return }
        isOwed = true
        blowIfOwed()
    }

    /// Whether a gust can be seen: gusts blow, the background is on screen and a display is awake.
    private var canShow: Bool {
        isEnabled && !isTurnedOff && isVisible && isDisplayAwake()
    }

    /// Whether the timer's gusts may blow now.
    private var mayBlow: Bool {
        canShow && !isLowPowerMode()
    }

    /// Arms the timer for the next gust while gusts may blow; otherwise disarms it and stills a gust
    /// in progress (the one that was asked for lasts through Low Power Mode, which stops the timer's,
    /// but not through a covered background or sleeping displays). Blows the gust that was
    /// asked for and is owed, if it can be seen now.
    func update() {
        if mayBlow {
            if timer == nil { scheduleNext() }
        } else {
            timer?.invalidate()
            timer = nil
        }
        if !isEnabled || isTurnedOff { isOwed = false }
        if gustStart != nil, !(canShow && (isAsked || !isLowPowerMode())) { gustStart = nil }
        blowIfOwed()
    }

    private func blowIfOwed() {
        guard isOwed, canShow else { return }
        timer?.invalidate()
        gust(asked: true)
    }

    /// Right after a wake a display can still read as asleep, so look again once it's up.
    private func updateAfterWake() {
        wakeCheck?.cancel()
        wakeCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    private func scheduleNext() {
        count += 1
        var rng = SeededRandom("breeze", count)
        let wait = Self.pause * rng.next(in: 0.67...1.33)
        timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.gust() }
        }
        timer?.tolerance = wait * 0.1
    }

    /// A gust now: the timer's, or (`asked`) the one turning gusts on asked for. Not private so a test can
    /// fire the timer's, whose own check of the state matters when a notification was missed.
    func gust(asked: Bool = false) {
        timer = nil
        // Missed notifications aside, the state is checked again here; the next gust is only
        // scheduled while gusts may blow.
        guard asked ? canShow : mayBlow else { return update() }
        let start = Date()
        gustStart = start
        isOwed = false
        isAsked = asked
        logEvent(asked ? "gust (asked for)" : "gust")
        Task {
            try? await Task.sleep(for: .seconds(Self.gustLength))
            if gustStart == start { gustStart = nil }
        }
        if mayBlow { scheduleNext() }
    }

    /// Whether any display is awake.
    static func isAnyDisplayAwake() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var found: UInt32 = 0
        return CGGetOnlineDisplayList(UInt32(ids.count), &ids, &found) == .success
            && ids.prefix(Int(found)).contains { CGDisplayIsAsleep($0) == 0 }
    }
}

// MARK: - Views

/// Every banner, over the trees. Its clock runs only while a gust blows (≤12 fps); each banner's
/// own drawing is fixed (`Pennant` and `RibbonShape` are equatable and drawn into their own layers),
/// so a frame of wind only turns layers.
struct BannerLayer: View {
    let plan: BannerPlan
    /// How far each banner has faded in (0…1) while its wood grows in; one not listed is shown.
    let shown: [String: Double]
    let style: WallpaperStyle
    let breeze: Breeze

    var body: some View {
        let blowing = breeze.gustStart != nil
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !blowing)) { timeline in
            let strength = breeze.strength(at: timeline.date)
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                ForEach(plan.ribbons) { ribbon in
                    // Heavier: it swings less, and the wind doesn't lift it.
                    RibbonView(ribbon: ribbon, style: style, occlusion: plan.occlusion,
                               angle: Self.sway(ribbon.id, side: 1, lift: 0, strength: strength * 0.35, seconds: seconds))
                        .opacity(shown[ribbon.id] ?? 1)
                }
                ForEach(plan.banners) { hanging in
                    let banner = hanging.banner
                    BannerView(hanging: hanging, style: style, occlusion: plan.occlusion,
                               angle: banner.droop > 0
                                   ? Self.lift(hanging.id, side: banner.side, droop: banner.droop, strength: strength, seconds: seconds)
                                   : Self.sway(hanging.id, side: banner.side, lift: 1.8, strength: strength, seconds: seconds))
                        .opacity(shown[hanging.id] ?? 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    /// A banner's swing about where it hangs, in degrees: a slow seeded pendulum, a pennant's free
    /// end (streaming to `side`) lifted by the wind by `lift`, all scaled by how hard it's blowing.
    static func sway(_ id: String, side: Double, lift: Double, strength: Double, seconds: TimeInterval) -> Double {
        guard strength > 0 else { return 0 }
        var rng = SeededRandom(id, -17)
        let period = rng.next(in: 1.8...3.2), phase = rng.next(in: 0...(2 * .pi))
        let swing = 2.6 * sin(seconds / period * 2 * .pi + phase) + 0.8 * sin(seconds / (period * 0.43) * 2 * .pi + phase * 2)
        // Positive turns clockwise: for a pennant streaming right, that drops its free end.
        return strength * side * (swing - lift)
    }

    /// How far below level a pennant hanging from its bough is held up by the wind at its strongest.
    static let lifted = 12.0

    /// A hanging pennant's turn about its hook, in degrees: dangling `droop` below level while it's
    /// still, lifted toward level (`lifted`) as a gust rises, flapping a little more than a streaming
    /// one sways, and falling back to dangling as the gust passes.
    static func lift(_ id: String, side: Double, droop: Double, strength: Double, seconds: TimeInterval) -> Double {
        let flap = sway(id, side: 1, lift: 0, strength: strength, seconds: seconds) * 1.8
        return side * (droop - (droop - lifted) * strength + flap)
    }
}

extension View {
    /// The view (covering `box` on the screen) less what's painted in front of it, when something is.
    @ViewBuilder
    func hidden(behind occlusion: Occlusion?, from depth: Int?, box: CGRect) -> some View {
        if let occlusion, let depth {
            mask(alignment: .topLeading) { OcclusionMask(occlusion: occlusion, depth: depth, box: box).equatable() }
        } else {
            self
        }
    }
}

/// A repository's ribbon: two cords from its anchor on the bough, and the ribbon hanging from them,
/// turned about the anchor by `angle`.
private struct RibbonView: View {
    let ribbon: BannerPlan.Ribbon
    let style: WallpaperStyle
    let occlusion: Occlusion?
    let angle: Double

    var body: some View {
        let hung = ribbon.ribbon
        let box = ribbon.box
        let anchor = CGPoint(x: hung.anchor.x - box.minX, y: hung.anchor.y - box.minY)
        ZStack(alignment: .topLeading) {
            Cords(anchor: anchor, ends: [hung.cordEnds.0, hung.cordEnds.1].map { end in
                CGPoint(x: end.x - box.minX,
                        y: end.y - box.minY + RibbonShape.top(at: end.x - hung.rect.minX, size: hung.rect.size))
            }, seed: HandDrawn.seed(ribbon.id), hand: style.hand)
                .stroke(style.ink.opacity(0.55), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
            RibbonShape(name: ribbon.name, seed: ribbon.seed, fontSize: ribbon.fontSize, style: style, origin: hung.rect.origin)
                .equatable()
                .frame(width: hung.rect.width, height: hung.rect.height)
                .offset(x: hung.rect.minX - box.minX, y: hung.rect.minY - box.minY)
        }
        .frame(width: box.width, height: box.height, alignment: .topLeading)
        .rotationEffect(.degrees(angle), anchor: UnitPoint(x: anchor.x / box.width, y: anchor.y / box.height))
        // Fixed on the screen: the ribbon swings behind what's in front of it.
        .hidden(behind: occlusion, from: ribbon.hiddenFrom, box: box)
        .offset(x: box.minX, y: box.minY)
    }
}

/// The two cords a ribbon hangs by, tied at one point, with a small knot there. Drawn by hand, a
/// cord isn't quite straight.
private struct Cords: Shape {
    let anchor: CGPoint
    let ends: [CGPoint]
    let seed: UInt64
    let hand: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, end) in ends.enumerated() {
            path.addLines(Sketched.line(from: anchor, to: end, seed: seed &+ UInt64(index), hand: hand))
        }
        path.addEllipse(in: CGRect(x: anchor.x - 1.8, y: anchor.y - 1.8, width: 3.6, height: 3.6))
        return path
    }
}

/// A paper banderole with the repository's name: an arched panel with a double-ruled frame, its
/// ends folding back behind it into swallowtails. In plain ink, larger and more formal than a
/// branch's pennant. Drawn once into its own layer; swaying only turns that layer.
struct RibbonShape: View, Equatable {
    let name: String
    /// Its repository's seed (`Pane.seed`), so two repositories of the same name don't wobble alike.
    let seed: String
    let fontSize: CGFloat
    let style: WallpaperStyle
    /// Where it hangs on the screen, so its grain lines up with the paper's.
    var origin: CGPoint = .zero

    /// Room around the name on the panel.
    static let padding = CGSize(width: 18, height: 4)

    static func == (a: RibbonShape, b: RibbonShape) -> Bool {
        a.name == b.name && a.seed == b.seed && a.fontSize == b.fontSize && a.origin == b.origin && a.style.bannerKey == b.style.bannerKey
    }

    /// The panel's height for a ribbon `size` tall.
    private static func panel(_ height: CGFloat) -> CGFloat { height / (1 + archRatio + dropRatio) }
    private static let archRatio: CGFloat = 0.14, dropRatio: CGFloat = 0.3, tailRatio: CGFloat = 0.8

    /// How far below the ribbon's top its panel's arched top edge is at `x` (where the cords meet it).
    static func top(at x: CGFloat, size: CGSize) -> CGFloat {
        let ph = panel(size.height), tail = ph * tailRatio
        let t = min(max((x - tail) / max(size.width - 2 * tail, 1), 0), 1)
        return ph * archRatio * (1 - 4 * t * (1 - t))
    }

    /// The ribbon's whole size for `name`: the panel, its arch, and the tails out to each side and
    /// dropped below it. The panel fits the script's letters, not its tall line.
    static func size(_ name: String, fontSize: CGFloat, style: WallpaperStyle) -> CGSize {
        let text = (name as NSString).size(withAttributes: [.font: style.ribbonMetricsFont(fontSize)])
        let panel = ceil(fontSize * 1.1) + padding.height * 2
        let width = ceil(text.width) + padding.width * 2 + panel * tailRatio * 2
        return CGSize(width: width, height: ceil(panel * (1 + archRatio + dropRatio)))
    }

    var body: some View {
        Canvas { context, size in
            let ph = Self.panel(size.height), arch = ph * Self.archRatio, drop = ph * Self.dropRatio
            let tail = ph * Self.tailRatio, notch = ph * 0.32
            let left = tail, right = size.width - tail
            let ink = style.ink, line = style.lineWidth
            let sketch = Sketch(style), seed = HandDrawn.seed(self.seed, -21)
            let grainOrigin = CGPoint(x: -origin.x, y: -origin.y)

            // The tails, behind: from each end of the panel out to a swallowtail, dropped below it.
            for side in [-1.0, 1.0] {
                let inner = side < 0 ? left : right, outer = side < 0 ? 0 : size.width
                var piece = Path()
                piece.move(to: CGPoint(x: inner, y: arch + drop))
                piece.addLine(to: CGPoint(x: outer, y: arch + drop))
                piece.addLine(to: CGPoint(x: outer - side * notch, y: arch + drop + ph / 2))
                piece.addLine(to: CGPoint(x: outer, y: arch + drop + ph))
                piece.addLine(to: CGPoint(x: inner, y: arch + drop + ph))
                piece.closeSubpath()
                let pieceSeed = seed &+ (side < 0 ? 1 : 2)
                let shape = sketch.shape(piece, seed: pieceSeed)
                context.fill(shape, with: .color(style.paper[1]))
                context.fill(shape, with: .color(ink.opacity(0.06)))
                Textures.grained(style, in: &context, size: size, origin: grainOrigin) { context in
                    sketch.stroke(piece, with: .color(ink.opacity(0.8)), width: line, seed: pieceSeed, in: &context)
                }
                // The fold where the ribbon turns back behind the panel.
                var fold = Path()
                fold.move(to: CGPoint(x: inner, y: arch + ph))
                fold.addLine(to: CGPoint(x: inner, y: arch + drop + ph))
                fold.addLine(to: CGPoint(x: inner - side * drop, y: arch + ph))
                fold.closeSubpath()
                Textures.grained(style, in: &context, size: size, origin: grainOrigin) { context in
                    context.fill(sketch.shape(fold, seed: pieceSeed &+ 10), with: .color(ink.opacity(0.55)))
                    sketch.stroke(fold, with: .color(ink.opacity(0.8)), width: line * 0.8, seed: pieceSeed &+ 10, in: &context)
                }
            }

            // The panel, arched, with an inner rule.
            func panel(inset: CGFloat) -> Path {
                var path = Path()
                path.move(to: CGPoint(x: left + inset, y: arch + inset))
                path.addQuadCurve(to: CGPoint(x: right - inset, y: arch + inset), control: CGPoint(x: size.width / 2, y: -arch + inset))
                path.addLine(to: CGPoint(x: right - inset, y: arch + ph - inset))
                path.addQuadCurve(to: CGPoint(x: left + inset, y: arch + ph - inset),
                                  control: CGPoint(x: size.width / 2, y: ph - arch - inset))
                path.closeSubpath()
                return path
            }
            context.fill(sketch.shape(panel(inset: 0), seed: seed &+ 3), with: .color(style.paper[0]))
            Textures.grained(style, in: &context, size: size, origin: grainOrigin) { context in
                if sketch.hand > 0 {
                    sketch.stroke(panel(inset: 0), with: .color(ink.opacity(0.9)), width: line * 1.5, seed: seed &+ 3, in: &context)
                    sketch.stroke(panel(inset: 3), with: .color(ink.opacity(0.45)), width: line * 0.6, seed: seed &+ 4, in: &context)
                } else {
                    context.stroke(panel(inset: 0), with: .color(ink.opacity(0.9)), style: StrokeStyle(lineWidth: line * 1.5, lineJoin: .round))
                    context.stroke(panel(inset: 3), with: .color(ink.opacity(0.45)), style: StrokeStyle(lineWidth: line * 0.6, lineJoin: .round))
                }
                let text = context.resolve(Text(name).font(style.ribbonFont(fontSize)).foregroundColor(ink.opacity(0.9)))
                context.draw(text, at: CGPoint(x: size.width / 2, y: ph / 2 + 2), anchor: .center)
            }
        }
    }
}

/// One banner: the thread from its tip, and the pennant hanging from the hook, turned by `angle`.
private struct BannerView: View {
    let hanging: BannerPlan.Hanging
    let style: WallpaperStyle
    let occlusion: Occlusion?
    let angle: Double

    var body: some View {
        let banner = hanging.banner
        // A box around the tip, the hook and the pennant, with room for its swing.
        let box = hanging.box
        ZStack(alignment: .topLeading) {
            Thread(tip: CGPoint(x: banner.tip.x - box.minX, y: banner.tip.y - box.minY),
                   hook: CGPoint(x: banner.hook.x - box.minX, y: banner.hook.y - box.minY),
                   seed: HandDrawn.seed(hanging.id), hand: style.hand)
                .stroke(style.ink.opacity(0.42), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
            Pennant(hanging: hanging, style: style)
                .equatable()
                .frame(width: banner.rect.width, height: banner.rect.height)
                .rotationEffect(.degrees(angle), anchor: UnitPoint(x: banner.side > 0 ? 0 : 1, y: 0))
                .offset(x: banner.rect.minX - box.minX, y: banner.rect.minY - box.minY)
        }
        .frame(width: box.width, height: box.height, alignment: .topLeading)
        .hidden(behind: occlusion, from: hanging.hiddenFrom, box: box)
        .offset(x: box.minX, y: box.minY)
    }
}

/// The thread: a fine line sagging a little between the tip and the hook, not quite smooth when
/// drawn by hand.
private struct Thread: Shape {
    let tip: CGPoint
    let hook: CGPoint
    let seed: UInt64
    let hand: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let length = hypot(hook.x - tip.x, hook.y - tip.y)
        let control = CGPoint(x: (tip.x + hook.x) / 2, y: (tip.y + hook.y) / 2 + length * 0.12)
        if hand > 0 {
            let steps = max(4, Int(length / 6))
            let points = (0...steps).map { k -> CGPoint in
                let t = CGFloat(k) / CGFloat(steps), u = 1 - t
                return CGPoint(x: u * u * tip.x + 2 * u * t * control.x + t * t * hook.x,
                               y: u * u * tip.y + 2 * u * t * control.y + t * t * hook.y)
            }
            path.addLines(HandDrawn.displace(points, seed: seed, amplitude: 0.5 * hand, wavelength: 30))
        } else {
            path.move(to: tip)
            path.addQuadCurve(to: hook, control: control)
        }
        path.addEllipse(in: CGRect(x: hook.x - 1.4, y: hook.y - 1.4, width: 2.8, height: 2.8))
        return path
    }
}

/// A paper swallowtail pennant with the name on it, in its branch's ink. Drawn once into its own
/// layer; swaying only turns that layer.
struct Pennant: View, Equatable {
    let hanging: BannerPlan.Hanging
    let style: WallpaperStyle

    static let padding: CGFloat = 7
    static func notch(height: CGFloat) -> CGFloat { min(7, height * 0.32) }

    static func == (a: Pennant, b: Pennant) -> Bool {
        a.hanging == b.hanging && a.style.bannerKey == b.style.bannerKey
    }

    var body: some View {
        let side = hanging.banner.side
        Canvas { context, size in
            let w = size.width, h = size.height, notch = Self.notch(height: h)
            // Streaming right: the hoist at x 0, the swallowtail at the right. Mirrored to stream left.
            var flag = Path()
            flag.move(to: CGPoint(x: 0, y: 0))
            flag.addQuadCurve(to: CGPoint(x: w, y: 1.5), control: CGPoint(x: w * 0.5, y: 2.2))
            flag.addLine(to: CGPoint(x: w - notch, y: h * 0.52))
            flag.addLine(to: CGPoint(x: w, y: h))
            flag.addQuadCurve(to: CGPoint(x: 0, y: h - 0.5), control: CGPoint(x: w * 0.5, y: h + 0.8))
            flag.closeSubpath()
            if side < 0 { flag = flag.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)) }
            let sketch = Sketch(style), seed = HandDrawn.seed(hanging.id)
            let shape = sketch.shape(flag, seed: seed)
            context.fill(shape, with: .color(style.paper[0].opacity(0.94)))
            context.fill(shape, with: .color(hanging.ink.opacity(0.07)))
            let rect = hanging.banner.rect
            Textures.grained(style, in: &context, size: size, origin: CGPoint(x: -rect.minX, y: -rect.minY)) { context in
                if sketch.hand > 0 {
                    sketch.stroke(flag, with: .color(hanging.ink.opacity(0.75 * hanging.alpha)), width: style.lineWidth * 0.8,
                                  seed: seed, in: &context)
                } else {
                    context.stroke(flag, with: .color(hanging.ink.opacity(0.75 * hanging.alpha)),
                                   style: StrokeStyle(lineWidth: style.lineWidth * 0.8, lineJoin: .round))
                }
                let text = context.resolve(Text(hanging.name).font(style.labelFont(hanging.fontSize))
                    .foregroundColor(hanging.ink.opacity(hanging.alpha)))
                let textRect = side > 0
                    ? CGRect(x: Self.padding, y: 0, width: w - Self.padding * 2 - notch, height: h)
                    : CGRect(x: Self.padding + notch, y: 0, width: w - Self.padding * 2 - notch, height: h)
                context.draw(text, at: CGPoint(x: textRect.midX, y: textRect.midY + 0.5), anchor: .center)
            }
        }
    }
}

/// Short lines drawn by hand, for the cords.
enum Sketched {
    /// A straight line from `a` to `b`, a little off true (true with a hand of 0).
    static func line(from a: CGPoint, to b: CGPoint, seed: UInt64, hand: CGFloat) -> [CGPoint] {
        guard hand > 0 else { return [a, b] }
        let steps = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 6))
        let points = (0...steps).map { k -> CGPoint in
            let t = CGFloat(k) / CGFloat(steps)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        return HandDrawn.displace(points, seed: seed, amplitude: 0.6 * hand, wavelength: 28)
    }
}
