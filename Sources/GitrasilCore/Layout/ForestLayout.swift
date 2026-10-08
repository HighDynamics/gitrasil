import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// How a crowd of trees is spread over the screen (docs/forest/PLAN.md). Spike: every mode but
/// `off` is opt-in (`GITRASIL_BACKGROUND_FOREST`).
public enum ForestMode: String, CaseIterable, Sendable {
    /// The orchard as it is: a plot of equal width per tree on one ground line.
    case off
    /// The orchard with the pane cap lifted and nothing else changed (the baseline).
    case plain
    /// One ground line, each tree given the room its crown takes, crowns allowed to interleave.
    case canopy
    /// Several ground lines in depth: back rows smaller and paler, the most recently active in front.
    case rows
    /// One ground line, busy repositories full-size and quiet ones saplings, packed by crown width.
    case activity
    /// Clustered by folder: a grove of staggered lines per folder, a gap between groves.
    case groves

    /// Whether `ForestLayout` places the trees (the other two use the orchard's equal plots).
    public var isPacked: Bool { self != .off && self != .plain }
}

/// One tree as the forest layout sees it: its crown in tree units (the trunk's foot is the origin,
/// the full-grown trunk 1 tall) and what says how it ranks.
public struct ForestTree: Sendable, Equatable {
    public var id: String
    /// The folder it sits in (its groves).
    public var group: String
    /// The crown's extent left and right of the trunk's foot, and its height, in tree units.
    public var left: Double
    public var right: Double
    public var height: Double
    /// When its newest commit was made.
    public var lastActive: Date
    /// Recent commits, each weighted by how fresh (half-life two weeks): the busy ones score high.
    public var activity: Double

    public init(id: String, group: String, left: Double, right: Double, height: Double,
                lastActive: Date, activity: Double) {
        self.id = id
        self.group = group
        self.left = left
        self.right = right
        self.height = height
        self.lastActive = lastActive
        self.activity = activity
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
    /// to leave sky.
    public var heightShare: CGFloat

    public init(size: CGSize, groundY: CGFloat, top: CGFloat, margin: CGFloat, nominalHeight: Double,
                heightShare: CGFloat = 1) {
        self.size = size
        self.groundY = groundY
        self.top = top
        self.margin = margin
        self.nominalHeight = nominalHeight
        self.heightShare = heightShare
    }

    /// The height from the ground to the highest a crown may reach.
    var tall: CGFloat { (groundY - top - margin) * heightShare }
    /// The widest a forest may run.
    var available: CGFloat { size.width - 2 * margin }
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

/// A grove's caption: its folder's name under the cluster.
public struct ForestGrove: Sendable, Equatable {
    public var name: String
    public var from: CGFloat
    public var to: CGFloat
    public var y: CGFloat
    public var count: Int
}

public struct ForestPlan: Sendable, Equatable {
    public var placements: [ForestPlacement] = []
    public var grounds: [ForestGround] = []
    public var groves: [ForestGrove] = []
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

    public static func plan(_ trees: [ForestTree], mode: ForestMode, screen: ForestScreen) -> ForestPlan {
        guard !trees.isEmpty, mode.isPacked else { return ForestPlan() }
        switch mode {
        case .canopy: return canopy(trees, screen: screen)
        case .rows: return rows(trees, screen: screen)
        case .activity: return activity(trees, screen: screen)
        case .groves: return groves(trees, screen: screen)
        case .off, .plain: return ForestPlan()
        }
    }

    // MARK: Spans

    /// A tree's reach each side of its foot, with room for leaves, rounded up.
    static func span(_ tree: ForestTree) -> (left: Double, right: Double) {
        func up(_ v: Double) -> Double { (v / quantum).rounded(.up) * quantum }
        return (up(max(-tree.left, 0.05) + pad), up(tree.right + pad))
    }

    /// The width a line of trees takes, in tree units at scale 1 (each tree's own `factor` applied):
    /// first crown's left edge to the last's right edge, adjacent crowns overlapping by `overlap`.
    static func extent(_ spans: [(left: Double, right: Double)], factors: [Double], overlap: Double) -> Double {
        guard !spans.isEmpty else { return 0 }
        var total = spans[0].left * factors[0]
        for i in spans.indices {
            if i + 1 < spans.count {
                total += (spans[i].right * factors[i] + spans[i + 1].left * factors[i + 1]) * (1 - overlap)
            } else {
                total += spans[i].right * factors[i]
            }
        }
        return total
    }

    /// Feet along a line from `start`, at `scale`, each tree scaled by its factor, with a seeded touch
    /// off true so the row isn't ruled.
    static func feet(_ spans: [(left: Double, right: Double)], factors: [Double], ids: [String], overlap: Double,
                     scale: CGFloat, start: CGFloat) -> [CGFloat] {
        var xs: [CGFloat] = []
        var cursor = start + CGFloat(spans[0].left * factors[0]) * scale
        for i in spans.indices {
            var rng = SeededRandom(ids[i], -21)
            let jitter = CGFloat(rng.next(in: -0.04...0.04))
            xs.append(cursor + jitter * CGFloat((spans[i].left + spans[i].right) * factors[i]) * scale)
            if i + 1 < spans.count {
                cursor += CGFloat((spans[i].right * factors[i] + spans[i + 1].left * factors[i + 1]) * (1 - overlap)) * scale
            }
        }
        return xs
    }

    /// From halfway to the neighbours either side (to the screen's edge, at the ends).
    static func slots(_ xs: [CGFloat], screen: ForestScreen, reach: [CGFloat]) -> [CGFloat] {
        xs.indices.map { i in
            let before = i > 0 ? xs[i] - xs[i - 1] : (xs[i] - screen.margin) * 2
            let after = i + 1 < xs.count ? xs[i + 1] - xs[i] : (screen.size.width - screen.margin - xs[i]) * 2
            return max(min(before, after), 8)
        }
    }

    // MARK: Canopy

    /// One ground line, each tree given room by its crown: the scale that makes the whole row just
    /// fit, no bigger than a lone tree would stand.
    static func canopy(_ trees: [ForestTree], screen: ForestScreen) -> ForestPlan {
        let spans = trees.map(span)
        let ones = trees.map { _ in 1.0 }
        let fit = CGFloat(screen.available) / CGFloat(extent(spans, factors: ones, overlap: overlap))
        let tallest = trees.map(\.height).max() ?? screen.nominalHeight
        let scale = min(fit, screen.tall / CGFloat(max(tallest, screen.nominalHeight)))
        let order = trees.indices.sorted { trees[$0].id < trees[$1].id }
        let ordered = order.map { spans[$0] }
        let xs = feet(ordered, factors: ones, ids: order.map { trees[$0].id }, overlap: overlap, scale: scale,
                      start: screen.margin + (screen.available - CGFloat(extent(ordered, factors: ones, overlap: overlap)) * scale) / 2)
        let slot = slots(xs, screen: screen, reach: [])
        var plan = ForestPlan()
        plan.scale = scale
        plan.placements = order.enumerated().map { rank, index in
            ForestPlacement(index: index, x: xs[rank], ground: screen.groundY, scale: scale, line: 0, fade: 0, slot: slot[rank])
        }
        return plan
    }

    // MARK: Activity

    /// How big a tree is drawn for how busy it is: a fraction of a busy one.
    public static func sizeFactor(activity: Double) -> Double {
        switch activity {
        case 8...: return 1.0
        case 2.5...: return 0.78
        case 0.6...: return 0.58
        default: return 0.42
        }
    }

    /// One ground line like the canopy's, but each tree scaled by its activity, so the quiet ones take
    /// less room and more fit.
    static func activity(_ trees: [ForestTree], screen: ForestScreen) -> ForestPlan {
        let spans = trees.map(span)
        let factors = trees.map { sizeFactor(activity: $0.activity) }
        let fit = CGFloat(screen.available) / CGFloat(extent(spans, factors: factors, overlap: overlap))
        let scale = min(fit, screen.tall / CGFloat(max(trees.map(\.height).max() ?? 1, screen.nominalHeight)))
        let order = trees.indices.sorted { trees[$0].id < trees[$1].id }
        let ordered = order.map { spans[$0] }, f = order.map { factors[$0] }
        let used = CGFloat(extent(ordered, factors: f, overlap: overlap)) * scale
        let xs = feet(ordered, factors: f, ids: order.map { trees[$0].id }, overlap: overlap, scale: scale,
                      start: screen.margin + (screen.available - used) / 2)
        let slot = slots(xs, screen: screen, reach: [])
        var plan = ForestPlan()
        plan.scale = scale
        plan.placements = order.enumerated().map { rank, index in
            ForestPlacement(index: index, x: xs[rank], ground: screen.groundY, scale: scale * CGFloat(f[rank]), line: 0,
                            fade: 0, slot: slot[rank])
        }
        return plan
    }

    // MARK: Rows

    /// Several ground lines in depth. Each line back is `depthScale` the size of the one in front and
    /// rises `depthRise` front trunk heights above it; the most recently active repositories stand in
    /// front. The number of lines is the fewest that keeps the front line's trees at a comfortable size
    /// (or the most that fit).
    static func rows(_ trees: [ForestTree], screen: ForestScreen) -> ForestPlan {
        let spans = trees.map(span)
        let tallest = CGFloat(max(trees.map(\.height).max() ?? 1, screen.nominalHeight))
        // Most recently active first (by day, so two commits in a day don't swap places), then by name.
        let ranked = trees.indices.sorted { a, b in
            let (x, y) = (Int(trees[a].lastActive.timeIntervalSince1970 / 86_400), Int(trees[b].lastActive.timeIntervalSince1970 / 86_400))
            return x != y ? x > y : trees[a].id < trees[b].id
        }
        let comfortable = screen.tall / tallest * 0.62
        var best: (scale: CGFloat, lines: [[Int]])?
        for count in 1...6 {
            let lines = distribute(ranked, lines: count)
            let scale = fitRows(lines, spans: spans, screen: screen, tallest: tallest)
            if best == nil || scale > best!.scale * 1.02 { best = (scale, lines) }
            if scale >= comfortable { best = (scale, lines); break }
        }
        guard let (scale, lines) = best else { return ForestPlan() }
        var plan = ForestPlan()
        plan.scale = scale
        plan.lines = lines.count
        var rise: CGFloat = 0
        for (k, members) in lines.enumerated() {
            let s = scale * CGFloat(pow(depthScale, Double(k)))
            if k > 0 { rise += CGFloat(depthRise) * scale * CGFloat(pow(depthScale, Double(k - 1))) }
            let fade = lines.count > 1 ? min(0.62, 0.62 * Double(k) / Double(lines.count - 1) + 0.04 * Double(min(k, 1))) : 0
            let order = members.sorted { trees[$0].id < trees[$1].id }
            let ordered = order.map { spans[$0] }
            let ones = order.map { _ in 1.0 }
            let used = CGFloat(extent(ordered, factors: ones, overlap: overlap)) * s
            // Each line starts a little off the one in front, so trunks don't stack.
            let phase = CGFloat(k % 2 == 0 ? 0 : 1) * min(40, s * 0.12)
            let xs = feet(ordered, factors: ones, ids: order.map { trees[$0].id + "\(k)" }, overlap: overlap, scale: s,
                          start: screen.margin + max((screen.available - used) / 2 + phase - phase / 2, 0))
            let slot = slots(xs, screen: screen, reach: [])
            let ground = screen.groundY - rise
            if k > 0, let first = xs.first, let last = xs.last {
                plan.grounds.append(ForestGround(y: ground, from: max(first - s * 0.4, 0), to: min(last + s * 0.4, screen.size.width),
                                                 fade: fade))
            }
            for (rank, index) in order.enumerated() {
                plan.placements.append(ForestPlacement(index: index, x: xs[rank], ground: ground, scale: s, line: k, fade: fade,
                                                       slot: slot[rank]))
            }
        }
        return plan
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
    static func fitRows(_ lines: [[Int]], spans: [(left: Double, right: Double)], screen: ForestScreen, tallest: CGFloat) -> CGFloat {
        var scale = screen.tall / tallest
        var rise = 0.0
        for (k, members) in lines.enumerated() {
            let f = pow(depthScale, Double(k))
            let ordered = members.sorted().map { spans[$0] }
            let width = extent(ordered, factors: ordered.map { _ in 1.0 }, overlap: overlap) * f
            if width > 0 { scale = min(scale, screen.available / CGFloat(width)) }
            if k > 0 { rise += depthRise * pow(depthScale, Double(k - 1)) }
            // The line's crowns must stay under the top.
            scale = min(scale, screen.tall / CGFloat(rise + Double(tallest) * f))
        }
        return scale
    }

    // MARK: Groves

    /// Trees clustered by folder. Each grove stands its trees on up to three staggered lines (the most
    /// recently active in front), crowns interleaving more than in a row; groves are set apart by a gap.
    static func groves(_ trees: [ForestTree], screen: ForestScreen) -> ForestPlan {
        let names = Array(Set(trees.map(\.group))).sorted()
        let spans = trees.map(span)
        let tallest = CGFloat(max(trees.map(\.height).max() ?? 1, screen.nominalHeight))
        let tight = 0.42
        let gap = 0.55 // tree units between groves
        struct Grove {
            var name: String
            var lines: [[Int]]
        }
        var groves: [Grove] = []
        for name in names {
            let members = trees.indices.filter { trees[$0].group == name }.sorted { a, b in
                let (x, y) = (Int(trees[a].lastActive.timeIntervalSince1970 / 86_400), Int(trees[b].lastActive.timeIntervalSince1970 / 86_400))
                return x != y ? x > y : trees[a].id < trees[b].id
            }
            let depth = members.count <= 3 ? 1 : members.count <= 9 ? 2 : 3
            var lines = Array(repeating: [Int](), count: depth)
            // Round-robin down the lines, the most recent first, so the front line has the freshest.
            for (i, member) in members.enumerated() { lines[i % depth].append(member) }
            groves.append(Grove(name: name, lines: lines))
        }
        func width(_ grove: Grove) -> Double {
            grove.lines.enumerated().map { k, members -> Double in
                let ordered = members.sorted { trees[$0].id < trees[$1].id }.map { spans[$0] }
                return extent(ordered, factors: ordered.map { _ in 1.0 }, overlap: tight) * pow(depthScale + 0.06, Double(k))
            }.max() ?? 0
        }
        let units = groves.map(width)
        let total = units.reduce(0, +) + gap * Double(max(groves.count - 1, 0))
        let depthMax = groves.map(\.lines.count).max() ?? 1
        let step = depthScale + 0.06
        var rise = 0.0
        for k in 1..<max(depthMax, 2) { rise += 0.2 * pow(step, Double(k - 1)) }
        let verticalCap = screen.tall / CGFloat(rise + Double(tallest) * pow(step, Double(depthMax - 1)))
        let scale = min(CGFloat(screen.available) / CGFloat(total), verticalCap, screen.tall / tallest)
        var plan = ForestPlan()
        plan.scale = scale
        plan.lines = depthMax
        var cursor = screen.margin + (screen.available - CGFloat(total) * scale) / 2
        for (g, grove) in groves.enumerated() {
            let w = CGFloat(units[g]) * scale
            var rise: CGFloat = 0
            for (k, members) in grove.lines.enumerated() {
                let f = pow(step, Double(k))
                let s = scale * CGFloat(f)
                if k > 0 { rise += CGFloat(0.2) * scale * CGFloat(pow(step, Double(k - 1))) }
                let order = members.sorted { trees[$0].id < trees[$1].id }
                let ordered = order.map { spans[$0] }
                let ones = order.map { _ in 1.0 }
                let used = CGFloat(extent(ordered, factors: ones, overlap: tight)) * s
                // Back lines start half a tree in, so their trunks fall between the front ones.
                let inset = k == 0 ? 0 : min(s * 0.25, (w - used) / 2)
                let shift = (k % 2 == 1 ? inset : -inset).clamped(0, max(w - used, 0))
                let xs = feet(ordered, factors: ones, ids: order.map { trees[$0].id + "g" }, overlap: tight, scale: s,
                              start: cursor + (w - used) / 2 + shift)
                let fade = grove.lines.count > 1 ? 0.2 * Double(k) : 0
                let slot = slots(xs, screen: screen, reach: [])
                if k > 0, let first = xs.first, let last = xs.last {
                    plan.grounds.append(ForestGround(y: screen.groundY - rise, from: first - s * 0.3, to: last + s * 0.3, fade: fade))
                }
                for (rank, index) in order.enumerated() {
                    plan.placements.append(ForestPlacement(index: index, x: xs[rank], ground: screen.groundY - rise, scale: s, line: k,
                                                           fade: fade, slot: min(slot[rank], max(w / CGFloat(max(order.count, 1)), 8))))
                }
            }
            plan.groves.append(ForestGrove(name: grove.name, from: cursor, to: cursor + w, y: screen.groundY,
                                           count: grove.lines.reduce(0) { $0 + $1.count }))
            cursor += w + CGFloat(gap) * scale
        }
        return plan
    }
}

private extension CGFloat {
    func clamped(_ low: CGFloat, _ high: CGFloat) -> CGFloat { Swift.min(Swift.max(self, low), high) }
}

extension ForestLayout {

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

    /// How busy it has been: every commit counts for 1 now, halving every two weeks.
    public func activity(now: Date) -> Double {
        let dates = trunk.map(\.date) + limbs.flatMap { $0.commits.map(\.date) }
        return dates.reduce(0) { $0 + pow(0.5, max(now.timeIntervalSince($1), 0) / (14 * 86_400)) }
    }
}
