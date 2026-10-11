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
    @State private var forestCache = ForestCache()

    var body: some View {
        let medium = background.settings.medium
        let style = WallpaperStyle.make(medium, dark: colorScheme == .dark)
        let panes = background.panes
        let arrangement = background.settings.arrangement
        let showsBranchNames = background.settings.showsBranchNames
        let showsRepoNames = background.settings.showsRepoNames
        let hangsBanners = background.settings.hangsBanners
        let occludesBanners = !background.settings.drawsAllBannersInView
        let now = background.now
        let shuffle = background.settings.layoutSeed
        let forest = background.settings.forest
        let policy = background.policy
        let ranking = background.ranking
        let seeds = PinnedRepositories.seeds(panes.map(\.repoURL))
        // Read each pane here so Observation redraws when one publishes a new tree or growth, and
        // when the scene stops waiting for its trees.
        // swiftlint:disable:next redundant_discardable_let - `_ =` would be a view in a ViewBuilder
        let _ = background.isAwaitingTrees
        let growing = background.isGrowingIn || panes.contains { pane in
            // swiftlint:disable:next redundant_discardable_let - `_ =` would be a view in a ViewBuilder
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
                    // What the plans below are made from: the trees, the screen and what's shown.
                    let key = PlanCache.Key(dark: colorScheme == .dark, medium: medium, size: proxy.size, now: now,
                                            shuffle: shuffle, arrangement: arrangement, forest: forest, treeCapacity: policy.fixedTreeCapacity,
                                            ranking: ranking,
                                            branchNames: showsBranchNames, repoNames: showsRepoNames,
                                            hanging: hangsBanners, occluded: occludesBanners,
                                            trees: panes.map { .init(id: $0.repoURL.path, tree: $0.tree) })
                    let resting = zip(panes, seeds).map { Pane($0, seed: $1) }
                    // The forest's trees are planned once, each a layer of its own (`ForestTreeLayer`).
                    let stands = forestCache.stands(for: key) {
                        Landscape(style: style, now: now, size: proxy.size, shuffle: shuffle, trunkGrowIn: nil, forest: forest, policy: policy,
                                  ranking: ranking).forestStands(resting, arrangement: arrangement)
                    }
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !growing)) { timeline in
                        let date = timeline.date
                        // The forest's small trees grow at fifteen frames a second, which the eye can't tell from thirty
                        // there: each layer is redrawn half as often.
                        let forestIDs = Set(stands?.stands.map(\.id) ?? [])
                        let slowDate = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate * 15).rounded(.down) / 15)
                        let panes = zip(panes, seeds).map { pane, seed in
                            let at = forestIDs.contains(pane.repoURL.path) ? slowDate : date
                            return Pane(pane, seed: seed, grown: pane.grown(at: at), growIn: background.growIn(pane.repoURL, at: at))
                        }
                        let trunkGrowIn = background.trunkGrowIn(at: date)
                        let landscape = Landscape(style: style, now: now, size: proxy.size, shuffle: shuffle, trunkGrowIn: trunkGrowIn,
                                                  forest: forest, policy: policy, ranking: ranking, layered: true)
                        ZStack {
                            if let stands {
                                ForestGroundsLayer(landscape: landscape, plan: stands.grounds, generation: stands.generation).equatable()
                                let byID = Dictionary(panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                                ForEach(stands.stands) { stand in
                                    if let pane = byID[stand.id] {
                                        ForestTreeLayer(landscape: landscape, stand: stand, pane: pane, generation: stands.generation)
                                            .equatable()
                                    }
                                }
                            }
                            MainTreeLayer(landscape: landscape, panes: panes, arrangement: arrangement,
                                          forestIDs: forestIDs, generation: forestCache.generation)
                                .equatable()
                        }
                    }
                    if showsBranchNames || showsRepoNames {
                        // The names hang where the full-grown trees put them, planned only when a tree or
                        // what's shown changes, not on every redraw.
                        let plan = plans.plan(for: key) {
                            Landscape(style: style, now: now, size: proxy.size, shuffle: shuffle, trunkGrowIn: nil, forest: forest, policy: policy,
                                      ranking: ranking).plan(
                                zip(panes, seeds).map { Pane($0, seed: $1) },
                                arrangement: arrangement, branchNames: showsBranchNames, repoNames: showsRepoNames,
                                hanging: hangsBanners, occluded: occludesBanners)
                        }
                        // Each name fades in as its wood finishes growing, on the trees' clock.
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !growing)) { timeline in
                            BannerLayer(plan: plan, shown: Self.shownBanners(plan, panes: panes, at: timeline.date,
                                                                             growIn: background.growIn),
                                        style: style, breeze: background.breeze)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    /// How far each banner on growing wood has faded in at `date`: a pennant as its stem reaches its
    /// tip (`TreeLayout.Stretch.nameShown`), a ribbon as its bough does; on a limb growing new
    /// commits, over the end of the growth. Banners on still wood aren't listed (they're shown). A banner
    /// hidden behind what's painted in front of it is masked by the full-grown trees, so on a tree growing
    /// in it waits for every tree growing in to finish, rather than show holes where leaves are still to come.
    /// `growIn` is how far a pane's tree is in growing in at a date (`BackgroundModel.growIn`). Each
    /// banner carries its stretch from the plan, so a frame only looks up a progress or two per pane.
    static func shownBanners(_ plan: BannerPlan, panes: [WallpaperModel], at date: Date,
                             growIn: (URL, Date) -> Double?) -> [String: Double] {
        var growingIn: [String: Double] = [:], growing: [String: (pane: WallpaperModel, progress: Double)] = [:]
        for pane in panes {
            if let progress = growIn(pane.repoURL, date) {
                growingIn[pane.repoURL.path] = progress
            } else if let progress = pane.growthProgress(at: date) {
                growing[pane.repoURL.path] = (pane, progress)
            }
        }
        guard !growingIn.isEmpty || !growing.isEmpty else { return [:] }
        var shown: [String: Double] = [:]
        let last = TreeLayout.Stretch.nameFade, everyone = growingIn.values.min() ?? 1
        let whole = min(max((everyone - (1 - last)) / last, 0), 1)
        for hanging in plan.banners {
            if let progress = growingIn[hanging.pane] {
                shown[hanging.id] = min(hanging.stretch.nameShown(at: progress), hanging.hiddenFrom == nil ? 1 : whole)
            } else if let (pane, progress) = growing[hanging.pane], pane.growth[hanging.stem] != nil {
                shown[hanging.id] = min(max((progress - 0.85) / 0.15, 0), 1)
            }
        }
        for ribbon in plan.ribbons {
            if let progress = growingIn[ribbon.pane] {
                shown[ribbon.id] = min(ribbon.stretch.nameShown(at: progress), ribbon.hiddenFrom == nil ? 1 : whole)
            }
        }
        return shown
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

// MARK: - Arrangements

/// One repository as it's drawn this frame.
struct Pane: Equatable {
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
    /// The trees' layout seed (`BackgroundSettings.layoutSeed`), as `TreeLayout` takes it.
    let shuffle: Int
    /// How far the single tree's shared trunk has risen, while it's rising.
    let trunkGrowIn: Double?
    /// How a crowd of trees is spread over the screen: by default the policy decides (`ForestMode.auto`).
    var forest: ForestMode = .auto
    var policy: ForestPolicy = .standard
    /// How the single tree's boughs fan out; by default by how many there are (`Fit.fitting`).
    var treeFit: YggdrasilLayout.Fit?
    /// When each repository (by pane id) last had a commit, as the ranking last took it: frozen at launch
    /// and at midnight, so a commit never reshuffles the trees. One not listed ranks on its own tree.
    var ranking: [String: Date] = [:]
    /// Whether the forest's trees are drawn as views of their own (`ForestTreeLayer`), which the
    /// canvas then leaves out: a tree that isn't growing isn't redrawn.
    var layered = false

    /// A pane's full-grown tree and where it stands on the screen.
    struct Planted {
        let index: Int
        let full: TreeLayout
        let frame: TreeFrame
        /// The forest layouts' extras: the style it's drawn in (faded into the paper at the back), the
        /// line it stands on (0 in front) and the width its name may take. Nil in the orchard.
        var forest: ForestPlanted?
        /// The width of an orchard plot, which its name has to fit in. Nil in the forest.
        var plot: CGFloat?
    }

    struct ForestPlanted {
        let style: WallpaperStyle
        let line: Int
        let slot: CGFloat
        let fade: Double
    }

    /// The trees in `arrangement`, broken up by the medium's grain.
    func draw(_ panes: [Pane], arrangement: Arrangement, in context: inout GraphicsContext) {
        Textures.grained(style, in: &context, size: size) { context in
            if isSingleTree(panes, arrangement: arrangement) {
                let scene = scene(panes, arrangement: arrangement)
                if !scene.forest.isEmpty, !layered { drawForestBehind(scene, in: &context) }
                drawSingleTree(scene.tree, problems: panes, narrowed: !scene.forest.isEmpty, in: &context)
            } else {
                drawOrchard(panes, in: &context)
            }
        }
    }

    /// The repositories that didn't fit on the single tree, standing behind it on either side.
    private func drawForestBehind(_ scene: Scene, in context: inout GraphicsContext) {
        let (full, frame) = singleTree(scene.tree, narrowed: true)
        let forest = forestScene(scene.forest, crown: CGFloat(full.bounds.width) * frame.scale)
        drawForestGrounds(forest.plan, in: &context)
        drawPlanted(forest.planted, of: scene.forest, in: &context)
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
        if isPacked(panes) { return forestScene(panes).planted }
        let plot = size.width / CGFloat(panes.count)
        let tall = Composition.groundY(size.height) - Composition.top - TreeFrame.margin
        let shared = min(tall / Composition.nominalHeight, plot / Composition.plotWidth)
        return panes.enumerated().compactMap { index, pane in
            guard let tree = pane.tree else { return nil }
            let full = TreeLayout(tree: tree, seed: pane.seed, shuffle: shuffle)
            var rng = SeededRandom(SeededRandom.key(pane.seed, shuffle: shuffle), -9)
            let x = plot * (CGFloat(index) + 0.5) + (panes.count > 1 ? plot * rng.next(in: -0.05...0.05) : 0)
            let frame = TreeFrame(size: size, bounds: full.bounds, nominalHeight: Composition.nominalHeight,
                                  scale: shared, maxWidth: min(plot * 1.45, size.width - 2 * TreeFrame.margin), x: x)
            return Planted(index: index, full: full, frame: frame, plot: plot)
        }
    }

    /// Whether an orchard of `panes` is too many for equal plots, so they stand in depth rows.
    func isPacked(_ panes: [Pane]) -> Bool { forest.packs(panes.filter { $0.tree != nil }.count, policy: policy) }

    func drawOrchard(_ panes: [Pane], in context: inout GraphicsContext) {
        let plot = size.width / CGFloat(panes.count)
        for (index, pane) in panes.enumerated() where pane.tree == nil {
            if let problem = pane.problem {
                problemText(problem, at: CGPoint(x: plot * (CGFloat(index) + 0.5), y: size.height / 2), in: &context)
            }
        }
        let planted: [Planted]
        if isPacked(panes) {
            // Layered, each tree is a view of its own (`ForestTreeLayer`).
            guard !layered else { return }
            let scene = forestScene(panes)
            planted = scene.planted
            drawForestGrounds(scene.plan, in: &context)
        } else {
            planted = orchard(panes)
        }
        drawPlanted(planted, of: panes, in: &context)
    }

    /// Each planted tree, with its shadow and name.
    func drawPlanted(_ planted: [Planted], of panes: [Pane], in context: inout GraphicsContext) {
        // Back to front, so a tree in front covers the foot of the one behind it.
        for planted in planted.sorted(by: { ($0.forest?.line ?? 0) > ($1.forest?.line ?? 0) }) {
            drawStand(planted, pane: panes[planted.index], in: &context)
        }
    }

    /// One planted tree as `pane` has it now: its shadow and name, then the tree.
    func drawStand(_ planted: Planted, pane: Pane, in context: inout GraphicsContext) {
        let tree = pane.tree!
        let layout = pane.growIn.map { TreeLayout(tree: tree, seed: pane.seed, growIn: $0, shuffle: shuffle) }
            ?? (pane.grown.isEmpty ? planted.full : TreeLayout(tree: tree, seed: pane.seed, grown: pane.grown, shuffle: shuffle))
        let drawing = TreeDrawing(style: planted.forest?.style ?? style, now: now, frame: planted.frame)
        // Its shadow and name come with it, not before it starts to grow.
        if pane.growIn != 0 {
            drawing.shadow(width: planted.full.bounds.width, in: &context)
            if let forest = planted.forest {
                drawing.forestPlate(pane.name, line: forest.line, slot: forest.slot, in: &context)
            } else {
                drawing.plate(pane.name, slot: planted.plot, in: &context)
            }
        }
        drawing.draw(layout.stems, seeds: layout.stems.map { _ in pane.seed }, parents: layout.stems.map { $0.fork?.parent },
                     rootedAt: layout.stems.isEmpty ? nil : 0, rootSeed: pane.seed, in: &context)
        if let problem = pane.problem {
            problemText(problem, at: CGPoint(x: planted.frame.origin.x, y: size.height / 2), in: &context)
        }
    }

    /// One tree for every repository with a tree (`ready`): a shared trunk, a bough each, fanned in
    /// pin order, and where it stands. A forest standing beside it (`narrowed`) leaves it less of the width.
    func singleTree(_ ready: [Pane], narrowed: Bool = false) -> (full: YggdrasilLayout, frame: TreeFrame) {
        // A bough's name is its seed: it sets the bough's lean.
        let full = YggdrasilLayout(repos: ready.map { .init(name: $0.seed, tree: $0.tree!) }, shuffle: shuffle,
                                   fit: fit(for: ready.count))
        let tall = Composition.groundY(size.height) - Composition.top - TreeFrame.margin
        // Its boughs lean, so it's rarely as tall as its trees would be on their own.
        let nominal = YggdrasilLayout.crotchHeight + Composition.nominalHeight * 0.82
        let width = narrowed ? size.width * Self.crownShare : size.width - 2 * TreeFrame.margin
        let frame = TreeFrame(size: size, bounds: full.bounds, nominalHeight: nominal, scale: tall / nominal,
                              maxWidth: width, x: size.width / 2)
        return (full, frame)
    }

    func fit(for count: Int) -> YggdrasilLayout.Fit { treeFit ?? .fitting(count: count) }

    /// About how many leafy twigs a single tree has in all, shared among its boughs: enough for a full
    /// crown, few enough to draw quickly.
    static let twigBudget = 640

    /// The single tree (each repository's name hangs on its ribbon over it: `BannerLayer`); `panes`
    /// are every pane's, for the problems written under it.
    func drawSingleTree(_ ready: [Pane], problems panes: [Pane], narrowed: Bool, in context: inout GraphicsContext) {
        let (full, frame) = singleTree(ready, narrowed: narrowed)
        let still = trunkGrowIn == nil && ready.allSatisfy { $0.grown.isEmpty && $0.growIn == nil }
        let layout = still ? full : YggdrasilLayout(repos: ready.map {
            .init(name: $0.seed, tree: $0.tree!, grown: $0.grown, growIn: $0.growIn)
        }, trunkGrowIn: trunkGrowIn, shuffle: shuffle, fit: fit(for: ready.count))
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
        let order = Self.paintOrder(layout)
        drawing.draw(stems, seeds: seeds, parents: parents, rootedAt: 0, rootSeed: "yggdrasil", groups: order.groups,
                     emerging: order.emerging, foliage: Self.foliage(layout), in: &context)
        let problems = panes.compactMap { pane in pane.problem.map { "\(pane.name): \($0)" } }
        if !problems.isEmpty {
            problemText(problems.joined(separator: "   "),
                        at: CGPoint(x: size.width / 2, y: Composition.groundY(size.height) + 56), in: &context)
        }
    }

    func problemText(_ text: String, at point: CGPoint, in context: inout GraphicsContext) {
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
    /// The smallest `detail` (a forest of small trees lets leaves and names shrink further).
    var detailFloor: CGFloat = 0.62

    /// Room kept around the crown for leaves and the names at the tips.
    static let margin: CGFloat = 40

    /// How large leaves and names are drawn: in step with the tree, within limits, so a small tree in a
    /// narrow plot isn't buried under them.
    var detail: CGFloat { min(max(scale / 520, detailFloor), 1.15) }

    /// A tree the forest layout has already fitted: this big, standing at `x` on `ground`.
    init(size: CGSize, scale: CGFloat, x: CGFloat, ground: CGFloat, detailFloor: CGFloat) {
        self.size = size
        self.scale = max(scale, 1)
        origin = CGPoint(x: x, y: ground)
        self.detailFloor = detailFloor
    }

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
    /// Where, on the screen, anything drawn matters: leaves and twigs wholly outside it are skipped
    /// (`Occlusion` draws only a banner's box). Nil draws everything.
    var only: CGRect?

    /// The wood and foliage of `stems` (names hang on banners over the canvas: `BannerLayer`),
    /// with roots spreading from the foot of the stem at `ground`. `seeds` are each stem's repository's
    /// seed (`Pane.seed`), and `rootSeed` the roots'. `parents` are each stem's parent, as an index
    /// into `stems` (before it), or nil for one standing on the ground.
    ///
    /// Without `groups` the whole tree's wood is one piece. With them, each group of stems (a bough of
    /// the single tree, say) is painted whole in turn, wood, outlines and leaves, over an opaque
    /// underlay, so a later group hides what it passes in front of. A stem forking from wood in an earlier
    /// group (a bough off the shared trunk) fades in from its foot (`fadeIn`), so it grows out of that wood
    /// rather than lying on it as a piece of its own, with a cut end, a rim or a tone that isn't the
    /// trunk's. `foliage` puts leafy twigs along every trunk with commits (a bough's main). `emerging`
    /// stems come toward the viewer out of the face of wood in an earlier group.
    func draw(_ stems: [TreeLayout.Stem], seeds: [String], parents: [Int?], rootedAt ground: Int?, rootSeed: String,
              groups: [[Int]]? = nil, emerging: Set<Int> = [], foliage: Foliage? = nil, in context: inout GraphicsContext) {
        for stem in stems { canopy(stem, in: &context) }
        var outlines = stems.map(outline)
        let woodSeeds = zip(stems, seeds).map { woodSeed($0, repo: $1) }
        let groupOf = (groups ?? []).enumerated().reduce(into: [Int: Int]()) { result, group in
            for index in group.element { result[index] = group.offset }
        }
        var tapers: [Taper] = []
        for index in stems.indices {
            // Parents come first, so a grafted stem's parent already has its shape.
            if let parent = parents[index], parent < index, let group = groupOf[index], groupOf[parent] != group {
                outlines[index] = graft(outlines[index], into: tapers[parent].shape, own: (stems[index].nodes.first?.width ?? 0) * frame.scale)
            }
            tapers.append(outlines[index].count >= 2 ? taper(outlines[index], seed: woodSeeds[index]) : Taper())
        }
        let shapes = tapers.map(\.shape)
        let tops = stems.map(top)
        let pressure = style.layeredWood ? pressures(stems, outlines, woodSeeds, parents: parents) : []
        let collars = style.contour > 0 ? stems.indices.map { collar($0, stems, outlines, tapers) } : []
        for group in groups ?? [Array(stems.indices)] {
            let roots = ground.flatMap { group.contains($0) ? self.roots(of: stems[$0], seed: rootSeed) : nil } ?? []
            let pieces = group.map { shapes[$0] } + group.compactMap { tops[$0] }
            let grafted = group.filter { index in parents[index].map { !group.contains($0) } ?? false }
            func paint(_ context: inout GraphicsContext) {
                if groups != nil {
                    for piece in pieces + roots { context.fill(piece, with: .color(style.paper[1])) }
                }
                if style.layeredWood {
                    strokes(group, outlines, pieces: pieces, shapes, pressure, roots: roots, tops: tops, in: &context)
                } else {
                    // A stem growing out of other wood has a rounded base, so no cut end shows past its parent
                    // (one grafted on fades in instead).
                    let feet = group.compactMap { index -> Path? in
                        guard stems[index].fork != nil, !grafted.contains(index), let base = outlines[index].first else { return nil }
                        let r = base.width / 2
                        return Path(ellipseIn: CGRect(x: base.point.x - r, y: base.point.y - r, width: 2 * r, height: 2 * r))
                    }
                    wood(pieces + feet, roots: roots, in: &context)
                }
                let knotted = group.map { knots(stems[$0], outlines[$0]) }
                for (index, knots) in zip(group, knotted) { bark(stems[index], outlines[index], around: knots, in: &context) }
                for knots in knotted { draw(knots, in: &context) }
                for index in group { ridge(stems[index], outlines[index], in: &context) }
                tint(group, stems, outlines, shapes, parents: parents, in: &context)
                if style.contour > 0 {
                    contours(group, stems, outlines, tapers, woodSeeds, collars, parents: (parents, emerging),
                             roots: (roots, ground), tops: tops, in: &context)
                    rootLines(roots, around: ground.map { tapers[$0].shape }, seed: rootSeed, in: &context)
                }
            }
            if grafted.isEmpty {
                paint(&context)
            } else {
                context.drawLayer { layer in
                    paint(&layer)
                    for index in grafted {
                        let parent = parents[index] ?? 0
                        fadeIn(index, stems, outlines, over: [shapes[parent]] + [tops[parent]].compactMap { $0 }, in: &layer)
                    }
                }
            }
            for index in group {
                if let foliage, stems[index].isTrunk, !stems[index].commits.isEmpty {
                    twigs(stems[index], outlines[index], repo: seeds[index], foliage: foliage, in: &context)
                }
                leaves(stems[index], repo: seeds[index], in: &context)
            }
            for index in group where stems[index].isCheckedOut { blossom(stems[index], repo: seeds[index], in: &context) }
        }
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
    func vigour(_ commit: RepoTree.Commit?) -> Double {
        style.fadeFloor < 1 ? (freshness(commit) - style.fadeFloor) / (1 - style.fadeFloor) : 1
    }

    private func tipCommit(_ stem: TreeLayout.Stem) -> RepoTree.Commit? { stem.commits.last }

    // MARK: Wood

    /// A stem's centreline through its curve, smoothed (Catmull–Rom), sampled with widths in points:
    /// (point, width) pairs from base to tip.
    func outline(_ stem: TreeLayout.Stem) -> [(point: CGPoint, width: CGFloat)] {
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
        // Every stem but a shared trunk narrows to a point at its end, as it's drawn now: a limb still
        // growing tapers to wherever it has got to.
        if stem.tapersToTip, samples.count >= 2 {
            var toTip = [CGFloat](repeating: 0, count: samples.count)
            for i in samples.indices.reversed().dropFirst() {
                toTip[i] = toTip[i + 1] + hypot(samples[i + 1].0.x - samples[i].0.x, samples[i + 1].0.y - samples[i].0.y)
            }
            let taper = stem.tipTaper
            for i in samples.indices {
                samples[i].1 *= CGFloat(taper.factor(distanceToTip: Double(toTip[i] / frame.scale)))
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
    func woodSeed(_ stem: TreeLayout.Stem, repo: String) -> UInt64 {
        HandDrawn.seed("\(repo)\u{1F}\(stem.name ?? "trunk")", stem.level)
    }

    /// A tapered shape around sampled centreline points. Drawn by hand, each edge strays a little from
    /// the smooth taper and the width swells and thins, by the wobble at each point's distance from
    /// the base: so a limb keeps its edges as it grows, and only its new stretch is new.
    func taper(_ samples: [(point: CGPoint, width: CGFloat)], seed: UInt64) -> Taper {
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

    /// A shared trunk's rounded top, so the boughs grow out of it; nil for any other stem.
    func top(_ stem: TreeLayout.Stem) -> Path? {
        guard stem.isTrunk, stem.commits.isEmpty, stem.fork == nil, stem.curve.count >= 2, let top = stem.curve.last else { return nil }
        let center = frame.point(top.point), r = top.width * frame.scale / 2
        return Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }

    /// The wood in a dry medium, laid down by hand: a soft smudge beside it first, then each stem with
    /// its pressure rising and falling along it. The whole tree's wood is one layer, so where wood
    /// meets wood (a collar on its parent, a bough on the trunk, a root at the trunk's foot) the medium
    /// isn't laid twice: each piece replaces what's under it, a parent after its limbs, and a limb's
    /// pressure starts from its parent's where it forks, so the fork reads as one piece of wood.
    private func strokes(_ group: [Int], _ outlines: [[(point: CGPoint, width: CGFloat)]], pieces: [Path], _ shapes: [Path],
                         _ pressure: [[HandDrawn.Pressure]], roots: [Path], tops: [Path?], in context: inout GraphicsContext) {
        let pieces = pieces + roots
        let bounds = pieces.reduce(CGRect.null) { $0.union($1.boundingRect) }
        guard !bounds.isNull else { return }
        if style.smudge > 0 {
            // Charcoal rubs off down and to the side; chalk dust falls.
            var smudge = context
            smudge.clip(to: Path(bounds.insetBy(dx: -10, dy: -10)))
            smudge.opacity = style.smudge
            smudge.drawLayer { layer in
                layer.translateBy(x: style.medium == .chalk ? 0 : 2.5, y: 3)
                for piece in pieces {
                    layer.fill(piece, with: .color(style.ink))
                    layer.stroke(piece, with: .color(style.ink), lineWidth: 6)
                }
            }
        }
        var wood = context
        // The layer only needs to cover the wood and its soft edge.
        wood.clip(to: Path(bounds.insetBy(dx: -3, dy: -3)))
        wood.opacity = style.woodOpacity
        wood.drawLayer { layer in
            layer.blendMode = .copy
            // A soft edge: the medium thins out past the stroke's line rather than stopping at it. The
            // wood is drawn over it, so only the part outside the whole tree's outline is left.
            for piece in pieces { layer.stroke(piece, with: .color(style.ink.opacity(0.3)), lineWidth: 2.5) }
            // The roots as strong as the trunk's foot, which is drawn over them.
            let foot = pressure.first?.first?.strength ?? 1
            for root in roots { layer.fill(root, with: .color(style.ink.opacity(foot))) }
            for index in group.reversed() {
                guard let base = outlines[index].first?.point, let tip = outlines[index].last?.point else { continue }
                let length = max(hypot(tip.x - base.x, tip.y - base.y), 1)
                let stops = pressure[index].map {
                    Gradient.Stop(color: style.ink.opacity($0.strength), location: $0.distance / length)
                }
                layer.fill(shapes[index], with: .linearGradient(Gradient(stops: stops), startPoint: base, endPoint: tip))
                if let top = tops[index] {
                    layer.fill(top, with: .color(style.ink.opacity(pressure[index].last?.strength ?? 1)))
                }
            }
        }
    }

    /// Each stem's pressure (`HandDrawn.pressure`), at fixed distances from its base along the line
    /// to its tip, so a limb growing longer keeps the shading it had and only its new stretch is new.
    /// Parents first: a limb starts from its parent's strength where it forks, easing into its own over
    /// its collar.
    private func pressures(_ stems: [TreeLayout.Stem], _ outlines: [[(point: CGPoint, width: CGFloat)]], _ seeds: [UInt64],
                           parents: [Int?]) -> [[HandDrawn.Pressure]] {
        var result: [[HandDrawn.Pressure]] = []
        for (index, stem) in stems.enumerated() {
            guard let base = outlines[index].first?.point, let tip = outlines[index].last?.point else { result.append([]); continue }
            let length = max(hypot(tip.x - base.x, tip.y - base.y), 1)
            var fork: (strength: Double, collar: Double)?
            if let joint = stem.fork, let parent = parents[index], parent < index,
               let parentBase = outlines[parent].first?.point, let parentTip = outlines[parent].last?.point {
                // Where the fork falls along the parent's shading.
                let d = CGPoint(x: parentTip.x - parentBase.x, y: parentTip.y - parentBase.y)
                let along = ((base.x - parentBase.x) * d.x + (base.y - parentBase.y) * d.y) / max(hypot(d.x, d.y), 1)
                let collar = TreeLayout.collarEnd(own: stem.nodes.first?.width ?? 0, parentWidth: joint.width,
                                                  angle: (stem.nodes.first?.heading ?? 0) - joint.heading) * frame.scale
                fork = (HandDrawn.strength(result[parent], at: Double(along)), Double(collar))
            }
            result.append(HandDrawn.pressure(seed: seeds[index] ^ 0x9E55, amount: style.pressure, length: Double(length), fork: fork))
        }
        return result
    }

    /// The wood's edges drawn as lines, shading from the wood's medium to the branch's along each limb
    /// as the limb does. A line stops where it runs into the wood it joins (a limb's inside its parent,
    /// a parent's under its limbs' collars and a sibling's beside it at the same fork, the trunk's under
    /// its roots), so what's left is the outline of one forked piece of wood: the trunk's edge turns
    /// into the bough's. `roots` are the roots' shapes and the stem they grow from (`rootLines` outlines
    /// them). An emerging stem (`draw`) lies over its parent's face, so neither's lines stop at the other.
    private func contours(_ group: [Int], _ stems: [TreeLayout.Stem], _ outlines: [[(point: CGPoint, width: CGFloat)]],
                          _ tapers: [Taper], _ seeds: [UInt64], _ collars: [Path?], parents family: (of: [Int?], emerging: Set<Int>),
                          roots: (paths: [Path], at: Int?), tops: [Path?], in context: inout GraphicsContext) {
        let sketch = Sketch(style), parents = family.of, emerging = family.emerging
        for index in group {
            let stem = stems[index], taper = tapers[index]
            guard taper.left.count >= 2, let base = outlines[index].first, let tip = outlines[index].last else { continue }
            var hidden: [Path] = []
            if let parent = parents[index], !emerging.contains(index) {
                hidden += [window(parent, around: base.point, radius: reach(index, stems, outlines), outlines, tapers), tops[parent]]
                    .compactMap { $0 }
            }
            for (other, collar) in collars.enumerated() where other != index {
                guard let collar, let otherBase = outlines[other].first else { continue }
                let child = parents[other] == index && !emerging.contains(other)
                let sibling = parents[other] != nil && parents[other] == parents[index]
                    && hypot(otherBase.point.x - base.point.x, otherBase.point.y - base.point.y) < max(base.width, otherBase.width)
                if child || sibling { hidden.append(collar) }
            }
            if index == roots.at { hidden += roots.paths }
            let alpha = style.contour * (stem.isTrunk ? 1 : 0.55 + 0.45 * vigour(tipCommit(stem)))
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [style.ink.opacity(alpha), ink(stem).opacity(alpha)]), startPoint: base.point, endPoint: tip.point)
            // Thin limbs get a finer line, so they aren't all edge.
            let width = min(style.contourWidth, max(base.width * 0.3, 0.7))
            var lines = context
            hide(hidden, around: taper.shape.boundingRect, in: &lines)
            for (side, edge) in [taper.left, taper.right].enumerated() {
                var line = Path()
                line.addLines(edge)
                sketch.stroke(line, with: shading, width: width, seed: seeds[index] &+ UInt64(side + 1), in: &lines)
            }
        }
    }

    /// The roots' outlines, each stopping under the other roots and the `trunk` they grow from.
    private func rootLines(_ roots: [Path], around trunk: Path?, seed: String, in context: inout GraphicsContext) {
        let sketch = Sketch(style)
        for (index, root) in roots.enumerated() {
            var lines = context
            let others = roots.indices.filter { $0 != index }.map { roots[$0] }
            hide(others + (trunk.map { [$0] } ?? []), around: root.boundingRect, in: &lines)
            sketch.stroke(root, with: .color(style.ink.opacity(style.contour * 0.8)), width: style.contourWidth * 0.8,
                          seed: HandDrawn.seed("\(seed)\u{1F}root", index), in: &lines)
        }
    }

    /// Clips `context` to leave out `hidden`, for drawing within `bounds`.
    private func hide(_ hidden: [Path], around bounds: CGRect, in context: inout GraphicsContext) {
        guard !hidden.isEmpty else { return }
        // A rectangle first, so the shapes' masks only cover what's drawn. It assumes a sketched line
        // strays at most 6 pt outside `bounds` (`Sketch`: under 3 pt, wobble and half its width).
        context.clip(to: Path(bounds.insetBy(dx: -6, dy: -6)))
        for path in hidden { context.clip(to: path, options: .inverse) }
    }

    /// How far from its fork stem `index` is still part of the join: past its collar, by its parent's width.
    private func reach(_ index: Int, _ stems: [TreeLayout.Stem], _ outlines: [[(point: CGPoint, width: CGFloat)]]) -> CGFloat {
        guard let fork = stems[index].fork else { return 0 }
        let stem = stems[index]
        let collar = TreeLayout.collarEnd(own: stem.nodes.first?.width ?? 0, parentWidth: fork.width,
                                          angle: (stem.nodes.first?.heading ?? 0) - fork.heading)
        return (collar + fork.width) * frame.scale
    }

    /// Stem `index`'s collar: its wood from its fork to where it has eased back to its own width.
    private func collar(_ index: Int, _ stems: [TreeLayout.Stem], _ outlines: [[(point: CGPoint, width: CGFloat)]],
                        _ tapers: [Taper]) -> Path? {
        let samples = outlines[index], taper = tapers[index]
        guard let fork = stems[index].fork, taper.left.count == samples.count, samples.count >= 2 else { return nil }
        let stem = stems[index]
        let length = TreeLayout.collarEnd(own: stem.nodes.first?.width ?? 0, parentWidth: fork.width,
                                          angle: (stem.nodes.first?.heading ?? 0) - fork.heading) * frame.scale
        var end = 1, distance: CGFloat = 0
        while end < samples.count - 1, distance < length {
            distance += hypot(samples[end].point.x - samples[end - 1].point.x, samples[end].point.y - samples[end - 1].point.y)
            end += 1
        }
        return band(taper, 0...end)
    }

    /// The part of stem `index`'s wood within `radius` of `point`: where a limb forking there lies on it.
    private func window(_ index: Int, around point: CGPoint, radius: CGFloat, _ outlines: [[(point: CGPoint, width: CGFloat)]],
                        _ tapers: [Taper]) -> Path? {
        let samples = outlines[index]
        guard tapers[index].left.count == samples.count,
              let first = samples.firstIndex(where: { hypot($0.point.x - point.x, $0.point.y - point.y) < radius }),
              let last = samples.lastIndex(where: { hypot($0.point.x - point.x, $0.point.y - point.y) < radius }) else { return nil }
        let range = max(first - 1, 0)...min(last + 1, samples.count - 1)
        return range.count >= 2 ? band(tapers[index], range) : nil
    }

    /// A stretch of a stem's shape, between two of its samples.
    private func band(_ taper: Taper, _ range: ClosedRange<Int>) -> Path {
        Path { p in
            p.move(to: taper.left[range.lowerBound])
            for point in taper.left[range].dropFirst() + taper.right[range].reversed() { p.addLine(to: point) }
            p.closeSubpath()
        }
    }

    /// All the tree's wood in brush ink, as one shape: every stem with its collar, the shared trunk's
    /// rounded top, the roots. Painted on paper, then inked as a single layer, so where wood meets
    /// wood (a limb's collar on its parent, a bough on the trunk) the outlines merge and the tone
    /// stays even, with no seam and no darker overlap.
    private func wood(_ shapes: [Path], roots: [Path], in context: inout GraphicsContext) {
        let pieces = shapes + roots
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
    /// edge, so the parent's streaks run on past the join and the limb's come out of its collar. They
    /// part around its `knots`, as the grain does.
    private func bark(_ stem: TreeLayout.Stem, _ samples: [(point: CGPoint, width: CGFloat)], around knots: [Knot],
                      in context: inout GraphicsContext) {
        guard style.barkOpacity > 0, samples.count > 2 else { return }
        var context = context
        for knot in knots { context.clip(to: knot.oval(1.35), options: .inverse) }
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
    ///
    /// The tints are one layer, and a sub-branch's replaces its parent's where its collar lies on it
    /// rather than going over it, so the fork changes colour without a darker or lighter patch.
    private func tint(_ group: [Int], _ stems: [TreeLayout.Stem], _ outlines: [[(point: CGPoint, width: CGFloat)]],
                      _ shapes: [Path], parents: [Int?], in context: inout GraphicsContext) {
        let bounds = group.filter { !stems[$0].isTrunk }.reduce(CGRect.null) { $0.union(shapes[$1].boundingRect) }
        guard !bounds.isNull else { return }
        var tints = context
        tints.clip(to: Path(bounds.insetBy(dx: -2, dy: -2)))
        tints.drawLayer { layer in
            // Per stem: the base and tip of its gradient, where it starts and with what, and its ink.
            // swiftlint:disable:next large_tuple - a throwaway record local to this closure
            var ramps: [Int: (base: CGPoint, tip: CGPoint, from: Double, start: Double, ink: Color, alpha: Double)] = [:]
            for index in group {
                let stem = stems[index]
                guard !stem.isTrunk, let base = outlines[index].first, let tip = outlines[index].last else { continue }
                let alpha = 0.55 + 0.4 * vigour(tipCommit(stem))
                var from = 0.0, fromInk = ink(stem), fromAlpha = alpha
                if let parent = parents[index], let ramp = ramps[parent] {
                    let d = CGPoint(x: ramp.tip.x - ramp.base.x, y: ramp.tip.y - ramp.base.y)
                    let u = ((base.point.x - ramp.base.x) * d.x + (base.point.y - ramp.base.y) * d.y) / max(d.x * d.x + d.y * d.y, 0.001)
                    from = Self.rampValue(u, from: ramp.from, start: ramp.start)
                    fromInk = ramp.ink
                    fromAlpha = ramp.alpha
                }
                let start = from > 0 ? 0 : 0.35
                ramps[index] = (base.point, tip.point, from, start, ink(stem), alpha)
                var wash = layer
                // A limb off plain wood starts untinted, so there's nothing under it to replace.
                if from > 0 { wash.blendMode = .copy }
                wash.fill(shapes[index], with: .linearGradient(
                    Gradient(stops: [.init(color: style.paper[1].opacity(from), location: 0),
                                     .init(color: style.paper[1].opacity(from), location: start),
                                     .init(color: style.paper[1], location: 1)]),
                    startPoint: base.point, endPoint: tip.point))
                layer.fill(shapes[index], with: .linearGradient(
                    Gradient(stops: [.init(color: fromInk.opacity(fromAlpha * from), location: 0),
                                     .init(color: fromInk.opacity(fromAlpha * from), location: start),
                                     .init(color: ink(stem).opacity(alpha), location: 1)]),
                    startPoint: base.point, endPoint: tip.point))
            }
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
    func leaves(_ stem: TreeLayout.Stem, repo: String, in context: inout GraphicsContext) {
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

    /// A small five-petalled blossom at the tip of a branch checked out in a worktree, its petals
    /// seeded from `repo` (`Pane.seed`) and the branch.
    func blossom(_ stem: TreeLayout.Stem, repo: String, in context: inout GraphicsContext) {
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

    /// The repository's name under its tree, like a plate's caption, fitted to the `slot` of ground its
    /// neighbours leave when it has one (`fittedPlate`).
    func plate(_ name: String, slot: CGFloat?, in context: inout GraphicsContext) {
        if let slot { return fittedPlate(name, slot: slot, in: &context) }
        let text = Text(name).font(style.plateFont).foregroundColor(style.ink.opacity(style.plateOpacity))
        context.draw(text, at: CGPoint(x: frame.origin.x, y: frame.origin.y + 22), anchor: .top)
    }
}
