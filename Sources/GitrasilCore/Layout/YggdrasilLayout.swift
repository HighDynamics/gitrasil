import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Several repositories grown as one tree: a shared trunk rising from the ground to a crotch, and
/// from there a bough per repository, fanned left to right in pin order. Each bough is that
/// repository's own tree (`TreeLayout`) planted leaning out of the crotch: its trunk (the default
/// branch) is the bough, and its branches grow off it as they would off a tree of its own. Same units
/// as `TreeLayout`: y up, the shared trunk's foot at the origin.
///
/// A bough's place and lean come from how many boughs there are, its position among them and its
/// name, never from another repository's history, so a commit in one repository only grows its own
/// bough (and thickens the shared trunk a hair).
public struct YggdrasilLayout: Sendable {

    public struct Repo: Sendable {
        public let name: String
        public let tree: RepoTree
        /// Commits grown in so far, as `TreeLayout` takes them.
        public let grown: [String: Double]
        /// While the bough grows in from the crotch, how far along it is (as `TreeLayout` takes it).
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
        /// Its tree, planted in the crotch; its first stem is the bough.
        public let layout: TreeLayout
        public let planting: TreeLayout.Planting
    }

    /// The shared trunk, from the ground to the crotch. It has no commits of its own.
    public let trunk: TreeLayout.Stem
    public let boughs: [Bough]
    /// Every node's extent, widths included.
    public let bounds: CGRect

    /// How high the boughs leave the shared trunk.
    public static let crotchHeight = 0.34

    /// How boughs fan out of the crotch. `standard` is the single tree as it has always been; a crowded
    /// tree opens its fan and stands the boughs' feet apart down the trunk's head, always inside its wood.
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

    /// - Parameters:
    ///   - trunkGrowIn: while the shared trunk rises from the ground, how far along it is (0…1); its
    ///     boughs wait for it (their own `growIn`).
    ///   - shuffle: a layout seed mixed into the shared trunk's sway, each bough's place and lean, and
    ///     its tree (`TreeLayout`'s `shuffle`); 0 for the shape the names alone give.
    public init(repos: [Repo], trunkGrowIn: Double? = nil, shuffle: Int = 0, fit: Fit = .standard) {
        // The shared trunk carries all of them: the pipe model again, width² adds up.
        let carried = sqrt(repos.reduce(0) { $0 + pow(TreeLayout.footWidth($1.tree), 2) })
        var rng = SeededRandom(SeededRandom.key("yggdrasil", shuffle: shuffle), -1)
        let lean = rng.next(in: -0.03...0.03), phase = rng.next(in: 0...(2 * .pi))
        func trunkPoint(_ h: Double) -> CGPoint {
            let t = h / Self.crotchHeight
            return CGPoint(x: 0.012 * sin(t * .pi * 1.4 + phase) * t + lean * t * t, y: h)
        }
        let count = 14
        let nodes = (0...count).map { k -> TreeLayout.Node in
            let h = Self.crotchHeight * Double(k) / Double(count)
            let p = trunkPoint(h), q = trunkPoint(h + 0.01)
            let width = carried * (1.3 - 0.3 * Double(k) / Double(count)) + 0.004
            return TreeLayout.Node(point: p, width: width, heading: atan2(q.x - p.x, q.y - p.y))
        }
        let shown = trunkGrowIn.map { progress in
            TreeLayout.cut(nodes, heights: nodes.map { Double($0.point.y) }, at: Self.crotchHeight * min(max(progress, 0), 1))
        } ?? nodes
        trunk = TreeLayout.Stem(name: nil, level: 0, nodes: shown, curve: shown, commits: [], grown: 0,
                                isBud: false, isCheckedOut: false, scale: 1, fork: nil)

        boughs = repos.enumerated().map { index, repo in
            let planting = Self.planting(index: index, of: repos.count, name: SeededRandom.key(repo.name, shuffle: shuffle),
                                         trunk: nodes, fit: fit)
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

    /// How much of the shared trunk's width, either side of its middle, a foot may stand in: a bough
    /// that starts there still has wood all round its base.
    static let footRoom = 0.35

    /// How far down the trunk below the crotch the outermost foot stands, in a fully spread fit.
    static let footDrop = 0.16

    /// The shared trunk's middle, width and heading at height `y` (interpolated between its nodes).
    static func wood(at y: Double, in trunk: [TreeLayout.Node]) -> (x: Double, width: Double, heading: Double) {
        guard let last = trunk.last, let first = trunk.first else { return (0, 0, 0) }
        let y = min(max(y, first.point.y), last.point.y)
        let i = trunk.indices.dropFirst().first { trunk[$0].point.y >= y } ?? trunk.count - 1
        let a = trunk[i - 1], b = trunk[i]
        let f = (y - a.point.y) / max(b.point.y - a.point.y, 1e-9)
        return (a.point.x + (b.point.x - a.point.x) * f, a.width + (b.width - a.width) * f, a.heading + (b.heading - a.heading) * f)
    }

    /// Bough `index` of `count`: fanned evenly, the outer ones leaning furthest, nudged a little by
    /// its name so the fan isn't ruled. Its foot stands inside the shared `trunk`'s wood, sunk a little
    /// into its top, a touch toward its side and a seeded hair higher or lower, so the boughs grow out
    /// of the wood rather than sitting on it, and don't all spring from one point. A crowded tree
    /// (`Fit.footSpread`) stands the feet down the head of the trunk instead, the outer boughs lowest
    /// and furthest to their side, each still inside the trunk's width at its height.
    static func planting(index: Int, of count: Int, name: String, trunk: [TreeLayout.Node],
                         fit: Fit = .standard) -> TreeLayout.Planting {
        var rng = SeededRandom(name, -5)
        let crotch = trunk[trunk.count - 1]
        let spread = count > 1 ? Double(index) / Double(count - 1) * 2 - 1 : 0
        let fan = min(fit.base + fit.perBough * Double(count), fit.cap) * .pi / 180
        let heading = spread * fan + rng.next(in: -3...3) * .pi / 180
        let spreadOut = min(max(fit.footSpread, 0), 1)
        let y = crotch.point.y - 0.03 - footDrop * spreadOut * abs(spread) + rng.next(in: -0.012...0.012)
        let wood = wood(at: y, in: trunk)
        let reach = (1 - spreadOut) * sin(heading) * 0.012 + spreadOut * spread * footRoom * wood.width
        let limit = footRoom * wood.width
        let foot = CGPoint(x: wood.x + min(max(reach, -limit), limit), y: y)
        let outward: Double = abs(spread) < 0.2 ? 0 : (spread < 0 ? -1 : 1)
        let fork = TreeLayout.Fork(parent: nil, node: trunk.lastIndex { $0.point.y <= y } ?? 0, width: wood.width, heading: wood.heading)
        return TreeLayout.Planting(foot: foot, heading: heading, outward: outward, fork: fork)
    }
}
