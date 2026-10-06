import AppKit
import IOKit.ps
import Observation
import SwiftUI
import GitrasilCore

// Branch names on hanging banners: each on a small paper pennant tied to its tip by a thread that
// runs outward, clear of the crown (`BannerLayout` places them). They're drawn as their own small
// views over the tree canvas, so a pennant swaying in a gust moves its own layer and never redraws
// the tree.

/// Where every name hangs, and where each bough's name is written in the single tree. Planned from
/// the full-grown trees whenever they change, never per frame.
struct BannerPlan {

    struct Hanging: Equatable, Identifiable {
        let banner: BannerLayout.Banner
        /// The repository and the stem (`RepoTree.commitCounts` key) it names.
        let pane: String
        let stem: String
        let name: String
        let ink: Color
        let alpha: Double
        let fontSize: CGFloat

        var id: String { banner.id }
    }

    var banners: [Hanging] = []
    var boughNames: [String: CGRect] = [:]
}

extension Scene {

    /// Where the names hang over the trees as they stand (`panes` with their full trees).
    func plan(_ panes: [Pane], arrangement: Arrangement) -> BannerPlan {
        var plan = BannerPlan()
        var trees: [(pane: String, stems: [TreeLayout.Stem], frame: TreeFrame)] = []
        var obstacles: [CGRect] = []
        var taken: [CGRect] = []
        if isSingleTree(panes, arrangement: arrangement) {
            let (full, frame) = singleTree(panes.filter { $0.tree != nil })
            obstacles += crown([full.trunk], frame: frame)
            for bough in full.boughs {
                trees.append((bough.name, bough.layout.stems, frame))
                if let rect = boughNameRect(bough, frame: frame, avoiding: taken) {
                    plan.boughNames[bough.name] = rect
                    taken.append(rect)
                }
            }
        } else {
            for planted in orchard(panes) { trees.append((panes[planted.index].name, planted.full.stems, planted.frame)) }
        }

        var requests: [(request: BannerLayout.Request, rank: (Bool, Bool, Date), hanging: (BannerLayout.Banner) -> BannerPlan.Hanging)] = []
        for tree in trees {
            obstacles += crown(tree.stems, frame: tree.frame)
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
                requests.append((BannerLayout.Request(id: id, tip: point, outward: outward, size: size),
                                 (stem.isTrunk, stem.isCheckedOut, stem.commits.last?.date ?? .distantPast),
                                 { BannerPlan.Hanging(banner: $0, pane: tree.pane, stem: name, name: name, ink: ink,
                                                      alpha: alpha, fontSize: fontSize) }))
            }
        }
        // The trunk and checked-out branches first, then the most recently active.
        requests.sort { a, b in
            if a.rank.0 != b.rank.0 { return a.rank.0 }
            if a.rank.1 != b.rank.1 { return a.rank.1 }
            return a.rank.2 > b.rank.2
        }
        let ground = Composition.groundY(size.height)
        let bounds = CGRect(x: 6, y: Composition.top - 16, width: size.width - 12, height: ground - 8 - (Composition.top - 16))
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

    /// A repository's name at the foot of its bough, as quiet as a branch's name: under a leaning
    /// bough, where there's no wood, or beside an upright one; nil when every spot is taken.
    private func boughNameRect(_ bough: YggdrasilLayout.Bough, frame: TreeFrame, avoiding taken: [CGRect]) -> CGRect? {
        guard let stem = bough.layout.stems.first, stem.curve.count > 2 else { return nil }
        let font = style.labelMetricsFont(max(10, (style.labelSize * frame.detail).rounded()))
        let measured = (bough.name as NSString).size(withAttributes: [.font: font])
        let size = CGSize(width: ceil(measured.width) + 2, height: ceil(measured.height))
        var rng = SeededRandom(bough.name, -11)
        let heading = bough.planting.heading
        let side: CGFloat = heading < -0.1 ? -1 : heading > 0.1 ? 1 : (rng.next() < 0.5 ? -1 : 1)
        for fraction in [0.12, 0.2, 0.28, 0.36] {
            let node = stem.curve[Int(Double(stem.curve.count - 1) * fraction)]
            let point = frame.point(node.point)
            let gap = node.width * frame.scale / 2 + 6
            // The side of the bough facing the ground (or, upright, its own side).
            let normal = abs(heading) > 0.1
                ? CGPoint(x: -cos(node.heading) * side * -1, y: abs(sin(node.heading)))
                : CGPoint(x: side, y: 0)
            let length = max(hypot(normal.x, normal.y), 0.001)
            let center = CGPoint(x: point.x + normal.x / length * (gap + size.height / 2),
                                 y: point.y + normal.y / length * (gap + size.height / 2))
            let x = side > 0 ? center.x : center.x - size.width
            let rect = CGRect(x: x, y: center.y - size.height / 2, width: size.width, height: size.height)
            if !taken.contains(where: { $0.insetBy(dx: -4, dy: -1).intersects(rect) }) { return rect }
        }
        return nil
    }
}

// MARK: - Wind

/// Now and then a gust: a few seconds in which the pennants sway, then stillness. Only when it's
/// cheap to show: never while the background is covered, the display is asleep, the Mac is on
/// battery or in Low Power Mode. Between gusts nothing ticks.
@MainActor
@Observable
final class Breeze {

    /// When the gust blowing now began; nil when it's still.
    private(set) var gustStart: Date?

    static let gustLength: TimeInterval = 7
    /// The pause between gusts, before its seeded jitter of up to a third either way.
    private let pause: TimeInterval
    private let enabled: Bool
    private let allowed: () -> Bool
    private var timer: Timer?
    private var count = 0

    /// - Parameter allowed: whether the background is on screen at all.
    init(allowed: @escaping () -> Bool, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.allowed = allowed
        // GITRASIL_BACKGROUND_BREEZE=off keeps the pennants still; =often gusts every twenty seconds or so
        // (to look at it, or measure it).
        let setting = environment["GITRASIL_BACKGROUND_BREEZE"]
        enabled = setting != "off"
        pause = setting == "often" ? 20 : 45
    }

    func start() {
        guard enabled else { return }
        scheduleNext()
    }

    /// How hard it's blowing at `date`: rising and falling over the gust, 0 when still.
    func strength(at date: Date) -> Double {
        guard let gustStart else { return 0 }
        let t = date.timeIntervalSince(gustStart) / Self.gustLength
        guard t > 0, t < 1 else { return 0 }
        return pow(sin(.pi * t), 2)
    }

    private func scheduleNext() {
        count += 1
        var rng = SeededRandom("breeze", count)
        let wait = pause * rng.next(in: 0.67...1.33)
        timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.gust() }
        }
        timer?.tolerance = wait * 0.1
    }

    private func gust() {
        defer { scheduleNext() }
        guard allowed(), Self.isCheapToAnimate() else { return }
        let start = Date()
        gustStart = start
        print("[\(start.formatted(.dateTime.hour().minute().second()))] gust")
        fflush(stdout)
        Task {
            try? await Task.sleep(for: .seconds(Self.gustLength))
            if gustStart == start { gustStart = nil }
        }
    }

    /// Still unless the display is awake and the Mac is on mains power, out of Low Power Mode.
    static func isCheapToAnimate() -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return false }
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String
        return source == kIOPMACPowerKey
    }
}

// MARK: - Views

/// Every banner, over the trees. Its clock runs only while a gust blows (≤12 fps); each pennant's
/// own drawing is fixed (`Pennant` is equatable and drawn into its own layer), so a frame of wind
/// only turns layers.
struct BannerLayer: View {
    let banners: [BannerPlan.Hanging]
    /// Banners whose stem is growing in: hidden until it's grown, then fading in.
    let hidden: Set<String>
    let style: WallpaperStyle
    let breeze: Breeze

    var body: some View {
        let blowing = breeze.gustStart != nil
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !blowing)) { timeline in
            let strength = breeze.strength(at: timeline.date)
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                ForEach(banners) { hanging in
                    let isHidden = hidden.contains(hanging.id)
                    BannerView(hanging: hanging, style: style, angle: Self.sway(hanging, strength: strength, seconds: seconds))
                        .opacity(isHidden ? 0 : 1)
                        .animation(isHidden ? nil : .easeIn(duration: 0.7), value: isHidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    /// A pennant's swing about its hook, in degrees: a slow seeded pendulum, its free end lifted a
    /// little by the wind, both scaled by how hard it's blowing.
    static func sway(_ hanging: BannerPlan.Hanging, strength: Double, seconds: TimeInterval) -> Double {
        guard strength > 0 else { return 0 }
        var rng = SeededRandom(hanging.id, -17)
        let period = rng.next(in: 1.8...3.2), phase = rng.next(in: 0...(2 * .pi))
        let swing = 2.6 * sin(seconds / period * 2 * .pi + phase) + 0.8 * sin(seconds / (period * 0.43) * 2 * .pi + phase * 2)
        // Positive turns clockwise: for a pennant streaming right, that drops its free end.
        return strength * hanging.banner.side * (swing - 1.8)
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
                   hook: CGPoint(x: banner.hook.x - box.minX, y: banner.hook.y - box.minY))
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

/// The thread: a fine line sagging a little between the tip and the hook.
private struct Thread: Shape {
    let tip: CGPoint
    let hook: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let length = hypot(hook.x - tip.x, hook.y - tip.y)
        path.move(to: tip)
        path.addQuadCurve(to: hook, control: CGPoint(x: (tip.x + hook.x) / 2, y: (tip.y + hook.y) / 2 + length * 0.12))
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
        a.hanging == b.hanging && a.style.paper == b.style.paper && a.style.ink == b.style.ink
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
            context.fill(flag, with: .color(style.paper[0].opacity(0.94)))
            context.fill(flag, with: .color(hanging.ink.opacity(0.07)))
            context.stroke(flag, with: .color(hanging.ink.opacity(0.75 * hanging.alpha)),
                           style: StrokeStyle(lineWidth: style.lineWidth * 0.8, lineJoin: .round))
            let text = context.resolve(Text(hanging.name).font(style.labelFont(hanging.fontSize))
                .foregroundColor(hanging.ink.opacity(hanging.alpha)))
            let textRect = side > 0
                ? CGRect(x: Self.padding, y: 0, width: w - Self.padding * 2 - notch, height: h)
                : CGRect(x: Self.padding + notch, y: 0, width: w - Self.padding * 2 - notch, height: h)
            context.draw(text, at: CGPoint(x: textRect.midX, y: textRect.midY + 0.5), anchor: .center)
        }
    }
}
