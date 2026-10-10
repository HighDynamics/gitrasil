import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// How a crowd of trees is spread over the screen (docs/forest/PLAN.md).
public enum ForestMode: String, CaseIterable, Sendable {
    /// The policy decides (`ForestPolicy`): a plain orchard up to its limit, depth rows beyond it, and
    /// in the single tree the repositories that don't fit on it behind it.
    case auto
    /// The orchard as it was: a plot of equal width per tree on one ground line, with the pane cap lifted.
    case off
    /// Depth rows always, even for a handful of trees.
    case rows

    /// Whether `ForestLayout` places a crowd of `count` trees (the other case is the orchard's equal plots).
    public func packs(_ count: Int, policy: ForestPolicy = .standard) -> Bool {
        switch self {
        case .off: return false
        case .rows: return true
        case .auto: return count > policy.plainLimit
        }
    }
}

/// One tree as the forest layout sees it: its crown in tree units (the trunk's foot is the origin,
/// the full-grown trunk 1 tall) and what says how it ranks.
public struct ForestTree: Sendable, Equatable {
    public var id: String
    /// The folder it sits in: trees of one folder stand together within a line.
    public var group: String
    /// The crown's extent left and right of the trunk's foot, and its height, in tree units.
    public var left: Double
    public var right: Double
    public var height: Double
    /// When its newest commit was made (as of the last time the ranking was taken: `ForestPolicy.rank`).
    public var lastActive: Date

    public init(id: String, group: String, left: Double, right: Double, height: Double, lastActive: Date) {
        self.id = id
        self.group = group
        self.left = left
        self.right = right
        self.height = height
        self.lastActive = lastActive
    }
}

/// The screen a forest is laid on, in points.
public struct ForestScreen: Sendable, Equatable {
    public var size: CGSize
    /// The front ground line's y, and the top of the room for crowns.
    public var groundY: CGFloat
    public var top: CGFloat
    /// Kept clear at the sides and above the tallest crown.
    public var margin: CGFloat
    /// A full-grown tree's height in tree units, crown included.
    public var nominalHeight: Double
    /// How much of the height from the ground to the top the forest may fill: 1 for all of it, less
    /// to leave sky (behind a single tree, to stay under its crown).
    public var heightShare: CGFloat
    /// Width kept clear in the middle, for the single tree standing in front of the forest.
    public var gap: CGFloat
    /// The least any line fades into the paper: behind a tree even the front line stands back.
    public var minFade: Double

    public init(size: CGSize, groundY: CGFloat, top: CGFloat, margin: CGFloat, nominalHeight: Double,
                heightShare: CGFloat = 1, gap: CGFloat = 0, minFade: Double = 0) {
        self.size = size
        self.groundY = groundY
        self.top = top
        self.margin = margin
        self.nominalHeight = nominalHeight
        self.heightShare = heightShare
        self.gap = gap
        self.minFade = minFade
    }

    /// The height from the ground to the highest a crown may reach.
    var tall: CGFloat { (groundY - top - margin) * heightShare }
    /// The widest a line may run, the gap taken out.
    var available: CGFloat { max(size.width - 2 * margin - gap, 1) }
}

/// Where one tree stands.
public struct ForestPlacement: Sendable, Equatable {
    /// Its index in the trees given.
    public var index: Int
    /// Its trunk's foot and its scale (points per tree unit).
    public var x: CGFloat
    public var ground: CGFloat
    public var scale: CGFloat
    /// 0 for the front line; more for lines further back.
    public var line: Int
    /// How far it fades into the paper, 0 (none) to 1.
    public var fade: Double
    /// The width its name may take: from halfway to its neighbours on the same line.
    public var slot: CGFloat
}

/// A short ground line for a line behind the front one.
public struct ForestGround: Sendable, Equatable {
    public var y: CGFloat
    public var from: CGFloat
    public var to: CGFloat
    public var fade: Double
}

public struct ForestPlan: Sendable, Equatable {
    public var placements: [ForestPlacement] = []
    public var grounds: [ForestGround] = []
    /// The number of lines of trees.
    public var lines = 1
    /// The front line's scale.
    public var scale: CGFloat = 0

    public init() {}
}

public enum ForestLayout {

    /// Room added each side of a crown for its leaves, in tree units; spans are rounded up to
    /// `quantum`, so a tree growing a little doesn't move every other tree.
    static let pad = 0.06
    static let quantum = 0.05

    /// How far a line is scaled and faded for each step back.
    static let depthScale = 0.80
    /// A line's rise over the one in front, in front-line trunk heights.
    static let depthRise = 0.30
    /// How much an adjacent pair of crowns on a line may interleave.
    static let overlap = 0.30

    /// A tree's reach each side of its foot, with room for leaves, rounded up.
    static func span(_ tree: ForestTree) -> (left: Double, right: Double) {
        func up(_ v: Double) -> Double { (v / quantum).rounded(.up) * quantum }
        return (up(max(-tree.left, 0.05) + pad), up(tree.right + pad))
    }

    /// The width a line of trees takes, in tree units at scale 1: first crown's left edge to the
    /// last's right edge, adjacent crowns overlapping by `overlap`.
    static func extent(_ spans: [(left: Double, right: Double)]) -> Double {
        guard !spans.isEmpty else { return 0 }
        var total = spans[0].left
        for i in spans.indices {
            if i + 1 < spans.count {
                total += (spans[i].right + spans[i + 1].left) * (1 - overlap)
            } else {
                total += spans[i].right
            }
        }
        return total
    }

    /// Feet along a line from `start`, at `scale`, with a seeded touch off true so the row isn't ruled.
    static func feet(_ spans: [(left: Double, right: Double)], ids: [String], scale: CGFloat, start: CGFloat) -> [CGFloat] {
        var xs: [CGFloat] = []
        var cursor = start + CGFloat(spans[0].left) * scale
        for i in spans.indices {
            var rng = SeededRandom(ids[i], -21)
            let jitter = CGFloat(rng.next(in: -0.04...0.04))
            xs.append(cursor + jitter * CGFloat(spans[i].left + spans[i].right) * scale)
            if i + 1 < spans.count {
                cursor += CGFloat((spans[i].right + spans[i + 1].left) * (1 - overlap)) * scale
            }
        }
        return xs
    }

    /// From halfway to the neighbours either side (to the screen's edge, at the ends).
    static func slots(_ xs: [CGFloat], screen: ForestScreen) -> [CGFloat] {
        xs.indices.map { i in
            let before = i > 0 ? xs[i] - xs[i - 1] : (xs[i] - screen.margin) * 2
            let after = i + 1 < xs.count ? xs[i + 1] - xs[i] : (screen.size.width - screen.margin - xs[i]) * 2
            return max(min(before, after), 8)
        }
    }

    /// Several ground lines in depth. Each line back is `depthScale` the size of the one in front and
    /// rises `depthRise` front trunk heights above it; the most recently active repositories stand in
    /// front. The number of lines is the fewest that keeps the front line's trees at a comfortable size
    /// (or the most that fit). With a `gap`, each line runs on both sides of it, in one sequence.
    public static func rows(_ trees: [ForestTree], screen: ForestScreen) -> ForestPlan {
        guard !trees.isEmpty else { return ForestPlan() }
        let spans = trees.map(span)
        let tallest = CGFloat(max(trees.map(\.height).max() ?? 1, screen.nominalHeight))
        let ranked = ForestPolicy.rank(trees.map { ($0.id, $0.lastActive) })
        let comfortable = screen.tall / tallest * 0.62
        var best: (scale: CGFloat, lines: [[Int]])?
        for count in 1...6 {
            let lines = distribute(ranked, lines: count)
            let scale = fitRows(lines, trees: trees, spans: spans, screen: screen, tallest: tallest)
            if best == nil || scale > best!.scale * 1.02 { best = (scale, lines) }
            if scale >= comfortable { best = (scale, lines); break }
        }
        guard let (scale, lines) = best else { return ForestPlan() }
        var plan = ForestPlan()
        plan.scale = scale
        plan.lines = lines.count
        let middle = screen.size.width / 2 - screen.gap / 2
        var rise: CGFloat = 0
        for (k, members) in lines.enumerated() {
            let s = scale * CGFloat(pow(depthScale, Double(k)))
            if k > 0 { rise += CGFloat(depthRise) * scale * CGFloat(pow(depthScale, Double(k - 1))) }
            let steps = lines.count > 1 ? min(0.62, 0.62 * Double(k) / Double(lines.count - 1) + 0.04 * Double(min(k, 1))) : 0
            let fade = max(steps, screen.minFade)
            let order = standing(members, trees: trees)
            let ordered = order.map { spans[$0] }
            let used = CGFloat(extent(ordered)) * s
            // Each line starts a little off the one in front, so trunks don't stack.
            let phase = CGFloat(k % 2 == 0 ? 0 : 1) * min(40, s * 0.12)
            var xs = feet(ordered, ids: order.map { trees[$0].id + "\(k)" }, scale: s,
                          start: screen.margin + max((screen.available - used) / 2 + phase / 2, 0))
            // The trees past the middle step over the gap.
            if screen.gap > 0 { xs = xs.map { $0 > middle ? $0 + screen.gap : $0 } }
            let slot = slots(xs, screen: screen)
            let ground = screen.groundY - rise
            if k > 0, let first = xs.first, let last = xs.last {
                let from = max(first - s * 0.4, 0), to = min(last + s * 0.4, screen.size.width)
                if screen.gap > 0, from < middle, to > middle + screen.gap {
                    plan.grounds.append(ForestGround(y: ground, from: from, to: middle, fade: fade))
                    plan.grounds.append(ForestGround(y: ground, from: middle + screen.gap, to: to, fade: fade))
                } else {
                    plan.grounds.append(ForestGround(y: ground, from: from, to: to, fade: fade))
                }
            }
            for (rank, index) in order.enumerated() {
                plan.placements.append(ForestPlacement(index: index, x: xs[rank], ground: ground, scale: s, line: k, fade: fade,
                                                       slot: slot[rank]))
            }
        }
        return plan
    }

    /// A line's trees in standing order: by folder, then name, so a folder's repositories stand together.
    static func standing(_ members: [Int], trees: [ForestTree]) -> [Int] {
        members.sorted { a, b in
            trees[a].group != trees[b].group ? trees[a].group < trees[b].group : trees[a].id < trees[b].id
        }
    }

    /// Shares the ranked trees over `lines` lines, each back line holding proportionally more (its
    /// trees are smaller): in the proportion 1, 1/f, 1/f², … rounded, front lines getting the rest.
    static func distribute(_ ranked: [Int], lines count: Int) -> [[Int]] {
        guard count > 1 else { return [ranked] }
        let weights = (0..<count).map { pow(1 / depthScale, Double($0)) }
        let total = weights.reduce(0, +)
        var sizes = weights.map { Int(($0 / total * Double(ranked.count)).rounded(.down)) }
        var left = ranked.count - sizes.reduce(0, +)
        var k = 0
        while left > 0 { sizes[k % count] += 1; left -= 1; k += 1 }
        var lines: [[Int]] = []
        var cursor = 0
        for size in sizes {
            lines.append(Array(ranked[cursor..<min(cursor + size, ranked.count)]))
            cursor += size
        }
        return lines.filter { !$0.isEmpty }
    }

    /// The front line's scale for these lines: the biggest at which each line fits the screen's width
    /// and the stack of lines fits its height.
    static func fitRows(_ lines: [[Int]], trees: [ForestTree], spans: [(left: Double, right: Double)], screen: ForestScreen,
                        tallest: CGFloat) -> CGFloat {
        var scale = screen.tall / tallest
        var rise = 0.0
        for (k, members) in lines.enumerated() {
            let f = pow(depthScale, Double(k))
            let width = extent(standing(members, trees: trees).map { spans[$0] }) * f
            if width > 0 { scale = min(scale, screen.available / CGFloat(width)) }
            if k > 0 { rise += depthRise * pow(depthScale, Double(k - 1)) }
            // The line's crowns must stay under the top.
            scale = min(scale, screen.tall / CGFloat(rise + Double(tallest) * f))
        }
        return scale
    }

    /// How many of a tree's branch names hang on pennants, from how big the tree is drawn (points per
    /// tree unit) and how far it has faded: nil for all of them, 0 for none. The trunk and the
    /// branches checked out come first, then the most recently active.
    public static func pennantAllowance(scale: CGFloat, fade: Double) -> Int? {
        if fade > 0.3 { return 0 }
        if scale >= 210 { return nil }
        if scale >= 140 { return 3 }
        return 0
    }
}

extension RepoTree {

    /// When its newest commit was made (the distant past for a tree with none).
    public var lastActive: Date {
        let newest = (trunk.map(\.date) + limbs.flatMap { $0.commits.map(\.date) }).max()
        return newest ?? .distantPast
    }
}
