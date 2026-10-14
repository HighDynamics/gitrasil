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
        /// The limbs leaving it, each where it leaves and how wide its base is: its taper never narrows it
        /// below one before that limb leaves (`tipTaper`), so one carrying on from its tip carries on from
        /// wood as wide as itself.
        public var carries: [Carry] = []
        /// Knots drawn on its wood at some of its elbows.
        public var knots: [Knot] = []

        /// How wide the widest limb carrying on from its very tip is, once it's grown that far (nil for
        /// none): the stem ends that wide, rather than in a point (`tipTaper`).
        public var carriedOn: Double? {
            carries.filter { $0.node == nodes.count - 1 && Double($0.node) <= grown }.map(\.width).max()
        }

        public var isTrunk: Bool { level == 0 }
        public var tip: Node? { nodes.last }

        /// Whether the stem ends in a point (`TipTaper`). Every stem does but a shared trunk, which has
        /// no commits of its own and ends in the boughs it carries.
        public var tapersToTip: Bool { !(isTrunk && commits.isEmpty && !isBud) }

        /// How this stem narrows to its end, as drawn (its curve as grown so far), held as wide as each
        /// limb leaving it until that limb leaves (`carries`, once it's grown that far).
        public var tipTaper: TipTaper {
            // Nothing grown yet, or a single point: no length to taper over.
            guard curve.count >= 2 else { return TipTaper(stemLength: 0) { _ in 0 } }
            let backwards = Array(curve.reversed())
            var ends = [0.0] // each node's distance from the end
            for (a, b) in zip(backwards, backwards.dropFirst()) {
                ends.append(ends[ends.count - 1] + hypot(b.point.x - a.point.x, b.point.y - a.point.y))
            }
            let holds = carries.compactMap { carry -> (distance: Double, width: Double)? in
                guard nodes.indices.contains(carry.node), Double(carry.node) <= grown else { return nil }
                let wood = nodes[carry.node].point
                let nearest = curve.indices.min { a, b in
                    hypot(curve[a].point.x - wood.x, curve[a].point.y - wood.y) < hypot(curve[b].point.x - wood.x, curve[b].point.y - wood.y)
                }!
                return (ends[curve.count - 1 - nearest], carry.width)
            }
            return TipTaper(stemLength: ends.last ?? 0, holds: holds) { distance in
                guard let i = ends.firstIndex(where: { $0 >= distance }) else { return backwards.last?.width ?? 0 }
                guard i > 0 else { return backwards[0].width }
                let f = (distance - ends[i - 1]) / max(ends[i] - ends[i - 1], 1e-12)
                return backwards[i - 1].width + (backwards[i].width - backwards[i - 1].width) * f
            }
        }

        /// The stem with its wood `girth` times as thick, and its fork's on its parent (but not the wood
        /// a trunk grows out of, which isn't its own).
        func thinned(_ girth: Double) -> Stem {
            func thin(_ node: Node) -> Node { Node(point: node.point, width: node.width * girth, heading: node.heading) }
            let joint = level == 0 ? fork : fork.map { Fork(parent: $0.parent, node: $0.node, width: $0.width * girth, heading: $0.heading) }
            return Stem(name: name, level: level, nodes: nodes.map(thin), curve: curve.map(thin), commits: commits, grown: grown,
                        isBud: isBud, isCheckedOut: isCheckedOut, scale: scale, fork: joint,
                        carries: carries.map { Carry(node: $0.node, width: $0.width * girth) }, knots: knots)
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

    /// A knot in the wood at a joint, drawn on it (`TreeDrawing`): at `index` along the stem's curve, `size`
    /// of the wood's width there across, a little to the outside of the turn: `side` 1 is the stem's right
    /// as it heads out, -1 its left.
    public struct Knot: Sendable, Equatable {
        public let index: Int
        public let size: Double
        public let side: Double
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
        /// How thick its wood is drawn, trunk and limbs alike, as a multiple of what the pipe model gives.
        public var girth: Double

        public init(foot: CGPoint = .zero, heading: Double = 0, outward: Double = 0, fork: Fork? = nil,
                    straighten: Double = TreeLayout.boughStraighten, reach: Double = 1, splay: Bool = false,
                    girth: Double = 1) {
            self.foot = foot
            self.heading = heading
            self.outward = outward
            self.fork = fork
            self.straighten = straighten
            self.reach = reach
            self.splay = splay
            self.girth = girth
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
        // A leaning trunk (a bough) is walked out along its length, straightening as it rises and bending
        // its own way, at an elbow or two if it's long.
        let bend = planting.isUpright ? Bend.none : Bend(seed, shuffle: shuffle, side: planting.heading < 0 ? -1 : 1, length: height)
        let arc = planting.isUpright ? [] : Self.bough(heading: planting.heading, length: height, straighten: planting.straighten,
                                                       bend: bend)
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
        let (trunkCurve, curveHeights) = Self.trunkCurve(trunkNodes, heights: trunkHeights, height: height, bend: bend, at: trunkPoint)
        // A knot at each elbow that has one, where it turns.
        let trunkKnots = bend.elbows.filter { $0.knot > 0 }.map { elbow in
            let h = elbow.at * height
            let index = curveHeights.indices.min { abs(curveHeights[$0] - h) < abs(curveHeights[$1] - h) } ?? 0
            return Knot(index: index, size: elbow.knot, side: elbow.turn > 0 ? -1 : 1)
        }
        let carries = Self.carries(tree, weights: weights, count: count)
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
                          isCheckedOut: tree.isTrunkCheckedOut, scale: 1, fork: planting.fork,
                          carries: carries[-1] ?? [], knots: trunkKnots.filter { $0.index < shownCurve.count }))

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
            let (nodes, curve, knots) = Self.grow(limb, from: base, lean: lean, scale: scale * planting.limbReach, shown: shown,
                                           shuffle: shuffle, tropism: planting.limbTropism,
                                           weight: { k in Self.remainingWeight(limb, index: index, tree: tree, weights: weights, beyond: k) })
            let stem = Stem(name: limb.name, level: level, nodes: nodes, curve: curve, commits: limb.commits, grown: shown,
                            isBud: limb.isBud, isCheckedOut: limb.isCheckedOut, scale: scale, fork: fork,
                            carries: carries[index] ?? [], knots: knots)
            stemIndex[index] = stems.count
            limbStems.append(stem)
            stems.append(stem)
        }

        if planting.girth != 1 { stems = stems.map { $0.thinned(planting.girth) } }
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

    /// The trunk's curve, and each point's height up it: its `nodes` (at `heights`), with points between
    /// any two far apart (the bare foot, say), and closer through an elbow of its `bend`, so it turns there
    /// rather than kinks, its wood thickening at the joint. `point` places a height up the trunk.
    private static func trunkCurve(_ nodes: [Node], heights: [Double], height: Double, bend: Bend,
                                   at point: (Double) -> CGPoint) -> (curve: [Node], heights: [Double]) {
        // Where the elbows turn, as heights up the trunk.
        let joints = bend.elbows.map { (from: ($0.at - $0.span * 0.75) * height, to: ($0.at + $0.span * 0.75) * height) }
        var curve: [Node] = [], curveHeights: [Double] = []
        for (index, (a, b)) in zip(nodes, nodes.dropFirst()).enumerated() {
            let from = heights[index], to = heights[index + 1]
            let pieces = max(1, Int(ceil((to - from) / 0.03)))
            var hs = (0..<pieces).map { from + (to - from) * Double($0) / Double(pieces) }
            for joint in joints where joint.from < to && joint.to > from {
                hs += stride(from: max(joint.from, from), to: min(joint.to, to), by: elbowStep).filter { $0 > from }
            }
            for h in Set(hs).sorted() {
                let t = (h - from) / max(to - from, 1e-12)
                curve.append(Node(point: point(h), width: (a.width + (b.width - a.width) * t) * bend.knuckle(at: h / max(height, 0.001)),
                                  heading: a.heading))
                curveHeights.append(h)
            }
        }
        return (curve + nodes.suffix(1), curveHeights + heights.suffix(1))
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
    /// turning by a seeded amount, curling its own seeded way (`limbCurl`) and bending toward straight
    /// up, spread over a few sub-steps so a long step curves too. Now and then, past its first few
    /// steps, a step turns sharply at an elbow (`limbElbow`), thickening a little at the joint, so a long
    /// limb has more of them, some with a knot (`limbKnot`). `shown` commits are grown, the last one
    /// part-way. Returns the commit nodes, the finer curve through them and the knots on it.
    static func grow(_ limb: RepoTree.Limb, from base: Node, lean: Double, scale: Double, shown: Double,
                     shuffle: Int = 0, tropism: Double = tropism, weight: (Int) -> Double) -> (nodes: [Node], curve: [Node], knots: [Knot]) {
        let steps = Int(ceil(shown))
        guard steps > 0 else { return ([], [], []) }
        var knots: [Knot] = []
        var nodes = [Node(point: base.point, width: min(base.width, width(weight: weight(0))), heading: lean)]
        var curve = nodes
        var heading = lean
        var point = base.point
        var length = (limb.isBud ? 0.35 : 1) * firstStep * scale
        let bendPerSubstep = 1 - pow(1 - tropism, 1 / Double(substeps))
        // The same every step, so a new commit curls on as the others did and moves none of them.
        let curl = curl(of: limb.name, shuffle: shuffle)
        // Each step's elbow hangs only on the steps before it, so a new commit moves none of them either.
        var lastElbow = 0.0
        for k in 1...steps {
            var rng = SeededRandom(SeededRandom.key(limb.name, shuffle: shuffle), k)
            let turn = rng.next(in: -11...11) * .pi / 180
            let elbow = elbow(of: limb.name, shuffle: shuffle, step: k, after: lastElbow)
            if elbow != 0 { lastElbow = elbow }
            let knuckle = Self.knuckle(elbow)
            let fraction = min(1, shown - Double(k - 1))
            let from = curve[curve.count - 1].width, to = width(weight: weight(k))
            for j in 1...substeps {
                let start = Double(j - 1) / Double(substeps)
                guard fraction > start else { break }
                let part = min(1 / Double(substeps), fraction - start)
                // An elbow turns over the step's first half, the joint at its middle.
                heading += turn / Double(substeps) + curl * part + (j <= 2 ? elbow * part * 2 : 0)
                heading -= heading * bendPerSubstep
                heading = min(max(heading, -1.75), 1.75)
                point = CGPoint(x: point.x + sin(heading) * length * part, y: point.y + cos(heading) * length * part)
                let t = start + part
                var thick = j == 1 ? knuckle : j == 2 ? 1 + (knuckle - 1) * 0.4 : 1
                if j == 1, elbow != 0, let size = Self.knot(of: limb.name, shuffle: shuffle, step: k) {
                    knots.append(Knot(index: curve.count, size: size, side: elbow > 0 ? -1 : 1))
                    thick += Self.burl
                }
                curve.append(Node(point: point, width: (from + (to - from) * t) * thick, heading: heading))
            }
            nodes.append(curve[curve.count - 1])
            length = (k == 1 ? step * scale : length * stepDecay)
        }
        return (nodes, curve, knots)
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
    /// How far a limb curls its own way each step, in degrees (seeded by its name); tropism pulls it back
    /// toward upright, so a long limb settles into an arc rather than curling round.
    static let limbCurl: ClosedRange<Double> = 2...4
    /// A limb's elbows: from its `limbElbowFrom`th step on, each step has this chance of one, turning it
    /// this many degrees, back the other way from its last elbow more often than not. Tropism eases it
    /// back toward upright after, as a real limb grows on toward the light.
    static let limbElbowChance = 0.24
    static let limbElbowFrom = 3
    static let limbElbow: ClosedRange<Double> = 22...40
    /// How much wider the wood is at an elbow's joint, at most (for the sharpest), and at least.
    static let knuckleWidth: ClosedRange<Double> = 0.18...0.38
    /// How often an elbow has a knot drawn at its joint, on a bough and on a limb, and how big it is, as a
    /// share of the wood's width there.
    static let boughKnotChance = 0.55
    static let limbKnotChance = 0.4
    static let knotSize: ClosedRange<Double> = 0.6...0.9
    /// How much wider again the wood swells at a joint with a knot.
    static let burl = 0.3

    /// Where a limb's knots draw from, step by step: a base of their own, far enough below every other stream a
    /// name is keyed with here (-1, -2, -3, -21, a bough's -23…-27, a limb's elbows -100 - step, its steps 0…)
    /// that no step count reaches one.
    static let knotStream = -1_000_000

    /// How big a knot the elbow at limb `name`'s step `step` has (`knotSize`), or nil for none.
    static func knot(of name: String, shuffle: Int, step: Int) -> Double? {
        var rng = SeededRandom(SeededRandom.key(name, shuffle: shuffle), knotStream - step)
        let has = rng.next() < limbKnotChance, size = rng.next(in: knotSize)
        return has ? size : nil
    }

    /// The elbow limb `name` turns at its step `step`, in radians, or 0 where it has none; `after` is the
    /// last elbow before it (0 for none).
    static func elbow(of name: String, shuffle: Int, step: Int, after last: Double) -> Double {
        guard step >= limbElbowFrom else { return 0 }
        var rng = SeededRandom(SeededRandom.key(name, shuffle: shuffle), -100 - step)
        guard rng.next() < limbElbowChance else { return 0 }
        let back = rng.next() < 0.7
        let way: Double = last == 0 ? (rng.next() < 0.5 ? -1 : 1) : (back ? -1 : 1) * (last < 0 ? -1 : 1)
        return way * rng.next(in: limbElbow) * .pi / 180
    }

    /// How much wider the wood is at the joint of an elbow turning `turn` radians.
    static func knuckle(_ turn: Double) -> Double {
        guard turn != 0 else { return 1 }
        let sharpness = min(abs(turn) / (boughElbow.upperBound * .pi / 180), 1)
        return 1 + knuckleWidth.lowerBound + (knuckleWidth.upperBound - knuckleWidth.lowerBound) * sharpness
    }

    /// How far the limb `name` curls each step, in radians, either way (`limbCurl`).
    static func curl(of name: String, shuffle: Int) -> Double {
        var rng = SeededRandom(SeededRandom.key(name, shuffle: shuffle), -21)
        return (rng.next() < 0.5 ? -1 : 1) * rng.next(in: limbCurl) * .pi / 180
    }

    /// A joint where a bough turns sharply and carries on its new way (`Bend`): `turn` radians (as a
    /// bend's `curl`), turned over `span` of the bough's length centred `at` along it (both as `t`).
    /// `knot` is how big a knot is drawn at its joint (`knotSize`), 0 for none.
    public struct Elbow: Sendable, Equatable {
        public var at: Double
        public var span: Double
        public var turn: Double
        public var knot: Double

        public init(at: Double, span: Double, turn: Double, knot: Double = 0) {
            self.at = at
            self.span = span
            self.turn = turn
            self.knot = knot
        }

        /// How much of its turn it has made by `t`: none before it, all after, smoothly between.
        func made(at t: Double) -> Double {
            let u = min(max((t - at) / span + 0.5, 0), 1)
            return u * u * (3 - 2 * u)
        }
    }

    /// A bough's own bend, on top of its straightening (`bough`): its heading at `t` along it (0 at its
    /// foot, 1 at its tip) turns by `curl·t² + wave·sin(πt)·t`, a curl gathering toward the tip and a bow
    /// along its middle, and at each of its elbows by that elbow's turn. Each is nothing, and level, at
    /// the foot, so the bough still leaves where and how its planting says.
    public struct Bend: Sendable, Equatable {
        /// Radians, positive turning clockwise (right, on a bough leaning right: down).
        public var curl: Double
        public var wave: Double
        public var elbows: [Elbow] = []

        public static let none = Bend(curl: 0, wave: 0)

        public init(curl: Double, wave: Double, elbows: [Elbow] = []) {
            self.curl = curl
            self.wave = wave
            self.elbows = elbows
        }

        /// Seeded by the repository's name (`seed`) and the layout seed, for a bough leaning to `side`
        /// (-1 left, 1 right) and `length` long: the curl turns it up toward the light more often than
        /// down, and a bough leaning left bends as the mirror of one leaning right. Each elbow has its own
        /// place, a seeded distance from the foot (`elbowFirst`, then about every `elbowEvery`), and is
        /// there once the bough is long enough to hold it (`elbowReach`), at most `mostElbows`: a short
        /// bough stays simple, and one growing longer gains an elbow where there's room and leaves the
        /// others where they were. After the first, each turns back the other way more often than not
        /// (back up after a droop, say), and none takes the bough past `boughTurn` (`fitted`).
        public init(_ seed: String, shuffle: Int, side: Double, length: Double) {
            var rng = SeededRandom(SeededRandom.key(seed, shuffle: shuffle), -3)
            let up: Double = rng.next() < 0.68 ? -side : side
            curl = up * rng.next(in: TreeLayout.boughCurl) * .pi / 180
            wave = side * (rng.next() < 0.5 ? -1 : 1) * rng.next(in: TreeLayout.boughWave) * .pi / 180
            let most = TreeLayout.boughTurn * .pi / 180
            var way = side
            for k in 0..<TreeLayout.mostElbows {
                // Its own draws, all of them every time, so nothing about it hangs on how many there are.
                var joint = SeededRandom(SeededRandom.key(seed, shuffle: shuffle), -23 - k)
                let distance = TreeLayout.elbowFirst + TreeLayout.elbowEvery * (Double(k) + joint.next(in: k == 0 ? 0...0.3 : -0.3...0.3))
                let down = joint.next() < 0.45, back = joint.next() < 0.7
                let size = joint.next(in: TreeLayout.boughElbow) * .pi / 180
                let knotted = joint.next() < TreeLayout.boughKnotChance, knot = joint.next(in: TreeLayout.knotSize)
                guard distance <= TreeLayout.elbowReach * length else { break }
                way = k == 0 ? (down ? side : -side) : (back ? -way : way)
                let elbow = Elbow(at: distance / length, span: TreeLayout.elbowSpan / length, turn: way * size, knot: knotted ? knot : 0)
                guard let fitted = fitted(elbow, within: most) else { continue }
                way = fitted.turn < 0 ? -1 : 1
                elbows.append(fitted)
            }
        }

        /// `elbow` as it can turn on top of the curl, the wave and the elbows before it without turning the
        /// bough more than `most` from its planting's heading anywhere past it: its own way if it can, else
        /// the other way, else smaller; nil if even a small one can't.
        private func fitted(_ elbow: Elbow, within most: Double) -> Elbow? {
            for scale in [1.0, 0.8, 0.6, 0.4] {
                for way in [1.0, -1.0] {
                    var trial = self
                    trial.elbows.append(Elbow(at: elbow.at, span: elbow.span, turn: elbow.turn * scale * way, knot: elbow.knot))
                    if trial.most(from: elbow.at - elbow.span / 2) <= most - Self.sampling { return trial.elbows.last }
                }
            }
            return nil
        }

        /// The most it turns the heading either way, from `t` along the bough to its tip, sampled every 0.002:
        /// between samples it can turn up to about `sampling` further.
        func most(from t: Double) -> Double {
            stride(from: max(t, 0), through: 1, by: 0.002).reduce(abs(turn(at: 1))) { max($0, abs(turn(at: $1))) }
        }

        static let sampling = 0.05 * .pi / 180

        /// How far it turns the heading at `t` along the bough.
        public func turn(at t: Double) -> Double {
            elbows.reduce(curl * t * t + wave * sin(.pi * t) * t) { $0 + $1.turn * $1.made(at: t) }
        }

        /// How much wider the bough's wood is at `t` along it: thicker at each elbow's joint (`knuckle`), and
        /// thicker still at one with a knot (`burl`).
        public func knuckle(at t: Double) -> Double {
            elbows.reduce(1) { total, elbow in
                let d = (t - elbow.at) / elbow.span
                return total + (TreeLayout.knuckle(elbow.turn) - 1 + (elbow.knot > 0 ? TreeLayout.burl : 0)) * exp(-d * d * 4)
            }
        }
    }

    /// How far a bough's curl turns it by its tip, and its bow at most, in degrees.
    static let boughCurl: ClosedRange<Double> = 8...20
    static let boughWave: ClosedRange<Double> = 4...11
    /// How far a bough's elbow turns it, in degrees, before `boughTurn` holds it back; and how much of
    /// its length an elbow takes to turn (in tree units, about one and a half of a bough's widths).
    static let boughElbow: ClosedRange<Double> = 24...44
    static let elbowSpan = 0.05
    /// The most a bough's curl, wave and elbows together ever turn it from its planting's heading, either
    /// way, in degrees, so it zigzags rather than curling round. The one place the cap is set.
    static let boughTurn = 36.0
    /// Where a bough's elbows fall, in tree units from its foot: the first at least `elbowFirst` out, each
    /// next about `elbowEvery` further (seeded, ±30% of that), and only within `elbowReach` of its length,
    /// so none turns right at its tip; at most `mostElbows`.
    static let elbowFirst = 0.28
    static let elbowEvery = 0.28
    static let elbowReach = 0.88
    static let mostElbows = 5
    /// How far apart a bough's curve's points are through an elbow, in tree units.
    static let elbowStep = 0.012

    /// A bough's centreline, from its foot, a point every `boughStep` of its length: it leaves at
    /// `heading` and straightens toward its tip, giving up `straighten` of its lean (by default, down to
    /// about a third of it), and bends its own way (`bend`). A bough leaning well out never bends down
    /// further than its planting leans (or level, if that's higher), so an elbow heading down can't
    /// take it nearer the ground than its planting already has it, nor up past straight up.
    static func bough(heading: Double, length: Double, straighten: Double = boughStraighten, bend: Bend = .none) -> [CGPoint] {
        var points = [CGPoint.zero]
        var point = CGPoint.zero
        let count = Int(ceil((length + 0.05) / boughStep))
        let side: Double = heading < 0 ? -1 : 1, lowest = max(abs(heading), .pi / 2), leaning = abs(heading) > leaningOut
        for i in 1...max(count, 1) {
            let t = min(Double(i) / max(length / boughStep, 1), 1)
            var h = heading * (1 - straighten * t) + bend.turn(at: t)
            if leaning { h = side * min(max(side * h, 0), lowest) }
            point = CGPoint(x: point.x + sin(h) * boughStep, y: point.y + cos(h) * boughStep)
            points.append(point)
        }
        return points
    }

    static let boughStep = 0.005
    /// A bough leaning out further than this (radians) is kept between straight up and its lowest (`bough`).
    static let leaningOut = 0.5
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

// MARK: - Carrying on

extension TreeLayout {
    /// A limb leaving a stem (`Stem.carries`): the stem's node it leaves from, and its base's width.
    public struct Carry: Sendable, Equatable {
        public let node: Int
        public let width: Double
    }

    /// What leaves each stem of `tree`, and how wide (`Stem.carries`): the trunk's under -1, a limb's under
    /// its index. `count` is the trunk's commits.
    static func carries(_ tree: RepoTree, weights: [Double], count: Int) -> [Int: [Carry]] {
        var carries: [Int: [Carry]] = [:]
        for (index, limb) in tree.limbs.enumerated() {
            let width = Self.width(weight: Self.remainingWeight(limb, index: index, tree: tree, weights: weights, beyond: 0))
            switch limb.parent {
            case .trunk(let node): carries[-1, default: []].append(Carry(node: min(node, count), width: width))
            case .limb(let parent, let node): carries[parent, default: []].append(Carry(node: node, width: width))
            }
        }
        return carries
    }

    /// How a stem narrows to a point at its end. The layout's widths (the pipe model) never get below
    /// a floor at the last node, which drawn as is leaves a flat cut, so the drawing multiplies a
    /// stem's width by `factor` over its last `length`: from 1 where the taper starts (easing in, so
    /// there's no corner there) to a fine point at the very end.
    public struct TipTaper: Sendable, Equatable {
        /// How far from the end the taper starts, in tree units.
        public let length: Double
        /// Where a limb leaves within it (its distance from the end), and the factor that keeps the stem as
        /// wide as that limb's base there (`Stem.carries`).
        public let holds: [Hold]

        // swiftlint:disable:next nesting - a hold is the taper's alone, nowhere else to put it
        public struct Hold: Sendable, Equatable {
            public let distance: Double
            public let factor: Double
        }

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
        ///   - holds: where limbs leave it, as distances from its end, and their bases' widths.
        public init(stemLength: Double, holds: [(distance: Double, width: Double)] = [], widthAt: (Double) -> Double) {
            var length = Self.reach * widthAt(0)
            for _ in 0..<2 { length = Self.reach * widthAt(min(length, stemLength)) }
            self.length = max(min(length, Self.share * stemLength), 0)
            self.holds = holds.map { Hold(distance: $0.distance, factor: min($0.width / max(widthAt($0.distance), 1e-12), 1)) }
        }

        /// The width's multiplier `distance` from the end (0 at the end; 1 from `length` on). Where a limb
        /// leaves, it's no narrower than that limb's base, and past it narrows from there to the end in
        /// the same way: one leaving at the very end leaves the stem ending as wide as it.
        public func factor(distanceToTip distance: Double) -> Double {
            holds.reduce(tapered(distance)) { factor, hold in
                guard distance < hold.distance else { return max(factor, hold.factor) }
                return max(factor, hold.factor * (Self.point + (1 - Self.point) * sin(distance / hold.distance * .pi / 2)))
            }
        }

        private func tapered(_ distance: Double) -> Double {
            guard length > 0, distance < length else { return 1 }
            let s = max(distance / length, 0)
            return Self.point + (1 - Self.point) * sin(s * .pi / 2)
        }
    }
}
