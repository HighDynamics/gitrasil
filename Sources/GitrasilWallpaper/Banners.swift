import AppKit
import IOKit.ps
import Observation
import SwiftUI
import GitrasilCore

// Names on hanging banners: each branch's on a small paper pennant tied to its tip by a thread that
// runs outward, clear of the crown, and in the single tree each repository's on a larger ribbon hung
// by two cords from its bough (`BannerLayout` places both). They're drawn as their own small views
// over the tree canvas, so a banner swaying in a gust moves its own layer and never redraws the tree.

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

        var id: String { banner.id }
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

        var id: String { ribbon.id }
    }

    var banners: [Hanging] = []
    var ribbons: [Ribbon] = []
}

extension Landscape {

    /// Where the names hang over the trees as they stand (`panes` with their full trees): the branches'
    /// pennants and, in the single tree, the repositories' ribbons, each only if shown.
    func plan(_ panes: [Pane], arrangement: Arrangement, branchNames: Bool, repoNames: Bool) -> BannerPlan {
        var plan = BannerPlan()
        // Each tree by its pane's id.
        var trees: [(pane: String, stems: [TreeLayout.Stem], schedule: TreeLayout.GrowInSchedule, frame: TreeFrame)] = []
        var obstacles: [CGRect] = []
        var taken: [CGRect] = []
        if isSingleTree(panes, arrangement: arrangement) {
            let ready = panes.filter { $0.tree != nil }
            let (full, frame) = singleTree(ready)
            obstacles += crown([full.trunk], frame: frame)
            for (pane, bough) in zip(ready, full.boughs) {
                trees.append((pane.id, bough.layout.stems, bough.layout.schedule, frame))
                obstacles += crown(bough.layout.stems, frame: frame)
            }
            // The repositories' ribbons first, so they hang in the same places whether or not the
            // branches' pennants are shown; the pennants keep off them.
            if repoNames {
                plan.ribbons = ribbons(Array(zip(ready, full.boughs)), frame: frame, obstacles: obstacles)
                taken = plan.ribbons.map(\.ribbon.footprint)
            }
        } else {
            for planted in orchard(panes) {
                trees.append((panes[planted.index].id, planted.full.stems, planted.full.schedule, planted.frame))
                obstacles += crown(planted.full.stems, frame: planted.frame)
            }
        }
        guard branchNames else { return plan }

        var requests: [(request: BannerLayout.Request, rank: (Bool, Bool, Date), hanging: (BannerLayout.Banner) -> BannerPlan.Hanging)] = []
        for tree in trees {
            let drawing = TreeDrawing(style: style, now: now, frame: tree.frame)
            let fontSize = max(10, (style.labelSize * tree.frame.detail).rounded())
            let font = style.labelMetricsFont(fontSize)
            for stem in tree.stems {
                guard let name = stem.name, let tip = stem.tip else { continue }
                let text = (name as NSString).size(withAttributes: [.font: font])
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
                                 { BannerPlan.Hanging(banner: $0, pane: tree.pane, stem: name, stretch: stretch, name: name,
                                                      ink: ink, alpha: alpha, fontSize: fontSize) }))
            }
        }
        // The trunk and checked-out branches first, then the most recently active.
        requests.sort { a, b in
            if a.rank.0 != b.rank.0 { return a.rank.0 }
            if a.rank.1 != b.rank.1 { return a.rank.1 }
            return a.rank.2 > b.rank.2
        }
        let placed = BannerLayout.place(requests.map(\.request), obstacles: obstacles, taken: taken, bounds: bounds)
        let byID = Dictionary(requests.map { ($0.request.id, $0.hanging) }, uniquingKeysWith: { a, _ in a })
        plan.banners = placed.compactMap { banner in byID[banner.id].map { $0(banner) } }
        return plan
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

    /// Where banners may hang: under the menu bar, above the ground.
    private var bounds: CGRect {
        let ground = Composition.groundY(size.height)
        return CGRect(x: 6, y: Composition.top - 16, width: size.width - 12, height: ground - 8 - (Composition.top - 16))
    }

    /// Each repository's ribbon, hung from the underside of its bough's first stretch, where it's
    /// still near the shared trunk.
    private func ribbons(_ boughs: [(pane: Pane, bough: YggdrasilLayout.Bough)], frame: TreeFrame,
                         obstacles: [CGRect]) -> [BannerPlan.Ribbon] {
        let fontSize = max(18, (style.ribbonSize * frame.detail).rounded())
        var requests: [BannerLayout.RibbonRequest] = []
        var panes: [String: (pane: Pane, stretch: TreeLayout.Stretch)] = [:]
        for (pane, bough) in boughs {
            guard let stem = bough.layout.stems.first, stem.curve.count > 2 else { continue }
            let anchors = [0.14, 0.2, 0.26, 0.32, 0.4, 0.48, 0.56].map { fraction -> CGPoint in
                let node = stem.curve[Int(Double(stem.curve.count - 1) * fraction)]
                let point = frame.point(node.point)
                return CGPoint(x: point.x, y: point.y + node.width * frame.scale / 2)
            }
            let id = "ribbon\u{1F}\(pane.id)"
            panes[id] = (pane, bough.layout.schedule.trunk)
            requests.append(.init(id: id, anchors: anchors, size: RibbonShape.size(pane.name, fontSize: fontSize, style: style)))
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
/// the Mac is on battery or in Low Power Mode. Between gusts only a one-shot timer waits, and in those
/// states not even that: it's re-armed when the background shows, a display wakes or the power
/// changes.
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
    @ObservationIgnored private var power: PowerSourceWatcher?
    @ObservationIgnored private var wakeCheck: Task<Void, Never>?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        isTurnedOff = environment["GITRASIL_BACKGROUND_BREEZE"] == "off"
    }

    /// Starts listening for what decides whether gusts may blow: displays sleeping and waking, the
    /// Mac waking, the power source and Low Power Mode.
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
        power = PowerSourceWatcher { [weak self] in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    /// How hard it's blowing at `date`: rising and falling over the gust, 0 when still.
    func strength(at date: Date) -> Double {
        guard let gustStart else { return 0 }
        let t = date.timeIntervalSince(gustStart) / Self.gustLength
        guard t > 0, t < 1 else { return 0 }
        return pow(sin(.pi * t), 2)
    }

    /// A gust at once (gusts were just turned on), if gusts may blow; the timer takes over after it.
    func blowNow() {
        guard mayBlow else { return }
        timer?.invalidate()
        gust()
    }

    /// Whether gusts may blow now.
    private var mayBlow: Bool {
        isEnabled && !isTurnedOff && isVisible && Self.isCheapToAnimate()
    }

    /// Arms the timer for the next gust while gusts may blow; otherwise disarms it and stills a gust
    /// in progress.
    private func update() {
        if mayBlow {
            if timer == nil { scheduleNext() }
        } else {
            timer?.invalidate()
            timer = nil
            gustStart = nil
        }
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

    private func gust() {
        timer = nil
        // Missed notifications aside, the state is checked again here; the next gust is only
        // scheduled while gusts may blow.
        guard mayBlow else { return update() }
        let start = Date()
        gustStart = start
        logEvent("gust")
        Task {
            try? await Task.sleep(for: .seconds(Self.gustLength))
            if gustStart == start { gustStart = nil }
        }
        scheduleNext()
    }

    /// Still unless a display is awake and the Mac is on mains power, out of Low Power Mode.
    static func isCheapToAnimate() -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var found: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &found) == .success,
              ids.prefix(Int(found)).contains(where: { CGDisplayIsAsleep($0) == 0 }) else { return false }
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String
        return source == kIOPMACPowerKey
    }
}

/// Calls back on the main run loop when the power source changes (plugged in, on battery), also
/// while a menu is open.
private final class PowerSourceWatcher {
    private let changed: () -> Void
    private var source: CFRunLoopSource?

    init(_ changed: @escaping () -> Void) {
        self.changed = changed
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerSourceWatcher>.fromOpaque(context).takeUnretainedValue().changed()
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
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
                    RibbonView(ribbon: ribbon, style: style,
                               angle: Self.sway(ribbon.id, side: 1, lift: 0, strength: strength * 0.35, seconds: seconds))
                        .opacity(shown[ribbon.id] ?? 1)
                }
                ForEach(plan.banners) { hanging in
                    BannerView(hanging: hanging, style: style,
                               angle: Self.sway(hanging.id, side: hanging.banner.side, lift: 1.8, strength: strength,
                                                seconds: seconds))
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
}

/// A repository's ribbon: two cords from its anchor on the bough, and the ribbon hanging from them,
/// turned about the anchor by `angle`.
private struct RibbonView: View {
    let ribbon: BannerPlan.Ribbon
    let style: WallpaperStyle
    let angle: Double

    var body: some View {
        let hung = ribbon.ribbon
        let box = hung.footprint.insetBy(dx: -10, dy: -10)
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
    let angle: Double

    var body: some View {
        let banner = hanging.banner
        // A box around the tip, the hook and the pennant, with room for its swing.
        let box = banner.rect.union(CGRect(origin: banner.tip, size: .zero)).insetBy(dx: -14, dy: -14)
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
