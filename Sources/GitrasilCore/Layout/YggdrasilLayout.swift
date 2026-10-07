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

    /// - Parameters:
    ///   - trunkGrowIn: while the shared trunk rises from the ground, how far along it is (0…1); its
    ///     boughs wait for it (their own `growIn`).
    ///   - shuffle: a layout seed mixed into the shared trunk's sway, each bough's place and lean, and
    ///     its tree (`TreeLayout`'s `shuffle`); 0 for the shape the names alone give.
    public init(repos: [Repo], trunkGrowIn: Double? = nil, shuffle: Int = 0) {
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

        let crotch = nodes[count].point
        boughs = repos.enumerated().map { index, repo in
            var planting = Self.planting(index: index, of: repos.count, name: SeededRandom.key(repo.name, shuffle: shuffle),
                                         crotch: crotch)
            planting.fork = TreeLayout.Fork(parent: nil, node: count, width: nodes[count].width, heading: nodes[count].heading)
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

    /// Bough `index` of `count`: fanned evenly, the outer ones leaning furthest, nudged a little by
    /// its name so the fan isn't ruled. Its foot is sunk a little into the top of the shared trunk,
    /// a touch toward its side and a seeded hair higher or lower, so the boughs grow out of the wood
    /// rather than sitting on it, and don't all spring from one point.
    static func planting(index: Int, of count: Int, name: String, crotch: CGPoint) -> TreeLayout.Planting {
        var rng = SeededRandom(name, -5)
        let spread = count > 1 ? Double(index) / Double(count - 1) * 2 - 1 : 0
        let fan = min(16 + 12 * Double(count), 52) * .pi / 180
        let heading = spread * fan + rng.next(in: -3...3) * .pi / 180
        let foot = CGPoint(x: crotch.x + sin(heading) * 0.012, y: crotch.y - 0.03 + rng.next(in: -0.012...0.012))
        let outward: Double = abs(spread) < 0.2 ? 0 : (spread < 0 ? -1 : 1)
        return TreeLayout.Planting(foot: foot, heading: heading, outward: outward)
    }
}
