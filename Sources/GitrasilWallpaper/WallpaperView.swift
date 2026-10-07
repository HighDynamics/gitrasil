import SwiftUI
import GitrasilCore

/// The wallpaper: each pinned repository grown as a tree (`TreeLayout`). As an orchard, a tree per
/// repository spaced along one ground; as a single tree (`YggdrasilLayout`), one shared trunk with a
/// bough per repository. Everything is one Canvas inside a TimelineView whose clock is paused unless
/// a limb is growing in, so an idle desktop costs no frames.
struct WallpaperView: View {
    let background: BackgroundModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var plans = PlanCache()

    var body: some View {
        let medium = background.settings.medium
        let style = WallpaperStyle.make(medium, dark: colorScheme == .dark)
        let panes = background.panes
        let arrangement = background.settings.arrangement
        let showsBranchNames = background.settings.showsBranchNames
        let showsRepoNames = background.settings.showsRepoNames
        let now = background.now
        let seeds = PinnedRepositories.seeds(panes.map(\.repoURL))
        // Read each pane here so Observation redraws when one publishes a new tree or growth.
        let growing = background.isGrowingIn || panes.contains { pane in
            let _ = (pane.tree, pane.growth, pane.problem)
            return pane.growthStart != nil
        }
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    Self.drawPaper(size: size, style: style, ground: !panes.isEmpty, in: &context)
                }
                if panes.isEmpty {
                    Text("Pin a repository from the menu bar to grow its tree here.")
                        .font(style.captionFont.weight(.regular))
                        .foregroundStyle(style.captionInk)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !growing)) { timeline in
                        let date = timeline.date
                        let panes = zip(panes, seeds).map { pane, seed in
                            Pane(pane, seed: seed, grown: pane.grown(at: date), growIn: background.growIn(pane.repoURL, at: date))
                        }
                        let trunkGrowIn = background.trunkGrowIn(at: date)
                        Canvas { context, size in
                            Landscape(style: style, now: now, size: size, trunkGrowIn: trunkGrowIn)
                                .draw(panes, arrangement: arrangement, in: &context)
                        }
                    }
                    if showsBranchNames || showsRepoNames {
                        // The names hang where the full-grown trees put them, planned only when a tree or
                        // what's shown changes, not on every redraw.
                        let key = PlanCache.Key(dark: colorScheme == .dark, medium: medium, size: proxy.size, now: now,
                                                arrangement: arrangement, branchNames: showsBranchNames,
                                                repoNames: showsRepoNames, trees: panes.map { .init(id: $0.repoURL.path, tree: $0.tree) })
                        let plan = plans.plan(for: key) {
                            Landscape(style: style, now: now, size: proxy.size, trunkGrowIn: nil).plan(
                                zip(panes, seeds).map { Pane($0, seed: $1) },
                                arrangement: arrangement, branchNames: showsBranchNames, repoNames: showsRepoNames)
                        }
                        BannerLayer(plan: plan, hidden: hiddenBanners(plan), style: style, breeze: background.breeze)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    /// Banners on wood that's growing in: hidden until it has grown, then fading in. A repository's
    /// ribbon waits for its whole bough.
    private func hiddenBanners(_ plan: BannerPlan) -> Set<String> {
        let panes = Dictionary(background.panes.map { ($0.repoURL.path, $0) }, uniquingKeysWith: { a, _ in a })
        func growingIn(_ id: String) -> Bool {
            guard let pane = panes[id] else { return false }
            return background.trunkGrowIn != nil || background.growIns[pane.repoURL] != nil
        }
        let banners = plan.banners.filter { hanging in
            guard let pane = panes[hanging.pane] else { return false }
            return growingIn(hanging.pane) || pane.growthStart != nil && pane.growth[hanging.stem] != nil
        }
        return Set(banners.map(\.id) + plan.ribbons.filter { growingIn($0.pane) }.map(\.id))
    }

    /// The paper, and the ground when there are trees to stand on it.
    static func drawPaper(size: CGSize, style: WallpaperStyle, ground: Bool, in context: inout GraphicsContext) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: style.paper), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
        let wash = rect.insetBy(dx: size.width * 0.1, dy: size.height * 0.08)
        context.fill(Path(ellipseIn: wash), with: .radialGradient(
            Gradient(colors: [style.wash, .clear]),
            center: CGPoint(x: wash.midX, y: wash.midY), startRadius: 0, endRadius: wash.width / 2))
        // The medium's surface: charcoal paper's tooth, a board's dust (made once, tiled).
        if let surface = Textures.surface(style, dark: context.environment.colorScheme == .dark,
                                          scale: context.environment.displayScale) {
            var tooth = context
            tooth.opacity = style.surface
            tooth.fill(Path(rect), with: .tiledImage(surface))
        }
        if style.smear != .clear { smears(size: size, style: style, in: &context) }
        // Fibres: short faint strokes at fixed, seeded places, so the paper never shimmers.
        var rng = SeededRandom(seed: 0x9E3779B9)
        var fibres = Path()
        for _ in 0..<Int(size.width * size.height / 9000) {
            let x = rng.next() * size.width, y = rng.next() * size.height
            let angle = rng.next() * .pi, length = 4 + rng.next() * 10
            fibres.move(to: CGPoint(x: x, y: y))
            fibres.addLine(to: CGPoint(x: x + cos(angle) * length, y: y + sin(angle) * length))
        }
        context.stroke(fibres, with: .color(style.fibre), lineWidth: 0.6)
        if ground {
            Textures.grained(style, in: &context, size: size) { drawGround(size: size, style: style, in: &$0) }
        }
    }

    /// Old erasing on a board: broad, faint arcs of chalk wiped across it, at seeded places.
    private static func smears(size: CGSize, style: WallpaperStyle, in context: inout GraphicsContext) {
        var rng = SeededRandom("smears")
        for _ in 0..<Int(max(size.width * size.height / 120_000, 6)) {
            let center = CGPoint(x: rng.next() * size.width, y: rng.next() * size.height)
            let radius = 180 + rng.next() * 420, start = rng.next() * 2 * .pi, sweep = 0.4 + rng.next() * 0.8
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: .radians(start), endAngle: .radians(start + sweep), clockwise: false)
            context.stroke(arc, with: .color(style.smear.opacity(0.4 + rng.next() * 0.6)),
                           style: StrokeStyle(lineWidth: 30 + rng.next() * 60, lineCap: .round))
        }
    }

    /// One hand-drawn horizon across the whole screen, every tree standing on it, with sparse tufts.
    private static func drawGround(size: CGSize, style: WallpaperStyle, in context: inout GraphicsContext) {
        let y = Composition.groundY(size.height)
        var line = Path()
        var rng = SeededRandom("ground")
        let phase = rng.next() * .pi * 2
        line.move(to: CGPoint(x: 0, y: y))
        for x in stride(from: 0, through: size.width, by: 12) {
            let wave = sin(x / 210 + phase) * 1.6 + sin(x / 57 + phase * 2) * style.wobble * 0.6
            line.addLine(to: CGPoint(x: x, y: y + wave))
        }
        Sketch(style).stroke(line, with: .color(style.ink.opacity(0.5)), width: style.lineWidth,
                             seed: HandDrawn.seed("ground"), in: &context)
        var tufts = Path()
        for x in stride(from: CGFloat(20), through: size.width, by: 26) where rng.next() < 0.45 {
            let base = CGPoint(x: x + rng.next() * 14, y: y + sin(x / 210 + phase) * 1.6)
            for _ in 0..<(2 + Int(rng.next() * 3)) {
                let lean = (rng.next() - 0.5) * 0.9, height = 3 + rng.next() * 6
                tufts.move(to: base)
                tufts.addQuadCurve(to: CGPoint(x: base.x + sin(lean) * height * 1.4, y: base.y - height),
                                   control: CGPoint(x: base.x, y: base.y - height * 0.6))
            }
        }
        context.stroke(tufts, with: .color(style.ink.opacity(0.32)), lineWidth: style.lineWidth * 0.7)
    }
}

/// The last banner plan a window made, kept until anything it was planned from changes. Planning
/// measures every banner against the whole crown, so it's too slow to redo on every redraw (a growth
/// starting or ending, a grow-in, the hourly tick).
final class PlanCache {
    struct Key: Equatable {
        struct Tree: Equatable {
            let id: String
            let tree: RepoTree?
        }
        let dark: Bool
        /// Each medium writes names in its own hand, so their banners are sized differently.
        let medium: Medium
        let size: CGSize
        let now: Date
        let arrangement: Arrangement
        let branchNames: Bool
        let repoNames: Bool
        let trees: [Tree]
    }

    private var key: Key?
    private var plan = BannerPlan()

    func plan(for key: Key, make: () -> BannerPlan) -> BannerPlan {
        if key != self.key {
            plan = make()
            self.key = key
        }
        return plan
    }
}

/// Where things sit on the screen, shared by the ground and every tree so they meet.
enum Composition {
    /// The ground line: high enough off the bottom to clear the Dock's usual reach.
    static func groundY(_ height: CGFloat) -> CGFloat { height - max(96, height * 0.13) }
    /// Clear of the menu bar.
    static let top: CGFloat = 44
    /// The height a full-grown tree is drawn for, crown included, in tree units (`TreeLayout`).
    static let nominalHeight = 1.45
    /// An orchard plot's width in tree units: the trees share one scale, so each is drawn as big as
    /// its own history makes it, and a crown a little wider than its plot reaches into the next.
    static let plotWidth = 1.3
}

// MARK: - Arrangements

/// One repository as it's drawn this frame.
struct Pane {
    /// Its path: what its banners are keyed by, since two repositories can share a name.
    let id: String
    /// Its folder's name, as written under its tree or on its ribbon.
    let name: String
    /// What its tree's shape is seeded from (`PinnedRepositories.seeds`).
    let seed: String
    let tree: RepoTree?
    let problem: String?
    /// Commits grown in so far, while a limb is growing in.
    let grown: [String: Double]
    /// How far the whole tree (or bough) is in growing in from nothing, while it is.
    let growIn: Double?

    @MainActor init(_ model: WallpaperModel, seed: String, grown: [String: Double] = [:], growIn: Double? = nil) {
        id = model.repoURL.path
        name = model.repoName
        self.seed = seed
        tree = model.tree
        problem = model.problem
        self.grown = grown
        self.growIn = growIn
    }
}

/// Lays the trees out on the screen and draws them, in either arrangement.
struct Landscape {
    let style: WallpaperStyle
    let now: Date
    let size: CGSize
    /// How far the single tree's shared trunk has risen, while it's rising.
    let trunkGrowIn: Double?

    /// A pane's full-grown tree and where it stands on the screen.
    struct Planted {
        let index: Int
        let full: TreeLayout
        let frame: TreeFrame
    }

    /// The trees in `arrangement`, broken up by the medium's grain.
    func draw(_ panes: [Pane], arrangement: Arrangement, in context: inout GraphicsContext) {
        Textures.grained(style, in: &context, size: size) { context in
            if isSingleTree(panes, arrangement: arrangement) {
                drawSingleTree(panes, in: &context)
            } else {
                drawOrchard(panes, in: &context)
            }
        }
    }

    /// The single tree takes two trees at least; with one it's that tree, in the orchard.
    func isSingleTree(_ panes: [Pane], arrangement: Arrangement) -> Bool {
        arrangement == .singleTree && panes.filter { $0.tree != nil }.count > 1
    }

    /// A tree per repository, each standing in its own plot along the ground. Every tree is drawn at
    /// one shared scale (set by the screen and the number of plots, never by another tree), so a
    /// sapling stands small beside a full-grown tree; a tree only shrinks when it outgrows the
    /// screen's height or spills well past its plot. Each is planted a seeded touch off its plot's
    /// centre, so the row isn't ruled.
    func orchard(_ panes: [Pane]) -> [Planted] {
        let plot = size.width / CGFloat(panes.count)
        let tall = Composition.groundY(size.height) - Composition.top - TreeFrame.margin
        let shared = min(tall / Composition.nominalHeight, plot / Composition.plotWidth)
        return panes.enumerated().compactMap { index, pane in
            guard let tree = pane.tree else { return nil }
            let full = TreeLayout(tree: tree, seed: pane.seed)
            var rng = SeededRandom(pane.seed, -9)
            let x = plot * (CGFloat(index) + 0.5) + (panes.count > 1 ? plot * rng.next(in: -0.05...0.05) : 0)
            let frame = TreeFrame(size: size, bounds: full.bounds, nominalHeight: Composition.nominalHeight,
                                  scale: shared, maxWidth: min(plot * 1.45, size.width - 2 * TreeFrame.margin), x: x)
            return Planted(index: index, full: full, frame: frame)
        }
    }

    func drawOrchard(_ panes: [Pane], in context: inout GraphicsContext) {
        let plot = size.width / CGFloat(panes.count)
        for (index, pane) in panes.enumerated() where pane.tree == nil {
            if let problem = pane.problem {
                problemText(problem, at: CGPoint(x: plot * (CGFloat(index) + 0.5), y: size.height / 2), in: &context)
            }
        }
        for planted in orchard(panes) {
            let pane = panes[planted.index], tree = pane.tree!
            let layout = pane.growIn.map { TreeLayout(tree: tree, seed: pane.seed, growIn: $0) }
                ?? (pane.grown.isEmpty ? planted.full : TreeLayout(tree: tree, seed: pane.seed, grown: pane.grown))
            let drawing = TreeDrawing(style: style, now: now, frame: planted.frame)
            drawing.shadow(width: planted.full.bounds.width, in: &context)
            drawing.plate(pane.name, in: &context)
            drawing.draw(layout.stems, seeds: layout.stems.map { _ in pane.seed }, parents: layout.stems.map { $0.fork?.parent },
                         groundStem: layout.stems.first, rootSeed: pane.seed, in: &context)
            if let problem = pane.problem {
                problemText(problem, at: CGPoint(x: planted.frame.origin.x, y: size.height / 2), in: &context)
            }
        }
    }

    /// One tree for every repository with a tree (`ready`): a shared trunk, a bough each, fanned in
    /// pin order, and where it stands.
    func singleTree(_ ready: [Pane]) -> (full: YggdrasilLayout, frame: TreeFrame) {
        // A bough's name is its seed: it sets the bough's lean.
        let full = YggdrasilLayout(repos: ready.map { .init(name: $0.seed, tree: $0.tree!) })
        let tall = Composition.groundY(size.height) - Composition.top - TreeFrame.margin
        // Its boughs lean, so it's rarely as tall as its trees would be on their own.
        let nominal = YggdrasilLayout.crotchHeight + Composition.nominalHeight * 0.82
        let frame = TreeFrame(size: size, bounds: full.bounds, nominalHeight: nominal, scale: tall / nominal,
                              maxWidth: size.width - 2 * TreeFrame.margin, x: size.width / 2)
        return (full, frame)
    }

    /// The single tree (each repository's name hangs on its ribbon over it: `BannerLayer`).
    func drawSingleTree(_ panes: [Pane], in context: inout GraphicsContext) {
        let ready = panes.filter { $0.tree != nil }
        let (full, frame) = singleTree(ready)
        let still = trunkGrowIn == nil && ready.allSatisfy { $0.grown.isEmpty && $0.growIn == nil }
        let layout = still ? full : YggdrasilLayout(repos: ready.map {
            .init(name: $0.seed, tree: $0.tree!, grown: $0.grown, growIn: $0.growIn)
        }, trunkGrowIn: trunkGrowIn)
        let drawing = TreeDrawing(style: style, now: now, frame: frame)
        let stems = [layout.trunk] + layout.boughs.flatMap(\.layout.stems)
        // Each bough's stems are seeded from its repository, as an orchard tree's are.
        let seeds = ["yggdrasil"] + layout.boughs.flatMap { bough in bough.layout.stems.map { _ in bough.name } }
        // A stem's fork names its parent among its own bough's stems; a bough's foot grows out of the
        // shared trunk.
        var parents: [Int?] = [nil]
        for bough in layout.boughs {
            let offset = parents.count
            parents += bough.layout.stems.map { stem in stem.fork.map { $0.parent.map { $0 + offset } ?? 0 } }
        }
        drawing.shadow(width: full.bounds.width, in: &context)
        drawing.draw(stems, seeds: seeds, parents: parents, groundStem: layout.trunk, rootSeed: "yggdrasil", in: &context)
        let problems = panes.compactMap { pane in pane.problem.map { "\(pane.name): \($0)" } }
        if !problems.isEmpty {
            problemText(problems.joined(separator: "   "),
                        at: CGPoint(x: size.width / 2, y: Composition.groundY(size.height) + 56), in: &context)
        }
    }

    private func problemText(_ text: String, at point: CGPoint, in context: inout GraphicsContext) {
        context.draw(Text(text).font(style.captionFont).foregroundColor(style.captionInk), at: point, anchor: .center)
    }
}

// MARK: - Geometry

/// Maps tree units to the screen: the trunk's foot on the ground line at `x`, unless the crown would
/// spill off a side. A tree is drawn at the scale it's given and shrinks only when it outgrows the
/// height for a nominal tree or `maxWidth`, so a new commit doesn't rescale the picture.
struct TreeFrame {
    let size: CGSize
    let scale: CGFloat
    let origin: CGPoint

    /// Room kept around the crown for leaves and the names at the tips.
    static let margin: CGFloat = 40

    /// How large leaves and names are drawn: in step with the tree, within limits, so a small tree in a
    /// narrow plot isn't buried under them.
    var detail: CGFloat { min(max(scale / 520, 0.62), 1.15) }

    init(size: CGSize, bounds: CGRect, nominalHeight: Double, scale: CGFloat, maxWidth: CGFloat, x: CGFloat) {
        self.size = size
        let ground = Composition.groundY(size.height)
        let tall = ground - Composition.top - Self.margin
        var scale = min(scale, tall / nominalHeight)
        if bounds.maxY > 0 { scale = min(scale, tall / bounds.maxY) }
        if bounds.width > 0 { scale = min(scale, maxWidth / bounds.width) }
        self.scale = max(scale, 1)
        var x = x
        x = max(x, Self.margin - bounds.minX * self.scale)
        x = min(x, size.width - Self.margin - bounds.maxX * self.scale)
        origin = CGPoint(x: x, y: ground)
    }

    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y - p.y * scale) }

    /// A heading (radians from straight up, right positive) as a screen direction.
    static func direction(_ heading: Double) -> CGPoint { CGPoint(x: sin(heading), y: -cos(heading)) }
}

// MARK: - Drawing

/// The tree's strokes, all styled from `style`. Every variation is seeded from what's drawn (a
/// branch's name and a commit's place on it, never time), so a redraw draws the same tree.
struct TreeDrawing {
    let style: WallpaperStyle
    let now: Date
    let frame: TreeFrame

    /// The wood and foliage of `stems` (names hang on banners over the canvas: `BannerLayer`),
    /// with roots spreading from `groundStem`'s foot. `seeds` are each stem's repository's seed
    /// (`Pane.seed`), and `rootSeed` the roots'. `parents` are each stem's parent, as an index into
    /// `stems` (before it), or nil for one standing on the ground.
    func draw(_ stems: [TreeLayout.Stem], seeds: [String], parents: [Int?], groundStem: TreeLayout.Stem?, rootSeed: String,
              in context: inout GraphicsContext) {
        for stem in stems { canopy(stem, in: &context) }
        let outlines = stems.map(outline)
        let woodSeeds = zip(stems, seeds).map { woodSeed($0, repo: $1) }
        let tapers = zip(outlines, woodSeeds).map { samples, seed in
            samples.count >= 2 ? taper(samples, seed: seed) : Taper()
        }
        let shapes = tapers.map(\.shape)
        let roots = groundStem.map { roots(of: $0, seed: rootSeed) } ?? []
        if style.layeredWood {
            strokes(stems, outlines, shapes, woodSeeds, roots: roots, in: &context)
        } else {
            // A stem growing out of other wood has a rounded base, so no cut end shows past its parent.
            let feet = zip(stems, outlines).compactMap { stem, samples -> Path? in
                guard stem.fork != nil, let base = samples.first else { return nil }
                let r = base.width / 2
                return Path(ellipseIn: CGRect(x: base.point.x - r, y: base.point.y - r, width: 2 * r, height: 2 * r))
            }
            wood(stems, shapes + feet, roots: roots, in: &context)
        }
        for (stem, samples) in zip(stems, outlines) { bark(stem, samples, in: &context) }
        for (stem, samples) in zip(stems, outlines) { ridge(stem, samples, in: &context) }
        tint(stems, outlines, shapes, parents: parents, in: &context)
        if style.contour > 0 { contours(stems, outlines, tapers, woodSeeds, roots: roots, rootSeed: rootSeed, in: &context) }
        for (stem, seed) in zip(stems, seeds) { leaves(stem, repo: seed, in: &context) }
        for (stem, seed) in zip(stems, seeds) where stem.isCheckedOut { blossom(stem, repo: seed, in: &context) }
    }

    /// A stem that bears leaves: any but a shared trunk, which has no commits of its own.
    private func isLeafy(_ stem: TreeLayout.Stem) -> Bool { stem.isBud || !stem.commits.isEmpty }

    // MARK: Inks and age

    func ink(_ stem: TreeLayout.Stem) -> Color {
        stem.isTrunk ? style.ink : stem.name.map(style.ink(forBranch:)) ?? style.ink
    }

    private func leafInk(_ stem: TreeLayout.Stem) -> Color { stem.isTrunk ? style.leafInk : ink(stem) }

    /// How strongly a commit is drawn, from its age.
    func freshness(_ commit: RepoTree.Commit?) -> Double {
        guard let commit else { return 1 }
        return style.opacity(ageDays: now.timeIntervalSince(commit.date) / 86_400)
    }

    /// Freshness rescaled so the fade floor is 0 and a brand-new commit is 1.
    private func vigour(_ commit: RepoTree.Commit?) -> Double {
        style.fadeFloor < 1 ? (freshness(commit) - style.fadeFloor) / (1 - style.fadeFloor) : 1
    }

    private func tipCommit(_ stem: TreeLayout.Stem) -> RepoTree.Commit? { stem.commits.last }

    // MARK: Wood

    /// A stem's centreline through its curve, smoothed (Catmull–Rom), sampled with widths in points:
    /// (point, width) pairs from base to tip.
    private func outline(_ stem: TreeLayout.Stem) -> [(point: CGPoint, width: CGFloat)] {
        let nodes = stem.curve
        guard nodes.count >= 2 else { return [] }
        let points = nodes.map { frame.point($0.point) }
        var samples: [(CGPoint, CGFloat)] = []
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let w1 = nodes[i].width * frame.scale, w2 = nodes[i + 1].width * frame.scale
            // Finer along the first stretch, where the collar narrows.
            let length = hypot(p2.x - p1.x, p2.y - p1.y)
            let steps = i == 0 && stem.fork != nil ? max(1, min(30, Int(length / 1.5))) : max(1, min(10, Int(length / 6)))
            for s in 0..<steps {
                let t = CGFloat(s) / CGFloat(steps)
                let t2 = t * t, t3 = t2 * t
                func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                samples.append((CGPoint(x: axis(p0.x, p1.x, p2.x, p3.x), y: axis(p0.y, p1.y, p2.y, p3.y)),
                                w1 + (w2 - w1) * t))
            }
        }
        samples.append((points[points.count - 1], nodes[nodes.count - 1].width * frame.scale))
        // A collar where it grows out of other wood: flared at the fork, easing to its own width.
        if let fork = stem.fork {
            let own = nodes[0].width, angle = nodes[0].heading - fork.heading
            var distance: CGFloat = 0
            for i in samples.indices {
                if i > 0 { distance += hypot(samples[i].0.x - samples[i - 1].0.x, samples[i].0.y - samples[i - 1].0.y) }
                let collar = TreeLayout.collarWidth(at: distance / frame.scale, own: own, parentWidth: fork.width, angle: angle)
                samples[i].1 = max(samples[i].1, collar * frame.scale)
            }
        }
        // The trunk flares into its roots just above the ground.
        if stem.isTrunk {
            let flare = 0.07 * frame.scale
            samples = samples.map { point, width in
                let h = frame.origin.y - point.y
                return (point, h < flare ? width * (1 + 0.8 * pow(1 - h / flare, 2)) : width)
            }
        }
        return samples.map { (point: $0.0, width: max($0.1, 0.9)) }
    }

    /// A stem's shape, and its two edges from base to tip.
    struct Taper {
        var shape = Path()
        var left: [CGPoint] = []
        var right: [CGPoint] = []
    }

    /// What a stem's hand-drawn wobble is seeded from: its repository's seed, its name and how deep it
    /// is, never its place among the others, so a new branch doesn't reshape the rest, and two trees'
    /// `main`s don't wobble alike.
    private func woodSeed(_ stem: TreeLayout.Stem, repo: String) -> UInt64 {
        HandDrawn.seed("\(repo)\u{1F}\(stem.name ?? "trunk")", stem.level)
    }

    /// A tapered shape around sampled centreline points. Drawn by hand, each edge strays a little from
    /// the smooth taper and the width swells and thins, by the wobble at each point's distance from
    /// the base: so a limb keeps its edges as it grows, and only its new stretch is new.
    private func taper(_ samples: [(point: CGPoint, width: CGFloat)], seed: UInt64) -> Taper {
        var left: [CGPoint] = [], right: [CGPoint] = []
        let hand = Double(style.hand)
        var distance = 0.0
        for (i, sample) in samples.enumerated() {
            let a = samples[max(i - 1, 0)].point, b = samples[min(i + 1, samples.count - 1)].point
            let length = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            let normal = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
            var halfLeft = sample.width / 2, halfRight = sample.width / 2
            if hand > 0 {
                if i > 0 { distance += hypot(sample.point.x - samples[i - 1].point.x, sample.point.y - samples[i - 1].point.y) }
                let swell = 1 + 0.09 * hand * HandDrawn.wobble(seed, at: distance / 55)
                let stray = min(0.45 + 0.06 * Double(sample.width), 1.5) * hand
                halfLeft = max(halfLeft * swell + stray * HandDrawn.wobble(seed ^ 0x51ED, at: distance / 23), 0.35)
                halfRight = max(halfRight * swell + stray * HandDrawn.wobble(seed ^ 0xA77E, at: distance / 23), 0.35)
            }
            left.append(CGPoint(x: sample.point.x + normal.x * halfLeft, y: sample.point.y + normal.y * halfLeft))
            right.append(CGPoint(x: sample.point.x - normal.x * halfRight, y: sample.point.y - normal.y * halfRight))
        }
        // One closed outline (`addLines` would start a second subpath for the return side).
        let shape = Path { p in
            p.move(to: left[0])
            for point in left.dropFirst() + right.reversed() { p.addLine(to: point) }
            p.closeSubpath()
        }
        return Taper(shape: shape, left: left, right: right)
    }

    /// The wood in a dry medium, laid down stroke by stroke: a soft smudge beside it first, then each
    /// stem with its pressure rising and falling along it, so where strokes overlap (a collar on its
    /// parent, a bough on the trunk) the medium builds up.
    private func strokes(_ stems: [TreeLayout.Stem], _ outlines: [[(point: CGPoint, width: CGFloat)]], _ shapes: [Path],
                         _ seeds: [UInt64], roots: [Path], in context: inout GraphicsContext) {
        if style.smudge > 0 {
            // Charcoal rubs off down and to the side; chalk dust falls.
            var smudge = context
            smudge.opacity = style.smudge
            smudge.translateBy(x: style.medium == .chalk ? 0 : 2.5, y: 3)
            for piece in shapes + roots {
                smudge.fill(piece, with: .color(style.ink))
                smudge.stroke(piece, with: .color(style.ink), lineWidth: 6)
            }
        }
        // A soft edge: the medium thins out past the stroke's line rather than stopping at it.
        for piece in shapes + roots {
            context.stroke(piece, with: .color(style.ink.opacity(style.woodOpacity * 0.3)), lineWidth: 2.5)
        }
        for index in stems.indices {
            guard let base = outlines[index].first?.point, let tip = outlines[index].last?.point else { continue }
            let seed = seeds[index] ^ 0x9E55
            let length = max(hypot(tip.x - base.x, tip.y - base.y), 1)
            // The pressure at fixed distances from the base, so a limb growing longer keeps the shading
            // it had and only its new stretch is new.
            let stops = (Array(stride(from: 0, to: length, by: 90)) + [length]).map { distance in
                let pressure = (1 + HandDrawn.wobble(seed, at: Double(distance) / 90)) / 2
                return Gradient.Stop(color: style.ink.opacity(style.woodOpacity * (1 - style.pressure * pressure)),
                                     location: distance / length)
            }
            context.fill(shapes[index], with: .linearGradient(Gradient(stops: stops), startPoint: base, endPoint: tip))
        }
        for root in roots { context.fill(root, with: .color(style.ink.opacity(style.woodOpacity))) }
    }

    /// The wood's edges drawn as lines, past where each limb leaves its parent, shading from the wood's
    /// medium to the branch's along it as the limb does; and the roots' outlines.
    private func contours(_ stems: [TreeLayout.Stem], _ outlines: [[(point: CGPoint, width: CGFloat)]], _ tapers: [Taper],
                          _ seeds: [UInt64], roots: [Path], rootSeed: String, in context: inout GraphicsContext) {
        let sketch = Sketch(style)
        for (index, stem) in stems.enumerated() {
            let taper = tapers[index]
            guard taper.left.count >= 2, let base = outlines[index].first, let tip = outlines[index].last else { continue }
            let start = stem.fork.map { fork in
                TreeLayout.collarExit(parentWidth: fork.width, angle: (stem.nodes.first?.heading ?? 0) - fork.heading) * frame.scale * 0.6
            } ?? 0
            var skip = 0, distance: CGFloat = 0
            while skip < outlines[index].count - 2, distance < start {
                distance += hypot(outlines[index][skip + 1].point.x - outlines[index][skip].point.x,
                                  outlines[index][skip + 1].point.y - outlines[index][skip].point.y)
                skip += 1
            }
            let alpha = style.contour * (stem.isTrunk ? 1 : 0.55 + 0.45 * vigour(tipCommit(stem)))
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [style.ink.opacity(alpha), ink(stem).opacity(alpha)]), startPoint: base.point, endPoint: tip.point)
            // Thin limbs get a finer line, so they aren't all edge.
            let width = min(style.contourWidth, max(base.width * 0.3, 0.7))
            for (side, edge) in [taper.left, taper.right].enumerated() {
                var line = Path()
                line.addLines(Array(edge.dropFirst(skip)))
                sketch.stroke(line, with: shading, width: width, seed: seeds[index] &+ UInt64(side + 1), in: &context)
            }
        }
        for (index, root) in roots.enumerated() {
            sketch.stroke(root, with: .color(style.ink.opacity(style.contour * 0.8)), width: style.contourWidth * 0.8,
                          seed: HandDrawn.seed("\(rootSeed)\u{1F}root", index), in: &context)
        }
    }

    /// All the tree's wood in brush ink, as one shape: every stem with its collar, the shared trunk's
    /// rounded top, the roots. Painted on paper, then inked as a single layer, so where wood meets
    /// wood (a limb's collar on its parent, a bough on the trunk) the outlines merge and the tone
    /// stays even, with no seam and no darker overlap.
    private func wood(_ stems: [TreeLayout.Stem], _ shapes: [Path], roots: [Path], in context: inout GraphicsContext) {
        var pieces = shapes + roots
        // A shared trunk (no commits of its own) is rounded off at its top, so the boughs grow out of it.
        for stem in stems where stem.isTrunk && stem.commits.isEmpty && stem.fork == nil {
            guard stem.curve.count >= 2, let top = stem.curve.last else { continue }
            let center = frame.point(top.point), r = top.width * frame.scale / 2
            pieces.append(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)))
        }
        let bounds = pieces.reduce(CGRect.null) { $0.union($1.boundingRect) }
        guard !bounds.isNull else { return }
        for piece in pieces { context.fill(piece, with: .color(style.paper[1])) }
        var ink = context
        // The layer only needs to cover the wood.
        ink.clip(to: Path(bounds.insetBy(dx: -2, dy: -2)))
        ink.opacity = style.woodOpacity
        ink.drawLayer { layer in
            for piece in pieces { layer.fill(piece, with: .color(style.ink)) }
        }
    }

    /// Light dry-brush streaks along the thicker wood. A limb's start where it leaves its parent's
    /// edge, so the parent's streaks run on past the join and the limb's come out of its collar.
    private func bark(_ stem: TreeLayout.Stem, _ samples: [(point: CGPoint, width: CGFloat)], in context: inout GraphicsContext) {
        guard style.barkOpacity > 0, samples.count > 2 else { return }
        let start = stem.fork.map { fork in
            TreeLayout.collarExit(parentWidth: fork.width, angle: (stem.nodes.first?.heading ?? 0) - fork.heading) * frame.scale
        } ?? 0
        var rng = SeededRandom(stem.name ?? "trunk", -7)
        var streaks = Path()
        for lane in 0..<4 {
            let offset = rng.next(in: -0.32...0.32)
            var drawing = false
            var distance: CGFloat = 0
            for (i, sample) in samples.enumerated() where i > 0 {
                let a = samples[i - 1].point
                let length = max(hypot(sample.point.x - a.x, sample.point.y - a.y), 0.001)
                distance += length
                guard sample.width > 5, distance > start else { drawing = false; continue }
                let normal = CGPoint(x: -(sample.point.y - a.y) / length, y: (sample.point.x - a.x) / length)
                let p = CGPoint(x: sample.point.x + normal.x * sample.width * offset,
                                y: sample.point.y + normal.y * sample.width * offset)
                // Broken streaks: each run of samples is drawn or skipped, by the seed.
                var gap = SeededRandom(stem.name ?? "trunk", lane * 1000 + i / 3)
                if gap.next() < 0.55 {
                    if drawing { streaks.addLine(to: p) } else { streaks.move(to: p) }
                    drawing = true
                } else {
                    drawing = false
                }
            }
        }
        let streak = style.streaksInInk ? style.ink : style.paper[1]
        context.stroke(streaks, with: .color(streak.opacity(style.barkOpacity)),
                       style: StrokeStyle(lineWidth: style.streaksInInk ? 1 : 0.8, lineCap: .round, lineJoin: .round))
    }

    /// The branch bark ridge: a light crease in the crotch, just under where a limb's upper edge
    /// meets its parent's, dipping into the wood and running a little way along both.
    private func ridge(_ stem: TreeLayout.Stem, _ samples: [(point: CGPoint, width: CGFloat)], in context: inout GraphicsContext) {
        guard style.barkOpacity > 0, let fork = stem.fork, let base = samples.first, samples.count > 2 else { return }
        let own = (stem.nodes.first?.width ?? 0) * frame.scale, parent = fork.width * frame.scale
        guard own > 3, parent > 5 else { return }
        // The limb's direction a little way out, and its parent's.
        let ahead = samples.first { hypot($0.point.x - base.point.x, $0.point.y - base.point.y) > parent } ?? samples[samples.count - 1]
        let span = max(hypot(ahead.point.x - base.point.x, ahead.point.y - base.point.y), 0.001)
        let dL = CGPoint(x: (ahead.point.x - base.point.x) / span, y: (ahead.point.y - base.point.y) / span)
        let dP = TreeFrame.direction(fork.heading)
        let cosine = dL.x * dP.x + dL.y * dP.y
        guard abs(cosine) < 0.95, cosine > -0.2 else { return }
        func unit(_ p: CGPoint) -> CGPoint { let l = max(hypot(p.x, p.y), 0.001); return CGPoint(x: p.x / l, y: p.y / l) }
        // The parent's edge on the limb's side, and the limb's edge on the parent's forward side.
        let nP = unit(CGPoint(x: dL.x - dP.x * cosine, y: dL.y - dP.y * cosine))
        let nL = unit(CGPoint(x: dP.x - dL.x * cosine, y: dP.y - dL.y * cosine))
        let a = CGPoint(x: base.point.x + nP.x * parent / 2, y: base.point.y + nP.y * parent / 2)
        let b = CGPoint(x: base.point.x + nL.x * own * 0.65, y: base.point.y + nL.y * own * 0.65)
        // Where they cross: a + t·dP = b + u·dL.
        let det = dP.x * -dL.y - dP.y * -dL.x
        guard abs(det) > 0.05 else { return }
        let t = ((b.x - a.x) * -dL.y - (b.y - a.y) * -dL.x) / det
        let crotch = CGPoint(x: a.x + dP.x * t, y: a.y + dP.y * t)
        let into = unit(CGPoint(x: -(dP.x + dL.x), y: -(dP.y + dL.y)))
        let reach = min(own * 0.9, parent * 0.6), inset = max(own * 0.22, 1.5)
        var path = Path()
        path.move(to: CGPoint(x: crotch.x + dP.x * reach - nP.x * inset, y: crotch.y + dP.y * reach - nP.y * inset))
        path.addQuadCurve(to: CGPoint(x: crotch.x + dL.x * reach - nL.x * inset, y: crotch.y + dL.y * reach - nL.y * inset),
                          control: CGPoint(x: crotch.x + into.x * (reach * 0.5 + inset), y: crotch.y + into.y * (reach * 0.5 + inset)))
        context.stroke(path, with: .color(style.paper[1].opacity(style.barkOpacity)),
                       style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
    }

    /// Each limb shades from its parent's tone at the fork (plain wood off the trunk) to its branch's
    /// ink at the tip: a wash of paper, then the ink, both rising along it. Parents first, so a
    /// sub-branch picks up where its parent's shading had got to.
    private func tint(_ stems: [TreeLayout.Stem], _ outlines: [[(point: CGPoint, width: CGFloat)]], _ shapes: [Path],
                      parents: [Int?], in context: inout GraphicsContext) {
        // Per stem: the base and tip of its gradient, where it starts and with what, and its ink.
        var ramps: [(base: CGPoint, tip: CGPoint, from: Double, start: Double, ink: Color, alpha: Double)?] = []
        for (index, stem) in stems.enumerated() {
            guard !stem.isTrunk, let base = outlines[index].first, let tip = outlines[index].last else { ramps.append(nil); continue }
            let alpha = 0.55 + 0.4 * vigour(tipCommit(stem))
            var from = 0.0, fromInk = ink(stem), fromAlpha = alpha
            if let parent = parents[index], parent < ramps.count, let ramp = ramps[parent] {
                let d = CGPoint(x: ramp.tip.x - ramp.base.x, y: ramp.tip.y - ramp.base.y)
                let u = ((base.point.x - ramp.base.x) * d.x + (base.point.y - ramp.base.y) * d.y) / max(d.x * d.x + d.y * d.y, 0.001)
                from = Self.rampValue(u, from: ramp.from, start: ramp.start)
                fromInk = ramp.ink
                fromAlpha = ramp.alpha
            }
            let start = from > 0 ? 0 : 0.35
            ramps.append((base.point, tip.point, from, start, ink(stem), alpha))
            context.fill(shapes[index], with: .linearGradient(
                Gradient(stops: [.init(color: style.paper[1].opacity(from), location: 0),
                                 .init(color: style.paper[1].opacity(from), location: start),
                                 .init(color: style.paper[1], location: 1)]),
                startPoint: base.point, endPoint: tip.point))
            context.fill(shapes[index], with: .linearGradient(
                Gradient(stops: [.init(color: fromInk.opacity(fromAlpha * from), location: 0),
                                 .init(color: fromInk.opacity(fromAlpha * from), location: start),
                                 .init(color: ink(stem).opacity(alpha), location: 1)]),
                startPoint: base.point, endPoint: tip.point))
        }
    }

    /// A limb's shading at `u` along it (0 at the fork, 1 at the tip): `from` until `start`, rising to 1.
    private static func rampValue(_ u: Double, from: Double, start: Double) -> Double {
        let t = min(max((u - start) / (1 - start), 0), 1)
        return from + (1 - from) * t
    }

    /// A few roots spreading from the trunk's foot along and just under the ground.
    private func roots(of trunk: TreeLayout.Stem, seed: String) -> [Path] {
        guard let foot = trunk.nodes.first else { return [] }
        var rng = SeededRandom(seed, -3)
        let base = frame.point(foot.point)
        let width = foot.width * frame.scale
        return (0..<5).map { k in
            let side: CGFloat = k % 2 == 0 ? -1 : 1
            let reach = width * rng.next(in: 1.2...2.6)
            let drop = width * rng.next(in: 0.05...0.5)
            let start = CGPoint(x: base.x + side * width * rng.next(in: 0.05...0.35), y: base.y - width * 0.15)
            let end = CGPoint(x: start.x + side * reach, y: base.y + drop)
            let control = CGPoint(x: start.x + side * reach * 0.35, y: base.y + drop * 0.1)
            let thick = width * rng.next(in: 0.18...0.32)
            var path = Path()
            path.move(to: CGPoint(x: start.x, y: start.y - thick / 2))
            path.addQuadCurve(to: end, control: CGPoint(x: control.x, y: control.y - thick * 0.4))
            path.addQuadCurve(to: CGPoint(x: start.x, y: start.y + thick / 2),
                              control: CGPoint(x: control.x, y: control.y + thick * 0.4))
            path.closeSubpath()
            return path
        }
    }

    // MARK: Foliage

    /// A soft wash of the branch's ink behind its tip, sized by how much it carries, fading with age.
    private func canopy(_ stem: TreeLayout.Stem, in context: inout GraphicsContext) {
        guard style.canopyOpacity > 0, !stem.isBud, isLeafy(stem), stem.nodes.count >= 2, stem.grown > 0,
              let tip = stem.tip else { return }
        let center = frame.point(tip.point)
        let leavesShown = min(Double(stem.commits.count), stem.grown)
        let radius = CGFloat(30 + 7 * sqrt(min(leavesShown, 40)))
        let alpha = style.canopyOpacity * (0.3 + 0.7 * vigour(tipCommit(stem)))
        context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                     with: .radialGradient(Gradient(colors: [leafInk(stem).opacity(alpha), .clear]),
                                           center: center, startRadius: 0, endRadius: radius))
    }

    /// Leaves are commits: each commit puts a leaf or two at its node on alternating sides, and most
    /// also sprout a short twig with a spray of leaves; the tip gets a full cluster. Old commits fade
    /// and drop some of theirs, so a dormant limb thins out. The trunk leafs out only along its recent
    /// commits. Each leaf's lopsidedness is seeded from `repo` (`Pane.seed`) as well, so two trees'
    /// `main`s don't lean alike.
    private func leaves(_ stem: TreeLayout.Stem, repo: String, in context: inout GraphicsContext) {
        guard isLeafy(stem) else { return }
        let key = stem.name ?? "trunk", handKey = "\(repo)\u{1F}\(key)"
        let color = leafInk(stem)
        let size = style.leafSize * frame.detail * (0.75 + 0.25 * min(stem.scale, 1))
        if stem.isBud {
            guard let tip = stem.tip else { return }
            let grow = min(max(stem.grown, 0), 1)
            for side in [-1.0, 0, 1.0] {
                leaf(at: frame.point(tip.point), heading: tip.heading + side * 0.8, length: size * 0.75 * grow,
                     color: color, alpha: 0.8, seed: Self.mix(HandDrawn.seed(handKey, -1), Int(side) + 1), in: &context)
            }
            return
        }
        let firstLeafy = stem.isTrunk ? max(1, stem.commits.count - 30) : 1
        let lastNode = stem.nodes.count - 1
        guard lastNode >= 1, firstLeafy <= lastNode else { return }
        for k in firstLeafy...lastNode {
            let commit = k <= stem.commits.count ? stem.commits[k - 1] : nil
            var rng = SeededRandom(key, 1000 + k)
            let vigour = self.vigour(commit), alpha = freshness(commit)
            guard rng.next() < 0.3 + 0.7 * vigour else { continue }
            let node = stem.nodes[k]
            let grow = min(max(stem.grown - Double(k - 1), 0), 1)
            let point = frame.point(node.point)
            let offset = node.width * frame.scale / 2
            let leafSeed = HandDrawn.seed(handKey, 1000 + k)
            for i in 0..<(rng.next() < 0.5 ? 3 : 2) {
                let side = (k + i) % 2 == 0 ? 1.0 : -1.0
                let at = CGPoint(x: point.x + cos(node.heading) * side * offset, y: point.y + sin(node.heading) * side * offset)
                leaf(at: at, heading: node.heading + side * rng.next(in: 0.55...1.2),
                     length: size * rng.next(in: 0.75...1.15) * grow, color: color, alpha: alpha,
                     seed: Self.mix(leafSeed, i), in: &context)
            }
            if rng.next() < 0.35 + 0.6 * vigour {
                let side = k % 2 == 0 ? -1.0 : 1.0
                let at = CGPoint(x: point.x + cos(node.heading) * side * offset, y: point.y + sin(node.heading) * side * offset)
                spray(from: at, heading: node.heading + side * rng.next(in: 0.6...1.0),
                      length: size * rng.next(in: 0.9...1.5) * grow, leaves: 3, seed: &rng,
                      leafSeed: Self.mix(leafSeed, 10), color: color, alpha: alpha, in: &context)
            }
        }
        // The tip's cluster, fuller on a lively branch.
        guard let tip = stem.tip, stem.grown > 0 else { return }
        let commit = tipCommit(stem)
        var rng = SeededRandom(key, 999)
        let vigour = self.vigour(commit), alpha = freshness(commit)
        let grow = min(max(stem.grown - Double(lastNode - 1), 0), 1)
        let at = frame.point(tip.point)
        let tipSeed = HandDrawn.seed(handKey, 999)
        for side in [-1.0, 1.0] where rng.next() < 0.4 + 0.6 * vigour {
            spray(from: at, heading: tip.heading + side * rng.next(in: 0.5...0.9), length: size * 1.3 * grow,
                  leaves: 3, seed: &rng, leafSeed: Self.mix(tipSeed, side > 0 ? 200 : 100), color: color, alpha: alpha,
                  in: &context)
        }
        let count = 4 + Int(4 * vigour)
        for i in 0..<count {
            let spread = count > 1 ? Double(i) / Double(count - 1) * 2 - 1 : 0
            leaf(at: at, heading: tip.heading + spread * 1.3 + rng.next(in: -0.15...0.15),
                 length: size * rng.next(in: 0.95...1.35) * grow, color: color, alpha: alpha,
                 seed: Self.mix(tipSeed, i), in: &context)
        }
    }

    /// A short, slightly curved twig with a fan of leaves at its end and one partway along.
    private func spray(from base: CGPoint, heading: Double, length: CGFloat, leaves: Int, seed rng: inout SeededRandom,
                       leafSeed: UInt64, color: Color, alpha: Double, in context: inout GraphicsContext) {
        guard length > 1 else { return }
        let direction = TreeFrame.direction(heading)
        let bend = rng.next(in: -0.35...0.35)
        let end = CGPoint(x: base.x + direction.x * length, y: base.y + direction.y * length)
        let control = CGPoint(x: base.x + direction.x * length * 0.5 + cos(heading) * length * bend,
                              y: base.y + direction.y * length * 0.5 + sin(heading) * length * bend)
        var twig = Path()
        twig.move(to: base)
        twig.addQuadCurve(to: end, control: control)
        context.stroke(twig, with: .color(style.ink.opacity(0.6 * alpha)), lineWidth: style.lineWidth * 0.8)
        let size = style.leafSize * frame.detail * 0.8
        let scale = min(1, length / (style.leafSize * frame.detail * 1.2))
        leaf(at: control, heading: heading + (bend > 0 ? -0.9 : 0.9), length: size * 0.8 * scale,
             color: color, alpha: alpha, seed: leafSeed, in: &context)
        for i in 0..<leaves {
            let spread = leaves > 1 ? Double(i) / Double(leaves - 1) * 2 - 1 : 0
            leaf(at: end, heading: heading + bend + spread * 0.75, length: size * rng.next(in: 0.85...1.15) * scale,
                 color: color, alpha: alpha, seed: Self.mix(leafSeed, i + 1), in: &context)
        }
    }

    /// Seed `seed`'s `index`th neighbour: for the leaves of one node or cluster.
    private static func mix(_ seed: UInt64, _ index: Int) -> UInt64 {
        seed &+ UInt64(bitPattern: Int64(index + 1)) &* 0x9E3779B97F4A7C15
    }

    /// One leaf: an almond in the ink at `alpha`, outlined, with a midrib. Drawn by hand, each is a
    /// touch lopsided (its tip, sides and swell nudged by its seed).
    private func leaf(at base: CGPoint, heading: Double, length: CGFloat, color: Color, alpha: Double,
                      seed: UInt64, in context: inout GraphicsContext) {
        guard length > 0.5 else { return }
        var tip = CGPoint(x: length, y: 0)
        var upper = length * 0.36, lower = length * 0.36, swell = length * 0.45
        if style.hand > 0 {
            var rng = SeededRandom(seed: seed)
            let hand = style.hand
            tip = CGPoint(x: length * (1 + 0.08 * hand * (rng.next() * 2 - 1)), y: length * 0.07 * hand * (rng.next() * 2 - 1))
            upper *= 1 + 0.22 * hand * (rng.next() * 2 - 1)
            lower *= 1 + 0.22 * hand * (rng.next() * 2 - 1)
            swell += length * 0.08 * hand * (rng.next() * 2 - 1)
        }
        var shape = Path()
        shape.move(to: .zero)
        shape.addQuadCurve(to: tip, control: CGPoint(x: swell, y: -upper))
        shape.addQuadCurve(to: .zero, control: CGPoint(x: swell, y: lower))
        var rib = Path()
        rib.move(to: .zero)
        rib.addLine(to: CGPoint(x: tip.x * 0.8, y: tip.y * 0.8))
        let transform = CGAffineTransform(translationX: base.x, y: base.y).rotated(by: heading - .pi / 2)
        context.fill(shape.applying(transform), with: .color(color.opacity(style.leafOpacity * alpha)))
        context.stroke(shape.applying(transform), with: .color(color.opacity(style.leafLine * alpha)), lineWidth: style.lineWidth * 0.6)
        context.stroke(rib.applying(transform), with: .color(color.opacity(0.7 * alpha)), lineWidth: style.lineWidth * 0.45)
    }

    /// A small five-petalled blossom at the tip of a branch checked out in a worktree, its petals
    /// seeded from `repo` (`Pane.seed`) and the branch.
    private func blossom(_ stem: TreeLayout.Stem, repo: String, in context: inout GraphicsContext) {
        guard let tip = stem.tip, stem.grown >= Double(max(stem.commits.count, 1)) else { return }
        let center = frame.point(tip.point)
        let color = stem.isTrunk ? style.ink : ink(stem)
        var rng = SeededRandom(seed: HandDrawn.seed("\(repo)\u{1F}\(stem.name ?? "trunk")", -5))
        for k in 0..<5 {
            let angle = Double(k) / 5 * 2 * .pi + tip.heading + 0.25 * style.hand * (rng.next() * 2 - 1)
            let r = 2.6 * (1 + 0.18 * style.hand * (rng.next() * 2 - 1))
            let petal = Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
                .applying(CGAffineTransform(translationX: center.x + cos(angle) * 3.6, y: center.y + sin(angle) * 3.6))
            context.fill(petal, with: .color(style.paper[0]))
            context.stroke(petal, with: .color(color.opacity(0.9)), lineWidth: style.lineWidth * 0.8)
        }
        context.fill(Path(ellipseIn: CGRect(x: center.x - 1.6, y: center.y - 1.6, width: 3.2, height: 3.2)),
                     with: .color(color))
    }

    // MARK: Text

    /// A faint wash of shade on the ground under the tree.
    func shadow(width: Double, in context: inout GraphicsContext) {
        let half = max(CGFloat(width) * frame.scale * 0.32, 40), depth: CGFloat = 7
        let rect = CGRect(x: frame.origin.x - half, y: frame.origin.y - depth / 2, width: half * 2, height: depth * 2)
        context.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [style.ink.opacity(0.12), .clear]),
            center: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0, endRadius: half))
    }

    /// The repository's name under its tree, like a plate's caption.
    func plate(_ name: String, in context: inout GraphicsContext) {
        let text = Text(name).font(style.plateFont).foregroundColor(style.ink.opacity(style.plateOpacity))
        context.draw(text, at: CGPoint(x: frame.origin.x, y: frame.origin.y + 22), anchor: .top)
    }
}
