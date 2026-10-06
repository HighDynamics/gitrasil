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
    }

    /// Where a stem leaves its parent: what its base flares into (`collarWidth`).
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

        public init(foot: CGPoint = .zero, heading: Double = 0, outward: Double = 0, fork: Fork? = nil) {
            self.foot = foot
            self.heading = heading
            self.outward = outward
            self.fork = fork
        }

        public static let upright = Planting()

        var isUpright: Bool { self == .upright }
    }

    /// The trunk first, then every limb after its parent.
    public let stems: [Stem]
    /// Every node's extent, widths included.
    public let bounds: CGRect

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
    /// Limbs off limbs are drawn this much smaller than their parent.
    static let childScale = 0.72
    /// A trunk commit's share of the trunk's weight, against a limb commit's 1.
    static let trunkCommitWeight = 0.35

    /// - Parameters:
    ///   - seed: the repository's identity (its name): seeds the trunk's sway.
    ///   - grown: commits grown in so far, by stem name (`RepoTree.commitCounts` keys), for a stem
    ///     that's growing; a stem not in it is fully grown.
    ///   - planting: where the trunk stands and which way it leans (upright at the origin by default).
    public init(tree: RepoTree, seed: String, grown: [String: Double] = [:], planting: Planting = .upright) {
        var stems: [Stem] = []
        let weights = Self.weights(tree)

        // The trunk: a gentle seeded sway, its commits spaced on a log scale from the tip down.
        let count = tree.trunk.count
        let height = Self.trunkHeight(commits: count)
        var rng = SeededRandom(seed, -1)
        let sway = (amplitude: rng.next(in: 0.015...0.04), waves: rng.next(in: 0.6...1.3),
                    phase: rng.next(in: 0...(2 * .pi)), lean: rng.next(in: -0.07...0.07))
        // A leaning trunk (a bough) is walked out along its length, straightening as it rises.
        let arc = planting.isUpright ? [] : Self.bough(heading: planting.heading, length: height)
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
        var trunkCurve: [Node] = []
        for (index, (a, b)) in zip(trunkNodes, trunkNodes.dropFirst()).enumerated() {
            let from = trunkHeights[index], to = trunkHeights[index + 1]
            let pieces = max(1, Int(ceil((to - from) / 0.03)))
            for piece in 0..<pieces {
                let t = Double(piece) / Double(pieces)
                let p = trunkPoint(from + (to - from) * t)
                trunkCurve.append(Node(point: p, width: a.width + (b.width - a.width) * t, heading: a.heading))
            }
        }
        trunkCurve += trunkNodes.suffix(1)
        let trunkName = tree.trunkName ?? ""
        stems.append(Stem(name: tree.trunkName, level: 0, nodes: trunkNodes, curve: trunkCurve, commits: tree.trunk,
                          grown: grown[trunkName] ?? Double(count), isBud: false,
                          isCheckedOut: tree.isTrunkCheckedOut, scale: 1, fork: planting.fork))

        // The limbs, each grown from its parent's node.
        var limbStems: [Stem?] = []
        var stemIndex: [Int: Int] = [:]
        let sides = Self.sides(tree, outward: planting.outward)
        for (index, limb) in tree.limbs.enumerated() {
            let base: Node, level: Int, scale: Double, lean: Double, parentGrown: Double, fork: Fork
            var rng = SeededRandom(limb.name)
            let side = sides[index]
            switch limb.parent {
            case .trunk(let node):
                base = trunkNodes[min(node, trunkNodes.count - 1)]
                let u = node == 0 ? 0 : Self.trunkPosition(node - 1, of: count)
                level = 1
                // Low limbs reach out nearly level and long; high ones rise steeply and stay short.
                scale = 1.05 - 0.45 * u
                lean = side * ((88 - 48 * u) + rng.next(in: -12...12)) * .pi / 180
                    + (planting.isUpright ? 0 : base.heading * 0.7)
                parentGrown = .infinity
                fork = Fork(parent: 0, node: min(node, trunkNodes.count - 1), width: base.width, heading: base.heading)
            case .limb(let parentIndex, let node):
                guard let parent = limbStems[parentIndex], !parent.nodes.isEmpty else { limbStems.append(nil); continue }
                base = parent.nodes[min(node, parent.nodes.count - 1)]
                level = parent.level + 1
                scale = parent.scale * Self.childScale
                // Mostly outward, away from the trunk, like a real crown; sometimes back in.
                var pick = SeededRandom(limb.name, -2)
                let outward: Double = base.heading >= 0 ? 1 : -1
                let childSide = pick.next() < 0.7 ? outward : -outward
                lean = base.heading + childSide * rng.next(in: 28...50) * .pi / 180
                parentGrown = parent.grown >= Double(node) ? .infinity : 0
                fork = Fork(parent: stemIndex[parentIndex], node: min(node, parent.nodes.count - 1),
                            width: base.width, heading: base.heading)
            }
            let full = Double(max(limb.commits.count, 1))
            let shown = min(full, grown[limb.name] ?? full, parentGrown)
            let (nodes, curve) = Self.grow(limb, from: base, lean: lean, scale: scale, shown: shown,
                                           weight: { k in Self.remainingWeight(limb, index: index, tree: tree, weights: weights, beyond: k) })
            let stem = Stem(name: limb.name, level: level, nodes: nodes, curve: curve, commits: limb.commits, grown: shown,
                            isBud: limb.isBud, isCheckedOut: limb.isCheckedOut, scale: scale, fork: fork)
            stemIndex[index] = stems.count
            limbStems.append(stem)
            stems.append(stem)
        }

        self.stems = stems
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
    static func sides(_ tree: RepoTree, outward: Double = 0) -> [Double] {
        var sides = tree.limbs.map { limb -> Double in
            var rng = SeededRandom(limb.name)
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
                     weight: (Int) -> Double) -> (nodes: [Node], curve: [Node]) {
        let steps = Int(ceil(shown))
        guard steps > 0 else { return ([], []) }
        var nodes = [Node(point: base.point, width: min(base.width, width(weight: weight(0))), heading: lean)]
        var curve = nodes
        var heading = lean
        var point = base.point
        var length = (limb.isBud ? 0.35 : 1) * firstStep * scale
        let bendPerSubstep = 1 - pow(1 - tropism, 1 / Double(substeps))
        for k in 1...steps {
            var rng = SeededRandom(limb.name, k)
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

    static let collarFlare = 2.0
    static let collarLength = 2.4

    /// Sub-steps per commit step in a limb's curve.
    static let substeps = 4

    /// A bough's centreline, from its foot, a point every `boughStep` of its length: it leaves at
    /// `heading` and straightens toward its tip, to about a third of its lean.
    static func bough(heading: Double, length: Double) -> [CGPoint] {
        var points = [CGPoint.zero]
        var point = CGPoint.zero
        let count = Int(ceil((length + 0.05) / boughStep))
        for i in 1...max(count, 1) {
            let t = min(Double(i) / max(length / boughStep, 1), 1)
            let h = heading * (1 - 0.65 * t)
            point = CGPoint(x: point.x + sin(h) * boughStep, y: point.y + cos(h) * boughStep)
            points.append(point)
        }
        return points
    }

    static let boughStep = 0.005

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
