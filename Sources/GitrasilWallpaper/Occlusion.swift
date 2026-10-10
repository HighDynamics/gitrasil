import SwiftUI
import GitrasilCore

// Banners at their boughs' depths (docs/banners/PLAN.md). A banner keeps its own layer over the tree
// canvas, so a gust only turns layers; what's painted in front of its bough is cut out of it instead, and
// there the canvas under it already shows that wood and those leaves.

/// What the trees paint, in the order they paint it, for hiding banners behind it: every stem's wood
/// (the drawing's own tapered outline) and its foliage. Made once per banner plan, never per frame.
final class Occlusion {

    /// One thing painted: a stem's wood, or its twigs, leaves and blossom.
    enum Mark: Equatable {
        case wood(Int)
        case foliage(Int)

        var stem: Int {
            switch self {
            case .wood(let index), .foliage(let index): index
            }
        }
    }

    private struct Stem {
        let stem: TreeLayout.Stem
        let drawing: Int
        let seed: String
        let outline: [(point: CGPoint, width: CGFloat)]
        let shape: Path
        /// Its outline, which runs a little past it, stroked once.
        let edge: Path
        let top: Path?
        let foliage: TreeDrawing.Foliage?
        /// What its wood covers, and what its leaves and twigs can reach.
        let wood: CGRect
        let leafy: CGRect
    }

    private var drawings: [TreeDrawing] = []
    private var stems: [Stem] = []
    /// Everything painted, back to front. A banner at depth `d` is hidden by `marks[d...]`.
    private(set) var marks: [Mark] = []

    /// How much of a mark's ink counts as covering: the faintest leaf hides what's behind it.
    static let threshold = 0.08

    /// Adds a tree, painted after everything added before it: `stems` with their repositories' seeds,
    /// `groups` of them painted whole in turn (nil: the whole tree's wood at once), as
    /// `TreeDrawing.draw` paints them. Returns each stem's depth: just after its own foliage.
    @discardableResult
    func add(_ stems: [TreeLayout.Stem], seeds: [String], drawing: TreeDrawing, groups: [[Int]]?,
             foliage: TreeDrawing.Foliage?) -> [Int] {
        let offset = self.stems.count, which = drawings.count
        drawings.append(drawing)
        let leafReach = drawing.style.leafSize * drawing.frame.detail * 5.5
        for (stem, seed) in zip(stems, seeds) {
            let outline = drawing.outline(stem)
            let shape = outline.count >= 2 ? drawing.taper(outline, seed: drawing.woodSeed(stem, repo: seed)).shape : Path()
            let top = drawing.top(stem)
            let wood = shape.boundingRect.union(top?.boundingRect ?? .null)
            let line = outline.reduce(CGRect.null) { $0.union(CGRect(origin: $1.point, size: .zero)) }
            let edge = shape.strokedPath(StrokeStyle(lineWidth: drawing.style.lineWidth * 2.5, lineJoin: .round))
            self.stems.append(Stem(stem: stem, drawing: which, seed: seed, outline: outline, shape: shape, edge: edge, top: top,
                                   foliage: foliage, wood: wood.isNull ? .null : wood.insetBy(dx: -4, dy: -4),
                                   leafy: line.isNull ? .null : line.insetBy(dx: -leafReach, dy: -leafReach)))
        }
        var depths = [Int](repeating: 0, count: stems.count)
        for group in groups ?? [Array(stems.indices)] {
            marks += group.map { .wood(offset + $0) }
            for index in group {
                marks.append(.foliage(offset + index))
                depths[index] = marks.count
            }
        }
        return depths
    }

    private func bounds(_ mark: Mark) -> CGRect {
        switch mark {
        case .wood(let index): stems[index].wood
        case .foliage(let index): stems[index].leafy
        }
    }

    /// Whether anything painted at or after `depth` may cover part of `box`.
    func reaches(after depth: Int, into box: CGRect) -> Bool {
        marks[min(depth, marks.count)...].contains { bounds($0).intersects(box) }
    }

    /// Paints what's painted at or after `depth` and may cover part of `box`, in screen points, as the
    /// trees do (inks and all; `OcclusionMask` takes any ink as covering).
    func draw(after depth: Int, in box: CGRect, into context: inout GraphicsContext) {
        for mark in marks[min(depth, marks.count)...] where bounds(mark).intersects(box) {
            let stem = stems[mark.stem]
            var drawing = drawings[stem.drawing]
            drawing.only = box
            switch mark {
            case .wood:
                context.fill(stem.shape, with: .color(.black))
                context.fill(stem.edge, with: .color(.black))
                if let top = stem.top { context.fill(top, with: .color(.black)) }
            case .foliage:
                if let foliage = stem.foliage, stem.stem.isTrunk, !stem.stem.commits.isEmpty {
                    drawing.twigs(stem.stem, stem.outline, repo: stem.seed, foliage: foliage, in: &context)
                }
                drawing.leaves(stem.stem, repo: stem.seed, in: &context)
                if stem.stem.isCheckedOut { drawing.blossom(stem.stem, repo: stem.seed, in: &context) }
            }
        }
    }
}

/// Where a banner's view may show: its box (`box`, on the screen), less everything painted in front of
/// it. Drawn once into its own layer and fixed on the screen, so a banner swaying in a gust turns under it.
struct OcclusionMask: View, Equatable {
    let occlusion: Occlusion
    let depth: Int
    let box: CGRect

    static func == (a: OcclusionMask, b: OcclusionMask) -> Bool {
        a.occlusion === b.occlusion && a.depth == b.depth && a.box == b.box
    }

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            context.blendMode = .destinationOut
            context.drawLayer { layer in
                layer.addFilter(.alphaThreshold(min: Occlusion.threshold, color: .black))
                layer.translateBy(x: -box.minX, y: -box.minY)
                occlusion.draw(after: depth, in: box, into: &layer)
            }
        }
        .frame(width: box.width, height: box.height)
    }
}

// MARK: - Paint order

extension Landscape {

    /// How a single tree's stems (its trunk, then each bough's in turn) are painted. A tall tree's boughs
    /// are painted one by one over the trunk, each hiding what it passes in front of: the crown at the
    /// back, then the tiers reaching out to the sides from the top down, then those coming toward the
    /// viewer (`emerging`, by their first stems). A small tree's wood is one piece (`groups` nil). The
    /// banners hang at their boughs' depths in this same order (`Occlusion`).
    static func paintOrder(_ layout: YggdrasilLayout) -> (groups: [[Int]]?, emerging: Set<Int>) {
        let shape = YggdrasilLayout.Shape(count: layout.boughs.count)
        guard shape.tiers > 0 else { return (nil, []) }
        var ranges: [Range<Int>] = [], start = 1
        for bough in layout.boughs {
            ranges.append(start..<(start + bough.layout.stems.count))
            start += bough.layout.stems.count
        }
        let tiers = (0..<shape.tiers).reversed()
        let order = Array(shape.tiers..<shape.count) + tiers.filter { !shape.isFront($0) } + tiers.filter(shape.isFront)
        return ([[0]] + order.map { Array(ranges[$0]) }, Set((0..<shape.tiers).filter(shape.isFront).map { ranges[$0].lowerBound }))
    }

    /// Any single tree is leafy, its twigs shared out among its boughs.
    static func foliage(_ layout: YggdrasilLayout) -> TreeDrawing.Foliage {
        TreeDrawing.Foliage(twigs: min(max(twigBudget / max(layout.boughs.count, 1), 10), 36))
    }

    /// Each bough's place in the single tree's paint order (`paintOrder`): a bough is painted over
    /// every bough of a lower rank.
    static func paintRanks(_ layout: YggdrasilLayout) -> [Int] {
        guard let groups = paintOrder(layout).groups else { return Array(layout.boughs.indices) }
        var boughs: [Int: Int] = [:], start = 1
        for (index, bough) in layout.boughs.enumerated() {
            boughs[start] = index
            start += bough.layout.stems.count
        }
        var ranks = Array(layout.boughs.indices)
        for (rank, group) in groups.enumerated() {
            if let first = group.first, let bough = boughs[first] { ranks[bough] = rank }
        }
        return ranks
    }

    /// Adds the single tree `full` (of the repositories `ready`) to `occlusion`, in the order it's
    /// painted, and returns each repository's depth, by its pane's id: just after its whole bough.
    func depths(_ full: YggdrasilLayout, of ready: [Pane], frame: TreeFrame, in occlusion: Occlusion) -> [String: Int] {
        let seeds = ["yggdrasil"] + full.boughs.flatMap { bough in bough.layout.stems.map { _ in bough.name } }
        let stemDepths = occlusion.add([full.trunk] + full.boughs.flatMap(\.layout.stems), seeds: seeds,
                                       drawing: TreeDrawing(style: style, now: now, frame: frame),
                                       groups: Self.paintOrder(full).groups, foliage: Self.foliage(full))
        var depths: [String: Int] = [:], start = 1
        for (pane, bough) in zip(ready, full.boughs) {
            let stems = start..<(start + bough.layout.stems.count)
            depths[pane.id] = stems.map { stemDepths[$0] }.max() ?? occlusion.marks.count
            start = stems.upperBound
        }
        return depths
    }
}
