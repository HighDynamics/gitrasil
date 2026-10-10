import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Several repositories grown as one tree: a shared trunk rising from the ground, and a bough per
/// repository. A few fan up out of the trunk's top, a small crown; the rest are tiers up the trunk,
/// alternately left and right, reaching out nearly level, so a tree of many repositories is a tall trunk
/// with its boughs laid out across the screen (`Shape`). Each bough is that repository's own tree
/// (`TreeLayout`) planted leaning out of the trunk: its trunk (the default branch) is the bough, and its
/// branches grow off it as they would off a tree of its own. Same units as `TreeLayout`: y up, the shared
/// trunk's foot at the origin.
///
/// A bough's place and lean come from how many boughs there are, its position among them and its
/// name, never from another repository's history, so a commit in one repository only grows its own
/// bough (and thickens the shared trunk a hair below it).
public struct YggdrasilLayout: Sendable {

    public struct Repo: Sendable {
        public let name: String
        public let tree: RepoTree
        /// Commits grown in so far, as `TreeLayout` takes them.
        public let grown: [String: Double]
        /// While the bough grows in from the trunk, how far along it is (as `TreeLayout` takes it).
        public let growIn: Double?

        public init(name: String, tree: RepoTree, grown: [String: Double] = [:], growIn: Double? = nil) {
            self.name = name
            self.tree = tree
            self.grown = grown
            self.growIn = growIn
        }
    }

    public struct Bough: Sendable {
        /// The repository's name.
        public let name: String
        /// Its tree, planted in the shared trunk; its first stem is the bough.
        public let layout: TreeLayout
        public let planting: TreeLayout.Planting
    }

    /// The shared trunk, from the ground to its top. It has no commits of its own.
    public let trunk: TreeLayout.Stem
    public let boughs: [Bough]
    /// Every node's extent, widths included.
    public let bounds: CGRect

    /// How tall the shared trunk stands with no tiers (up to four boughs, all in the crown).
    public static let crotchHeight = 0.34

    /// How the crown's boughs fan out of the trunk's top. `standard` is the single tree as it has always
    /// been; a crowded crown opens its fan and stands the boughs' feet apart down the trunk's head, always
    /// inside its wood.
    public struct Fit: Sendable, Equatable {
        /// The fan's half-angle for `count` boughs: `base + perBough * count`, at most `cap` degrees.
        public var base: Double, perBough: Double, cap: Double
        /// How far the feet leave the crotch for the trunk's head, 0…1: 0 stands them all at the crotch;
        /// 1 spreads them over the wood below it (`planting`), the outer boughs lowest and furthest out.
        public var footSpread: Double
        /// How far along a bough (0…1) a ribbon may hang from; a crowded tree reaches further out.
        public var ribbonStops: [Double]
        /// A ribbon's size by the number of boughs: full up to `ribbonCrowd`, then smaller (never under `ribbonFloor`).
        public var ribbonCrowd: Int, ribbonFloor: Double

        public init(base: Double = 16, perBough: Double = 12, cap: Double = 52, footSpread: Double = 0,
                    ribbonStops: [Double] = [0.14, 0.2, 0.26, 0.32, 0.4, 0.48, 0.56], ribbonCrowd: Int = .max,
                    ribbonFloor: Double = 1) {
            self.base = base
            self.perBough = perBough
            self.cap = cap
            self.footSpread = footSpread
            self.ribbonStops = ribbonStops
            self.ribbonCrowd = ribbonCrowd
            self.ribbonFloor = ribbonFloor
        }

        /// How large ribbons are drawn among `count` boughs, as a fraction of their full size.
        public func ribbonScale(count: Int) -> Double {
            guard count > ribbonCrowd else { return 1 }
            return max((Double(ribbonCrowd) / Double(count)).squareRoot(), ribbonFloor)
        }

        public static let standard = Fit()
        public static let wide = Fit(base: 20, perBough: 8, cap: 74, footSpread: 1,
                                     ribbonStops: [0.14, 0.2, 0.26, 0.32, 0.4, 0.48, 0.56, 0.66, 0.76, 0.86],
                                     ribbonCrowd: 6, ribbonFloor: 0.62)

        /// The fit for `count` boughs: the standard fan up to `standardUpTo` of them, the wide one from
        /// `wideFrom`, blended between. It depends on the count only, so the tree stays as it is until a
        /// repository is added or dropped.
        public static func fitting(count: Int, standardUpTo: Int = 4, wideFrom: Int = 8) -> Fit {
            let t = min(max(Double(count - standardUpTo) / Double(max(wideFrom - standardUpTo, 1)), 0), 1)
            guard t > 0 else { return .standard }
            guard t < 1 else { return .wide }
            func blend(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
            let (a, b) = (standard, wide)
            return Fit(base: blend(a.base, b.base), perBough: blend(a.perBough, b.perBough), cap: blend(a.cap, b.cap),
                       footSpread: blend(a.footSpread, b.footSpread),
                       ribbonStops: count >= 6 ? b.ribbonStops : a.ribbonStops, ribbonCrowd: count >= 6 ? b.ribbonCrowd : a.ribbonCrowd,
                       ribbonFloor: blend(a.ribbonFloor, b.ribbonFloor))
        }
    }

    /// How the boughs are shared out: the last `crown` of them fan up out of the trunk's top, as the single
    /// tree always has; the rest are tiers, leaving the trunk at heights up its length, alternately left and
    /// right from the bottom, and reaching out nearly level. The trunk grows taller with every tier.
    public struct Shape: Sendable, Equatable {
        public let count: Int
        /// How many boughs fan out of the top.
        public let crown: Int
        /// How tall the shared trunk stands, to its top (the crown's crotch).
        public let trunkHeight: Double

        /// How many boughs leave the trunk below the crown.
        public var tiers: Int { count - crown }

        public init(count: Int) {
            self.count = count
            // Up to four (`Fit.standard`), it's the tree as it was: a short trunk and a fan. Then a crown of
            // two to six.
            crown = count <= Self.fanUpTo ? count : min(2 + count / 6, 6)
            trunkHeight = YggdrasilLayout.crotchHeight + Self.tierRise * Double(min(count - crown, Self.tallestAt))
        }

        /// The most boughs that are all crown, the single tree as it always was.
        static let fanUpTo = 4
        /// How much taller the trunk grows for each tier, up to `tallestAt` tiers.
        static let tierRise = 0.042
        static let tallestAt = 26
        /// The lowest and highest tier, as fractions of the trunk's height.
        static let lowestTier = 0.36, highestTier = 0.86

        /// Where tier `index` (0 at the bottom) leaves the trunk, as a fraction of its height.
        func tierPosition(_ index: Int) -> Double {
            guard tiers > 1 else { return (Self.lowestTier + Self.highestTier) / 2 }
            return Self.lowestTier + (Self.highestTier - Self.lowestTier) * Double(index) / Double(tiers - 1)
        }

        /// The side tier `index` reaches out to: -1 left, 1 right, alternating from the bottom.
        func tierSide(_ index: Int) -> Double { index % 2 == 0 ? -1 : 1 }
    }

    /// - Parameters:
    ///   - trunkGrowIn: while the shared trunk rises from the ground, how far along it is (0…1); its
    ///     boughs wait for it (their own `growIn`).
    ///   - shuffle: a layout seed mixed into the shared trunk's sway, each bough's place and lean, and
    ///     its tree (`TreeLayout`'s `shuffle`); 0 for the shape the names alone give.
    public init(repos: [Repo], trunkGrowIn: Double? = nil, shuffle: Int = 0, fit: Fit = .standard) {
        let shape = Shape(count: repos.count)
        let height = shape.trunkHeight
        let names = repos.map { SeededRandom.key($0.name, shuffle: shuffle) }
        let feet = repos.map { TreeLayout.footWidth($0.tree) }
        let heights = repos.indices.map { Self.footHeight(index: $0, shape: shape, name: names[$0], fit: fit) }
        // The pipe model again (width² adds up): the trunk carries every bough leaving above it, and a
        // tier's wood a little past its foot, so it tapers from the ground to the crown. The crown's
        // boughs it carries to the top.
        let carriedTo = repos.indices.map { $0 < shape.tiers ? heights[$0] + Self.carriedPast : .infinity }
        var rng = SeededRandom(SeededRandom.key("yggdrasil", shuffle: shuffle), -1)
        let lean = rng.next(in: -0.03...0.03), phase = rng.next(in: 0...(2 * .pi))
        func trunkPoint(_ h: Double) -> CGPoint {
            let t = h / height
            return CGPoint(x: 0.012 * sin(t * .pi * 1.4 + phase) * t + lean * t * t, y: h)
        }
        let count = max(14, Int((height / Self.trunkStep).rounded(.up)))
        let nodes = (0...count).map { k -> TreeLayout.Node in
            let h = height * Double(k) / Double(count)
            let p = trunkPoint(h), q = trunkPoint(h + 0.01)
            let carried = sqrt(repos.indices.reduce(0) { $0 + (h <= carriedTo[$1] ? feet[$1] * feet[$1] : 0) })
            let width = carried * (1 + 0.3 * (1 - Double(k) / Double(count))) + 0.004
            return TreeLayout.Node(point: p, width: width, heading: atan2(q.x - p.x, q.y - p.y))
        }
        let shown = trunkGrowIn.map { progress in
            TreeLayout.cut(nodes, heights: nodes.map { Double($0.point.y) }, at: height * min(max(progress, 0), 1))
        } ?? nodes
        trunk = TreeLayout.Stem(name: nil, level: 0, nodes: shown, curve: shown, commits: [], grown: 0,
                                isBud: false, isCheckedOut: false, scale: 1, fork: nil)

        boughs = repos.enumerated().map { index, repo in
            let planting = Self.planting(index: index, shape: shape, name: names[index], width: feet[index],
                                         at: heights[index], trunk: nodes, fit: fit)
            return Bough(name: repo.name,
                         layout: TreeLayout(tree: repo.tree, seed: repo.name, grown: repo.grown, planting: planting,
                                            growIn: repo.growIn, shuffle: shuffle),
                         planting: planting)
        }

        var bounds = CGRect.null
        for node in nodes {
            bounds = bounds.union(CGRect(x: node.point.x - node.width / 2, y: node.point.y, width: node.width, height: 0))
        }
        for bough in boughs { bounds = bounds.union(bough.layout.bounds) }
        self.bounds = bounds
    }

    /// A trunk node at least every this far up it.
    static let trunkStep = 0.025

    /// How far past its foot the trunk still carries a tier's wood: more than `trunkStep`, so both nodes
    /// around the foot are wide enough for the bough's whole base.
    static let carriedPast = 0.04

    /// How much of the shared trunk's width, either side of its middle, a foot may stand in: a bough
    /// that starts there still has wood all round its base.
    static let footRoom = 0.35

    /// How far down the trunk below the crotch the outermost crown foot stands, in a fully spread fit.
    static let footDrop = 0.16

    /// How far a tier reaches, as a multiple of its tree's own size: further than a crown bough, so the
    /// tiers lay the boughs out across the screen.
    static let tierReach = 1.55

    /// How far a crown bough reaches over tiers, as a multiple of its tree's own size.
    static let crownReach = 0.8

    /// The shared trunk's middle, width and heading at height `y` (interpolated between its nodes).
    static func wood(at y: Double, in trunk: [TreeLayout.Node]) -> (x: Double, width: Double, heading: Double) {
        guard let last = trunk.last, let first = trunk.first else { return (0, 0, 0) }
        let y = min(max(y, first.point.y), last.point.y)
        let i = trunk.indices.dropFirst().first { trunk[$0].point.y >= y } ?? trunk.count - 1
        let a = trunk[i - 1], b = trunk[i]
        let f = (y - a.point.y) / max(b.point.y - a.point.y, 1e-9)
        return (a.point.x + (b.point.x - a.point.x) * f, a.width + (b.width - a.width) * f, a.heading + (b.heading - a.heading) * f)
    }

    /// A crown bough's place in its fan, -1 (left) … 1 (right).
    static func crownSpread(_ index: Int, of count: Int) -> Double {
        count > 1 ? Double(index) / Double(count - 1) * 2 - 1 : 0
    }

    /// How high bough `index` leaves the trunk, a seeded hair higher or lower: a tier at its place up the
    /// trunk; a crown bough sunk a little into the top, or (`Fit.footSpread`) further down its head the
    /// further out it fans.
    static func footHeight(index: Int, shape: Shape, name: String, fit: Fit) -> Double {
        // The same draws as the crown bough's nudge (`planting`) then this, as the single tree always had.
        var rng = SeededRandom(name, -5)
        _ = rng.next(in: -3...3)
        let jitter = rng.next(in: -0.012...0.012)
        guard index >= shape.tiers else { return shape.trunkHeight * shape.tierPosition(index) + jitter }
        let spread = crownSpread(index - shape.tiers, of: shape.crown)
        return shape.trunkHeight - 0.03 - footDrop * min(max(fit.footSpread, 0), 1) * abs(spread) + jitter
    }

    /// Bough `index`, leaving the trunk at height `y`. Its foot stands inside the shared `trunk`'s wood
    /// there, toward its own side, so the bough grows out of the wood rather than sitting on it; `width` is
    /// its own base width (`TreeLayout.footWidth`): it must fit, not only its middle.
    ///
    /// A crown bough fans out of the top as the single tree always has: evenly, the outer ones leaning
    /// furthest, nudged a little by its name so the fan isn't ruled. A tier leans out nearly level to its
    /// side, a seeded touch up or down, keeps most of that lean (`Planting.straighten`) and reaches further
    /// than its tree would on its own (`Planting.reach`), the lower tiers furthest; its limbs splay off it
    /// (`Planting.splay`), favouring its upper side.
    static func planting(index: Int, shape: Shape, name: String, width: Double, at y: Double,
                         trunk: [TreeLayout.Node], fit: Fit = .standard) -> TreeLayout.Planting {
        var rng = SeededRandom(name, -6)
        let wood = wood(at: y, in: trunk)
        // Its whole base, `width` across, stays inside the trunk: a big repository stands nearer the middle.
        let limit = min(footRoom * wood.width, max(wood.width - width, 0) / 2)
        let fork = TreeLayout.Fork(parent: nil, node: trunk.lastIndex { $0.point.y <= y } ?? 0, width: wood.width, heading: wood.heading)
        guard index >= shape.tiers else {
            let side = shape.tierSide(index), u = shape.tierPosition(index)
            let heading = side * rng.next(in: 78...94) * .pi / 180
            let reach = tierReach * (1.15 - 0.3 * u) * rng.next(in: 0.85...1.15)
            return TreeLayout.Planting(foot: CGPoint(x: wood.x + side * limit, y: y), heading: heading, outward: -side,
                                       fork: fork, straighten: rng.next(in: -0.04...0.2), reach: reach, splay: true)
        }
        let spread = crownSpread(index - shape.tiers, of: shape.crown)
        let fan = min(fit.base + fit.perBough * Double(shape.crown), fit.cap) * .pi / 180
        var nudge = SeededRandom(name, -5)
        let heading = spread * fan + nudge.next(in: -3...3) * .pi / 180
        let spreadOut = min(max(fit.footSpread, 0), 1)
        let along = (1 - spreadOut) * sin(heading) * 0.012 + spreadOut * spread * footRoom * wood.width
        let foot = CGPoint(x: wood.x + min(max(along, -limit), limit), y: y)
        let outward: Double = abs(spread) < 0.2 ? 0 : (spread < 0 ? -1 : 1)
        // Over tiers, the crown is a small one.
        return TreeLayout.Planting(foot: foot, heading: heading, outward: outward, fork: fork,
                                   reach: shape.tiers > 0 ? crownReach : 1)
    }
}
