import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Grows a `RepoTree` into geometry: the trunk rising from the ground and every limb a curving,
/// tapering run of nodes, one per commit. Pure and unit-free — the trunk of a full-grown tree is
/// 1 tall, y points up, the trunk's foot is the origin — so a renderer only scales and styles it.
///
/// Everything random is seeded: the trunk's sway from the repository's name, and a limb's side, lean
/// and every turn from its branch name and the step's index from its base. A limb's shape therefore
/// depends only on its name, where it forks and how many commits it has, so a new commit adds one step
/// at the tip and leaves every earlier node where it was.
public struct TreeLayout: Sendable {

    public struct Node: Sendable, Equatable {
        public var point: CGPoint
        /// The stem's width here, in the same units.
        public var width: Double
        /// The stem's heading: radians from straight up, positive leaning right.
        public var heading: Double
    }

    /// The trunk or one limb.
    public struct Stem: Sendable {
        /// The branch's name (nil for a trunk whose name isn't known).
        public let name: String?
        /// 0 for the trunk, 1 for a limb off the trunk, 2 for a limb off that, and so on.
        public let level: Int
        /// Node 0 is the base (the trunk's foot, a limb's fork point); node k is commit k, oldest
        /// first. While a limb is growing in, only the grown nodes are here, the last one part-way.
        public let nodes: [Node]
        /// A finer run of points along the stem through its nodes, for drawing it as a smooth curve.
        public let curve: [Node]
        /// The stem's commits, oldest first (node k is `commits[k - 1]`), grown or not.
        public let commits: [RepoTree.Commit]
        /// How many commits are grown in, fractionally (the stem's full count when not animating).
        public let grown: Double
        public let isBud: Bool
        public let isCheckedOut: Bool
        /// How large this stem's limbs are drawn relative to a low limb off the trunk.
        public let scale: Double
        /// Where it grows out of other wood (nil for a trunk standing on the ground).
        public let fork: Fork?

        public var isTrunk: Bool { level == 0 }
        public var tip: Node? { nodes.last }

        /// Whether the stem ends in a point (`TipTaper`). Every stem does but a shared trunk, which has
        /// no commits of its own and ends in the boughs it carries.
        public var tapersToTip: Bool { !(isTrunk && commits.isEmpty && !isBud) }

        /// How this stem narrows to its end, as drawn (its curve as grown so far).
        public var tipTaper: TipTaper {
            // Nothing grown yet, or a single point: no length to taper over.
            guard curve.count >= 2 else { return TipTaper(stemLength: 0) { _ in 0 } }
            let backwards = Array(curve.reversed())
            var ends = [0.0] // each node's distance from the end
            for (a, b) in zip(backwards, backwards.dropFirst()) {
                ends.append(ends[ends.count - 1] + hypot(b.point.x - a.point.x, b.point.y - a.point.y))
            }
            return TipTaper(stemLength: ends.last ?? 0) { distance in
                guard let i = ends.firstIndex(where: { $0 >= distance }) else { return backwards.last?.width ?? 0 }
                guard i > 0 else { return backwards[0].width }
                let f = (distance - ends[i - 1]) / max(ends[i] - ends[i - 1], 1e-12)
                return backwards[i - 1].width + (backwards[i].width - backwards[i - 1].width) * f
            }
        }

        /// How much of its width the stem keeps, as drawn, at the point of its curve nearest `point`: 1
        /// well back from its end, narrowing to `TipTaper.point` at it. 1 for a stem that doesn't taper
        /// or has no length yet.
        public func taperFactor(at point: CGPoint) -> Double {
            guard tapersToTip, curve.count >= 2 else { return 1 }
            let nearest = curve.indices.min { a, b in
                hypot(curve[a].point.x - point.x, curve[a].point.y - point.y)
                    < hypot(curve[b].point.x - point.x, curve[b].point.y - point.y)
            }!
            var toTip = 0.0
            for i in nearest..<(curve.count - 1) {
                toTip += hypot(curve[i + 1].point.x - curve[i].point.x, curve[i + 1].point.y - curve[i].point.y)
            }
            return tipTaper.factor(distanceToTip: toTip)
        }
    }

    /// Where a stem leaves its parent: what its base flares into (`collarWidth`).
    ///
    /// `width` is the parent's width *as drawn* there: its pipe-model width, narrowed by its own taper
    /// (`Stem.taperFactor(at:)`) where the fork lies in it, so a limb forking near its parent's end
    /// flares into the thin wood that's there, not into the wood the parent would have had.
    public struct Fork: Sendable, Equatable {
        /// The parent's index in `stems`; nil when the parent isn't in this layout (a bough's shared
        /// trunk).
        public let parent: Int?
        /// The parent's node it leaves from.
        public let node: Int
        /// The parent's width and heading there.
        public let width: Double
        public let heading: Double

        public init(parent: Int?, node: Int, width: Double, heading: Double) {
            self.parent = parent
            self.node = node
            self.width = width
            self.heading = heading
        }
    }

    /// Where and how a tree stands. Upright at the origin on its own; as a bough of a single shared
    /// tree (`YggdrasilLayout`), its trunk leaves the shared trunk's crotch leaning out and bends back
    /// up as it rises, and more of its limbs grow to the outside.
    public struct Planting: Sendable, Equatable {
        /// The trunk's foot.
        public var foot: CGPoint
        /// The trunk's lean at its foot: radians from straight up, positive leaning right.
        public var heading: Double
        /// Which side limbs off the trunk favour: -1 left, 1 right, 0 balanced.
        public var outward: Double
        /// The wood the trunk grows out of (a shared trunk's top), for its foot's collar; nil on the ground.
        public var fork: Fork?
        /// How much of its lean a leaning trunk (a bough) gives up by its tip: the default bends it most of
        /// the way back up; less keeps it reaching out sideways (`bough`).
        public var straighten: Double
        /// How long the tree grows, trunk and limbs alike, as a multiple of its own size (widths unchanged).
        public var reach: Double
        /// Whether its limbs leave the trunk the way limbs leave a limb, splayed a little to either side of
        /// it, at their own size, and bend up only gently, rather than climbing toward upright: for a bough
        /// reaching out nearly level.
        public var splay: Bool

        public init(foot: CGPoint = .zero, heading: Double = 0, outward: Double = 0, fork: Fork? = nil,
                    straighten: Double = TreeLayout.boughStraighten, reach: Double = 1, splay: Bool = false) {
            self.foot = foot
            self.heading = heading
            self.outward = outward
            self.fork = fork
            self.straighten = straighten
            self.reach = reach
            self.splay = splay
        }

        public static let upright = Planting()

        /// How long its limbs grow: as far as the tree reaches, but a splayed bough's stay their own size.
        var limbReach: Double { splay ? min(reach, 1) : reach }
        /// How much its limbs bend toward upright at each step.
        var limbTropism: Double { splay ? TreeLayout.splayTropism : TreeLayout.tropism }

        var isUpright: Bool { self == .upright }
    }

    /// The trunk first, then every limb after its parent.
    public let stems: [Stem]
    /// Every node's extent, widths included.
    public let bounds: CGRect
    /// When each stem grows during a grow-in (the same whether or not this layout is growing in), so a
    /// stem's banner can fade in as its wood finishes.
    public let schedule: GrowInSchedule

    // MARK: Shape constants

    /// The tallest a trunk grows, and the shortest (a sapling); in between it goes with the log of its
    /// drawn commits up to `fullTrunkCommits`.
    static let fullTrunkCommits = 200
    static let saplingHeight = 0.5
    /// The lowest stretch of trunk, as a fraction of its height, that no limb leaves from.
    static let bareTrunk = 0.22
    /// A low limb's first step; each later step is `stepDecay` times the one before.
    static let firstStep = 0.12
    static let step = 0.075
    static let stepDecay = 0.9
    /// How much a limb's heading turns toward straight up at each step.
    static let tropism = 0.18
    /// ... and on a splayed bough (`Planting.splay`), so its limbs keep reaching along it.
    static let splayTropism = 0.07
    /// Limbs off limbs are drawn this much smaller than their parent.
    static let childScale = 0.72
    /// A trunk commit's share of the trunk's weight, against a limb commit's 1.
    static let trunkCommitWeight = 0.35

    /// - Parameters:
    ///   - seed: the repository's identity (its name): seeds the trunk's sway.
    ///   - grown: commits grown in so far, by stem name (`RepoTree.commitCounts` keys), for a stem
    ///     that's growing; a stem not in it is fully grown.
    ///   - planting: where the trunk stands and which way it leans (upright at the origin by default).
    ///   - growIn: while the whole tree grows in from nothing, how far along it is (0…1; `growIn(…)`);
    ///     it overrides `grown`. Nil for the tree as it stands.
    ///   - shuffle: a layout seed mixed into the trunk's sway and each limb's side, lean and turns
    ///     (`SeededRandom.key(_:shuffle:)`); 0 for the shape the names alone give. The same seed always
    ///     gives the same shape, and the branching (which limb leaves where) never changes with it.
    public init(tree: RepoTree, seed: String, grown: [String: Double] = [:], planting: Planting = .upright,
                growIn: Double? = nil, shuffle: Int = 0) {
        var stems: [Stem] = []
        let weights = Self.weights(tree)

        // The trunk: a gentle seeded sway, its commits spaced on a log scale from the tip down.
        let count = tree.trunk.count
        let height = Self.trunkHeight(commits: count) * planting.reach
        var rng = SeededRandom(SeededRandom.key(seed, shuffle: shuffle), -1)
        let sway = (amplitude: rng.next(in: 0.015...0.04), waves: rng.next(in: 0.6...1.3),
                    phase: rng.next(in: 0...(2 * .pi)), lean: rng.next(in: -0.07...0.07))
        // A leaning trunk (a bough) is walked out along its length, straightening as it rises.
        let arc = planting.isUpright ? [] : Self.bough(heading: planting.heading, length: height, straighten: planting.straighten)
        func trunkPoint(_ h: Double) -> CGPoint {
            let t = h / max(height, 0.001)
            let x = sway.amplitude * sin(t * .pi * 2 * sway.waves + sway.phase) * t + sway.lean * t * t
            guard !arc.isEmpty else { return CGPoint(x: x, y: h) }
            let at = min(max(h / Self.boughStep, 0), Double(arc.count - 1))
            let i = min(Int(at), arc.count - 2), f = at - Double(i)
            let a = arc[i], b = arc[i + 1]
            return CGPoint(x: planting.foot.x + a.x + (b.x - a.x) * f + x * 0.5,
                           y: planting.foot.y + a.y + (b.y - a.y) * f)
        }
        let trunkHeights = [0] + (0..<count).map { index in height * Self.trunkLift(Self.trunkPosition(index, of: count)) }
        // Remaining weight above each trunk node: its later commits plus every limb leaving at or above.
        var above = [Double](repeating: 0, count: count + 1)
        for (index, limb) in tree.limbs.enumerated() {
            if case .trunk(let node) = limb.parent { above[min(node, count)] += weights[index] }
        }
        var running = 0.0
        for node in stride(from: count, through: 0, by: -1) {
            running += above[node] + (node < count ? Self.trunkCommitWeight : 0)
            above[node] = running
        }
        let trunkNodes = trunkHeights.enumerated().map { node, h in
            let p = trunkPoint(h), q = trunkPoint(h + 0.01)
            return Node(point: p, width: Self.width(weight: above[node] + 1), heading: atan2(q.x - p.x, q.y - p.y))
        }
        // The trunk's curve: its nodes, with points between any two far apart (the bare foot, say).
        var trunkCurve: [Node] = [], curveHeights: [Double] = []
        for (index, (a, b)) in zip(trunkNodes, trunkNodes.dropFirst()).enumerated() {
            let from = trunkHeights[index], to = trunkHeights[index + 1]
            let pieces = max(1, Int(ceil((to - from) / 0.03)))
            for piece in 0..<pieces {
                let t = Double(piece) / Double(pieces)
                let p = trunkPoint(from + (to - from) * t)
                trunkCurve.append(Node(point: p, width: a.width + (b.width - a.width) * t, heading: a.heading))
                curveHeights.append(from + (to - from) * t)
            }
        }
        trunkCurve += trunkNodes.suffix(1)
        curveHeights += trunkHeights.suffix(1)
        let trunkName = tree.trunkName ?? ""
        var trunkGrown = grown[trunkName] ?? Double(count)
        // Growing in, each stem grows over its own stretch (`growInSchedule`): the trunk rises from its
        // foot first, cut off at the height reached so far.
        let plans = Self.limbPlans(tree)
        let schedule = Self.growInSchedule(tree, plans: plans)
        let trunkReach = growIn.map { schedule.trunk.progress(at: $0) * height }
        var shownTrunk = trunkNodes, shownCurve = trunkCurve
        if let reach = trunkReach {
            shownTrunk = Self.cut(trunkNodes, heights: trunkHeights, at: reach)
            shownCurve = Self.cut(trunkCurve, heights: curveHeights, at: reach)
            let k = trunkHeights.lastIndex { $0 <= reach } ?? 0
            trunkGrown = k < count ? Double(k) + (reach - trunkHeights[k]) / max(trunkHeights[k + 1] - trunkHeights[k], 1e-9)
                                   : Double(count)
        }
        stems.append(Stem(name: tree.trunkName, level: 0, nodes: shownTrunk, curve: shownCurve, commits: tree.trunk,
                          grown: trunkGrown, isBud: false,
                          isCheckedOut: tree.isTrunkCheckedOut, scale: 1, fork: planting.fork))

        // The limbs, each grown from its parent's node.
        var limbStems: [Stem?] = []
        var stemIndex: [Int: Int] = [:]
        let sides = Self.sides(tree, outward: planting.outward, shuffle: shuffle)
        for (index, limb) in tree.limbs.enumerated() {
            let base: Node, level: Int, scale: Double, lean: Double, parentGrown: Double, fork: Fork
            let key = SeededRandom.key(limb.name, shuffle: shuffle)
            var rng = SeededRandom(key)
            let side = sides[index]
            switch limb.parent {
            case .trunk(let node):
                base = trunkNodes[min(node, trunkNodes.count - 1)]
                let u = plans[index]?.up ?? 0
                level = 1
                // Low limbs reach out nearly level and long; high ones rise steeply and stay short
                // (`limbPlans`).
                scale = plans[index]?.scale ?? 1
                lean = planting.splay ? base.heading + side * rng.next(in: 26...46) * .pi / 180
                    : side * ((88 - 48 * u) + rng.next(in: -12...12)) * .pi / 180 + (planting.isUpright ? 0 : base.heading * 0.7)
                parentGrown = .infinity
                fork = Fork(parent: 0, node: min(node, trunkNodes.count - 1),
                            width: base.width * stems[0].taperFactor(at: base.point), heading: base.heading)
            case .limb(let parentIndex, let node):
                // `RepoTree` puts a limb's parent before it; a limb whose parent isn't laid out yet
                // (or at all) is left out rather than crashing.
                guard limbStems.indices.contains(parentIndex), let parent = limbStems[parentIndex], !parent.nodes.isEmpty
                else { limbStems.append(nil); continue }
                base = parent.nodes[min(node, parent.nodes.count - 1)]
                level = parent.level + 1
                scale = plans[index]?.scale ?? parent.scale * Self.childScale
                // Mostly outward, away from the trunk, like a real crown; sometimes back in.
                var pick = SeededRandom(key, -2)
                let outward: Double = base.heading >= 0 ? 1 : -1
                let childSide = pick.next() < 0.7 ? outward : -outward
                lean = base.heading + childSide * rng.next(in: 28...50) * .pi / 180
                parentGrown = parent.grown >= Double(node) ? .infinity : 0
                fork = Fork(parent: stemIndex[parentIndex], node: min(node, parent.nodes.count - 1),
                            width: base.width * parent.taperFactor(at: base.point), heading: base.heading)
            }
            let full = Double(max(limb.commits.count, 1))
            var shown = min(full, grown[limb.name] ?? full, parentGrown)
            if let growIn {
                shown = full * schedule.limbs[index].progress(at: growIn)
            }
            let (nodes, curve) = Self.grow(limb, from: base, lean: lean, scale: scale * planting.limbReach, shown: shown,
                                           shuffle: shuffle, tropism: planting.limbTropism,
                                           weight: { k in Self.remainingWeight(limb, index: index, tree: tree, weights: weights, beyond: k) })
            let stem = Stem(name: limb.name, level: level, nodes: nodes, curve: curve, commits: limb.commits, grown: shown,
                            isBud: limb.isBud, isCheckedOut: limb.isCheckedOut, scale: scale, fork: fork)
            stemIndex[index] = stems.count
            limbStems.append(stem)
            stems.append(stem)
        }

        self.stems = stems
        self.schedule = schedule
        var bounds = CGRect.null
        for stem in stems {
            for node in stem.curve {
                bounds = bounds.union(CGRect(x: node.point.x - node.width / 2, y: node.point.y - node.width / 2,
                                             width: node.width, height: node.width))
            }
        }
        self.bounds = bounds.isNull ? .zero : bounds
    }

    // MARK: - Pieces

    /// A stem's stretch of a grow-in, as fractions of it (0…1).
    public struct Stretch: Equatable, Sendable {
        public let start: Double
        public let end: Double

        /// How far through its stretch the stem is at grow-in progress `growIn`: 0 before it, 1 after.
        public func progress(at growIn: Double) -> Double {
            min(max((growIn - start) / max(end - start, 1e-9), 0), 1)
        }

        /// How far the stem's name (its banner) has faded in at `growIn`: over the last of its
        /// stretch (`nameFade` of the grow-in, or all of it when it's shorter), whole as the stem
        /// reaches its tip.
        public func nameShown(at growIn: Double) -> Double {
            let fade = min(Self.nameFade, end - start)
            guard growIn < end else { return 1 }
            guard fade > 0 else { return 0 }
            return min(max((growIn - (end - fade)) / fade, 0), 1)
        }

        public static let nameFade = 0.08
    }

    /// When each stem grows during a grow-in.
    public struct GrowInSchedule: Equatable, Sendable {
        public let trunk: Stretch
        /// By limb, in `RepoTree.limbs` order.
        public let limbs: [Stretch]
        let names: [String: Int]

        /// The stretch of the stem named `name` (a `RepoTree.commitCounts` key), or nil.
        public func stretch(of name: String) -> Stretch? {
            names[name].map { $0 < 0 ? trunk : limbs[$0] }
        }
    }

    /// Each limb grows at the pace the trunk rises: a full-height trunk's height in one unit of time,
    /// a limb over its own length (at least this long, so a bud still opens).
    static let shortestLimbTime = 0.12

    /// Where a limb leaves and how it grows, worked out from the tree alone before anything is laid
    /// out, so the layout and its grow-in schedule can't disagree: for a limb off the trunk, how far up
    /// the trunk it leaves (0…1, `trunkPosition`); the scale it's drawn at; and its stretch of a
    /// grow-in, in units of the trunk's rise, before scaling.
    struct LimbPlan {
        let up: Double?
        let scale: Double
        let start: Double
        let end: Double
    }

    /// Each limb's plan, in `RepoTree.limbs` order; nil for one that's left out (its parent comes
    /// after it, or is left out too). A limb off the trunk starts growing when the trunk rises past
    /// its fork, a limb off a limb when its parent reaches its fork, and each grows out over its own
    /// length at the pace the trunk rose (at least `shortestLimbTime`).
    static func limbPlans(_ tree: RepoTree) -> [LimbPlan?] {
        let count = tree.trunk.count
        // A stem's length in units of its trunk's height.
        let height = trunkHeight(commits: count)
        var plans: [LimbPlan?] = []
        for limb in tree.limbs {
            let up: Double?, scale: Double, start: Double
            switch limb.parent {
            case .trunk(let node):
                let u = node == 0 ? 0 : trunkPosition(min(node, count) - 1, of: count)
                up = u
                scale = 1.05 - 0.45 * u
                start = node == 0 ? 0 : trunkLift(u)
            case .limb(let parentIndex, let node):
                guard plans.indices.contains(parentIndex), let parent = plans[parentIndex] else { plans.append(nil); continue }
                let parentCount = Double(max(tree.limbs[parentIndex].commits.count, 1))
                up = nil
                scale = parent.scale * childScale
                start = parent.start + (parent.end - parent.start) * min(Double(node) / parentCount, 1)
            }
            let length = length(commits: max(limb.commits.count, 1), scale: scale, bud: limb.isBud)
            plans.append(LimbPlan(up: up, scale: scale, start: start, end: start + max(length / height, shortestLimbTime)))
        }
        return plans
    }

    /// When each stem of `tree` grows during a grow-in: the trunk rises first, from its foot; then
    /// each limb over its stretch (`limbPlans`), so the low limbs finish first and the outermost twigs
    /// last. Scaled so the last stem finishes at 1. A limb that's left out gets an empty stretch at
    /// the end.
    static func growInSchedule(_ tree: RepoTree, plans: [LimbPlan?]? = nil) -> GrowInSchedule {
        let plans = plans ?? limbPlans(tree)
        let total = max(plans.compactMap { $0?.end }.max() ?? 1, 1)
        var names = [tree.trunkName ?? "": -1]
        for (index, limb) in tree.limbs.enumerated() { names[limb.name] = index }
        return GrowInSchedule(trunk: Stretch(start: 0, end: 1 / total),
                              limbs: plans.map { plan in
                                  plan.map { Stretch(start: $0.start / total, end: $0.end / total) } ?? Stretch(start: 1, end: 1)
                              },
                              names: names)
    }

    /// How long a limb of `commits` grows (`grow`'s steps), in tree units, at `scale`.
    static func length(commits: Int, scale: Double, bud: Bool) -> Double {
        var length = (bud ? 0.35 : 1) * firstStep * scale, total = 0.0
        for k in 1...max(commits, 1) {
            total += length
            length = k == 1 ? step * scale : length * stepDecay
        }
        return total
    }

    /// Eased grow-in progress for the time since it began, as a fraction of its duration.
    public static func growIn(_ fraction: Double) -> Double {
        let t = min(max(fraction, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The run of `nodes` (at `heights` along the stem) up to `reach`, the last one placed part-way.
    static func cut(_ nodes: [Node], heights: [Double], at reach: Double) -> [Node] {
        guard let first = nodes.first else { return [] }
        var kept = [first]
        for i in nodes.indices.dropFirst() {
            if heights[i] <= reach { kept.append(nodes[i]); continue }
            let a = nodes[i - 1], b = nodes[i]
            let span = heights[i] - heights[i - 1]
            let f = span > 0 ? (reach - heights[i - 1]) / span : 0
            if f > 0 {
                kept.append(Node(point: CGPoint(x: a.point.x + (b.point.x - a.point.x) * f, y: a.point.y + (b.point.y - a.point.y) * f),
                                 width: a.width + (b.width - a.width) * f, heading: b.heading))
            }
            break
        }
        return kept
    }

    /// A trunk of `commits` drawn commits: a sapling for a young repository, full height from
    /// `fullTrunkCommits` on.
    static func trunkHeight(commits: Int) -> Double {
        let t = min(1, log(Double(max(commits, 1))) / log(Double(fullTrunkCommits)))
        return saplingHeight + (1 - saplingHeight) * t
    }

    /// How far up the trunk (0 at its oldest drawn commit, 1 at its tip) trunk commit `index` (oldest
    /// first) sits: on a log scale of its depth below the tip, so recent history has the most room.
    static func trunkPosition(_ index: Int, of count: Int) -> Double {
        guard count > 1 else { return 1 }
        let depth = Double(count - 1 - index)
        return 1 - log1p(depth) / log1p(Double(count - 1))
    }

    /// A trunk position as a fraction of the trunk's height, above its bare foot.
    static func trunkLift(_ u: Double) -> Double { bareTrunk + (1 - bareTrunk) * u }

    /// Width for a stem carrying `weight` commits beyond it: the pipe model, width² ∝ what it feeds.
    static func width(weight: Double) -> Double { 0.0042 * sqrt(max(weight, 0)) + 0.0022 }

    /// Each limb's weight: its own commits plus everything growing off it (a bud weighs half).
    static func weights(_ tree: RepoTree) -> [Double] {
        var weights = tree.limbs.map { $0.isBud ? 0.5 : Double($0.commits.count) }
        // Children follow parents, so a reverse pass rolls each up into its parent.
        for (index, limb) in tree.limbs.enumerated().reversed() {
            if case .limb(let parent, _) = limb.parent, parent < index { weights[parent] += weights[index] }
        }
        return weights
    }

    /// Which way each limb leans off its parent: -1 left, 1 right. Limbs off the trunk balance the
    /// crown, from the ground up: each leans away from the side the limbs below it weigh down, and
    /// picks by its name's hash when they're even. A limb weighs as many branches as it carries (itself
    /// and its sub-branches), never its commits, so a commit can't flip a limb; and working upward
    /// keeps it stable where it matters — new branches mostly fork from recent trunk, at the top, so
    /// they never flip the limbs below them. (Limbs off limbs choose their own side as they grow:
    /// mostly outward.)
    ///
    /// A bough's limbs favour its outer side (`outward`): the tally starts that far behind on it, so
    /// roughly the first half of the limbs go outward before the balancing begins.
    static func sides(_ tree: RepoTree, outward: Double = 0, shuffle: Int = 0) -> [Double] {
        var sides = tree.limbs.map { limb -> Double in
            var rng = SeededRandom(SeededRandom.key(limb.name, shuffle: shuffle))
            return rng.next() < 0.5 ? -1 : 1
        }
        var branches = [Double](repeating: 1, count: tree.limbs.count)
        for (index, limb) in tree.limbs.enumerated().reversed() {
            if case .limb(let parent, _) = limb.parent, parent < index { branches[parent] += branches[index] }
        }
        let offTrunk = tree.limbs.indices.compactMap { index -> (index: Int, node: Int)? in
            if case .trunk(let node) = tree.limbs[index].parent { return (index, node) }
            return nil
        }.sorted { a, b in a.node != b.node ? a.node < b.node : tree.limbs[a.index].name < tree.limbs[b.index].name }
        var lean = -outward * max(1, Double(offTrunk.count) * 0.6)
        for (index, _) in offTrunk {
            if lean > 0 { sides[index] = -1 } else if lean < 0 { sides[index] = 1 }
            lean += sides[index] * branches[index]
        }
        return sides
    }

    /// What a limb still carries beyond node `k`: its later commits and the limbs leaving at or after it.
    static func remainingWeight(_ limb: RepoTree.Limb, index: Int, tree: RepoTree, weights: [Double], beyond k: Int) -> Double {
        var weight = Double(max(limb.commits.count - k, 0))
        for (child, other) in tree.limbs.enumerated() {
            if case .limb(let parent, let node) = other.parent, parent == index, node >= k { weight += weights[child] }
        }
        return weight + 0.5
    }

    /// Walk a limb out from its base, a step per commit: each step a little shorter than the last,
    /// turning by a seeded amount and bending toward straight up, spread over a few sub-steps so a
    /// long step curves too. `shown` commits are grown, the last one part-way. Returns the commit
    /// nodes and the finer curve through them.
    static func grow(_ limb: RepoTree.Limb, from base: Node, lean: Double, scale: Double, shown: Double,
                     shuffle: Int = 0, tropism: Double = tropism, weight: (Int) -> Double) -> (nodes: [Node], curve: [Node]) {
        let steps = Int(ceil(shown))
        guard steps > 0 else { return ([], []) }
        var nodes = [Node(point: base.point, width: min(base.width, width(weight: weight(0))), heading: lean)]
        var curve = nodes
        var heading = lean
        var point = base.point
        var length = (limb.isBud ? 0.35 : 1) * firstStep * scale
        let bendPerSubstep = 1 - pow(1 - tropism, 1 / Double(substeps))
        for k in 1...steps {
            var rng = SeededRandom(SeededRandom.key(limb.name, shuffle: shuffle), k)
            let turn = rng.next(in: -11...11) * .pi / 180
            let fraction = min(1, shown - Double(k - 1))
            let from = curve[curve.count - 1].width, to = width(weight: weight(k))
            for j in 1...substeps {
                let start = Double(j - 1) / Double(substeps)
                guard fraction > start else { break }
                let part = min(1 / Double(substeps), fraction - start)
                heading += turn / Double(substeps)
                heading -= heading * bendPerSubstep
                heading = min(max(heading, -1.75), 1.75)
                point = CGPoint(x: point.x + sin(heading) * length * part, y: point.y + cos(heading) * length * part)
                let t = start + part
                curve.append(Node(point: point, width: from + (to - from) * t, heading: heading))
            }
            nodes.append(curve[curve.count - 1])
            length = (k == 1 ? step * scale : length * stepDecay)
        }
        return (nodes, curve)
    }

    /// How a stem narrows to a point at its end. The layout's widths (the pipe model) never get below
    /// a floor at the last node, which drawn as is leaves a flat cut, so the drawing multiplies a
    /// stem's width by `factor` over its last `length`: from 1 where the taper starts (easing in, so
    /// there's no corner there) to a fine point at the very end.
    public struct TipTaper: Sendable, Equatable {
        /// How far from the end the taper starts, in tree units.
        public let length: Double

        /// The taper is this many times the stem's width where it starts, ...
        static let reach = 12.0
        /// ... but at most this much of the stem, so a short limb or a bud is a thorn: pointed over
        /// nearly all of it, rather than a stub with a point on.
        static let share = 0.85
        /// The factor at the very end: a point as fine as a line.
        static let point = 0.04

        /// - Parameters:
        ///   - stemLength: how long the stem is as drawn (as grown so far, while it's growing).
        ///   - widthAt: the stem's width, before tapering, `distance` from its end. It's asked where
        ///     the taper would start, so a stem that's still wide a little way back (a trunk's top)
        ///     tapers over a longer stretch than one that's already fine.
        public init(stemLength: Double, widthAt: (Double) -> Double) {
            var length = Self.reach * widthAt(0)
            for _ in 0..<2 { length = Self.reach * widthAt(min(length, stemLength)) }
            self.length = max(min(length, Self.share * stemLength), 0)
        }

        /// The width's multiplier `distance` from the end (0 at the end; 1 from `length` on).
        public func factor(distanceToTip distance: Double) -> Double {
            guard length > 0, distance < length else { return 1 }
            let s = max(distance / length, 0)
            return Self.point + (1 - Self.point) * sin(s * .pi / 2)
        }
    }

    /// A branch collar: how wide a stem is drawn `distance` along it from its fork (tree units), where
    /// its own width there is `own` and its parent's is `parentWidth`, leaving at `angle` (radians) off
    /// the parent's heading. Inside the parent's wood it's as wide as the parent allows (up to
    /// `collarFlare` times its own); from where it leaves the parent's edge it eases back to its own
    /// width over `collarLength` of its own widths, concave like a fillet, so the outlines run into
    /// each other instead of meeting at a corner.
    public static func collarWidth(at distance: Double, own: Double, parentWidth: Double, angle: Double) -> Double {
        let flared = max(own, min(parentWidth * 0.9, own * collarFlare))
        let t = (distance - collarExit(parentWidth: parentWidth, angle: angle)) / (own * collarLength)
        if t <= 0 { return flared }
        if t >= 1 { return own }
        return own + (flared - own) * pow(1 - t, 2.4)
    }

    /// How far along a stem leaving at `angle` it crosses its parent's edge.
    public static func collarExit(parentWidth: Double, angle: Double) -> Double {
        parentWidth / 2 / max(abs(sin(angle)), 0.35)
    }

    /// How far along a stem leaving at `angle` its collar has eased back to its own width.
    public static func collarEnd(own: Double, parentWidth: Double, angle: Double) -> Double {
        collarExit(parentWidth: parentWidth, angle: angle) + own * collarLength
    }

    static let collarFlare = 2.0
    static let collarLength = 2.4

    /// Sub-steps per commit step in a limb's curve.
    static let substeps = 4

    /// A bough's centreline, from its foot, a point every `boughStep` of its length: it leaves at
    /// `heading` and straightens toward its tip, giving up `straighten` of its lean (by default, down to
    /// about a third of it).
    static func bough(heading: Double, length: Double, straighten: Double = boughStraighten) -> [CGPoint] {
        var points = [CGPoint.zero]
        var point = CGPoint.zero
        let count = Int(ceil((length + 0.05) / boughStep))
        for i in 1...max(count, 1) {
            let t = min(Double(i) / max(length / boughStep, 1), 1)
            let h = heading * (1 - straighten * t)
            point = CGPoint(x: point.x + sin(h) * boughStep, y: point.y + cos(h) * boughStep)
            points.append(point)
        }
        return points
    }

    static let boughStep = 0.005
    /// How much of its lean a bough gives up by its tip, unless its planting says otherwise.
    public static let boughStraighten = 0.65

    /// The trunk's width at its foot, before it's grown: what a shared trunk has to carry for it.
    public static func footWidth(_ tree: RepoTree) -> Double {
        let weights = weights(tree)
        let limbs = tree.limbs.indices.reduce(0.0) { total, index in
            if case .trunk = tree.limbs[index].parent { return total + weights[index] }
            return total
        }
        return width(weight: limbs + Double(tree.trunk.count) * trunkCommitWeight + 1)
    }
}
