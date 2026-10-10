import AppKit
import SwiftUI
import GitrasilCore

// The forest (docs/forest/PLAN.md): trees laid out by `ForestLayout` in depth rows instead of equal
// plots, once the orchard has more than `ForestPolicy.plainLimit` of them, and in the single tree the
// repositories that don't fit on it, standing behind it on either side.

extension Landscape {

    /// Where the repositories are drawn: on the single tree, in the forest, or (a plain orchard) neither.
    struct Scene {
        /// On the single tree, in pin order (its bough is its place in this list).
        var tree: [Pane] = []
        /// In the forest, in pin order.
        var forest: [Pane] = []
    }

    /// The share of the screen's width the single tree may take when a forest stands beside it, and
    /// the share of its crown's width kept clear of forest trees (lower down they'd meet its roots).
    static let crownShare: CGFloat = 0.66
    static let clearShare: CGFloat = 0.8
    /// How much of the height the forest beside a tree may fill, and how pale its nearest trees stand.
    static let besideHeight: CGFloat = env("GITRASIL_FOREST_BESIDE", 0.58, 0.3...1)
    static let besideFade = 0.42

    /// Splits `panes` between the single tree and the forest: the tree takes the display's capacity,
    /// the most recently active first (by the ranking: frozen, so a commit doesn't move trees).
    func scene(_ panes: [Pane], arrangement: Arrangement) -> Scene {
        let ready = panes.filter { $0.tree != nil }
        guard isSingleTree(panes, arrangement: arrangement) else { return Scene(tree: [], forest: isPacked(panes) ? ready : []) }
        guard forest != .off, ready.count > policy.treeCapacity(for: size) else { return Scene(tree: ready, forest: []) }
        let onTree = policy.onTree(ready.map { ($0.seed, ranking[$0.id] ?? $0.tree?.lastActive ?? .distantPast) }, size: size)
        return Scene(tree: ready.enumerated().filter { onTree.contains($0.offset) }.map(\.element),
                     forest: ready.enumerated().filter { !onTree.contains($0.offset) }.map(\.element))
    }

    /// A forest's trees and where `ForestLayout` stands them, with the extra ground lines. Beside a
    /// single tree (`crown`: how wide its crown stands), they keep clear of it, stand lower and paler.
    func forestScene(_ panes: [Pane], crown: CGFloat? = nil) -> (planted: [Planted], plan: ForestPlan) {
        let ready = panes.indices.filter { panes[$0].tree != nil }
        let layouts = ready.map { TreeLayout(tree: panes[$0].tree!, seed: panes[$0].seed, shuffle: shuffle) }
        let trees = zip(ready, layouts).map { index, layout -> ForestTree in
            let pane = panes[index], tree = pane.tree!
            return ForestTree(id: pane.seed, group: Self.folder(of: pane.id), left: layout.bounds.minX, right: layout.bounds.maxX,
                              height: layout.bounds.maxY, lastActive: ranking[pane.id] ?? tree.lastActive)
        }
        let beside = crown != nil
        let screen = ForestScreen(size: size, groundY: Composition.groundY(size.height), top: Composition.top,
                                  margin: TreeFrame.margin, nominalHeight: Composition.nominalHeight,
                                  heightShare: beside ? Self.besideHeight : Self.heightShare,
                                  gap: (crown ?? 0) * Self.clearShare, minFade: beside ? Self.besideFade : 0)
        let plan = ForestLayout.rows(trees, screen: screen)
        var faded: [Double: WallpaperStyle] = [:]
        let planted = plan.placements.map { place -> Planted in
            let frame = TreeFrame(size: size, scale: place.scale, x: place.x, ground: place.ground, detailFloor: 0.2)
            let look = faded[place.fade] ?? style.faded(place.fade)
            faded[place.fade] = look
            return Planted(index: ready[place.index], full: layouts[place.index], frame: frame,
                           forest: ForestPlanted(style: look, line: place.line, slot: place.slot, fade: place.fade))
        }
        return (planted, plan)
    }

    /// GITRASIL_FOREST_HEIGHT (0.4…1): how much of the screen's height a forest on its own may fill.
    static let heightShare: CGFloat = env("GITRASIL_FOREST_HEIGHT", 1, 0.4...1)

    private static func env(_ key: String, _ standard: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        ProcessInfo.processInfo.environment[key].flatMap { Double($0) }.map { min(max(CGFloat($0), range.lowerBound), range.upperBound) }
            ?? standard
    }

    /// The folder a repository sits in.
    static func folder(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// The ground under each line behind the front one.
    func drawForestGrounds(_ plan: ForestPlan, in context: inout GraphicsContext) {
        for ground in plan.grounds {
            var line = Path()
            var rng = SeededRandom("ground\(Int(ground.y))")
            let phase = rng.next() * .pi * 2
            line.move(to: CGPoint(x: ground.from, y: ground.y))
            for x in stride(from: ground.from, through: ground.to, by: 12) {
                line.addLine(to: CGPoint(x: x, y: ground.y + sin(x / 150 + phase) * 1.2))
            }
            let look = style.faded(ground.fade)
            Sketch(look).stroke(line, with: .color(look.ink.opacity(0.4)), width: look.lineWidth * 0.9,
                                seed: HandDrawn.seed("ground\(Int(ground.y))"), in: &context)
        }
    }
}

extension TreeDrawing {

    /// A repository's name under its tree in a crowd, in the room its neighbours leave: whole when it
    /// fits, smaller when it nearly does, written down the ground when it doesn't, left out when even
    /// that is too small to read. Only the front line is named.
    func forestPlate(_ name: String, line: Int, slot: CGFloat, in context: inout GraphicsContext) {
        guard line == 0 else { return }
        fittedPlate(name, slot: slot, in: &context)
    }

    /// A repository's name under its tree, fitted to `slot` points of ground (`PlateFit`).
    func fittedPlate(_ name: String, slot: CGFloat, in context: inout GraphicsContext) {
        let text = Text(name).font(style.plateFont).foregroundColor(style.ink.opacity(style.plateOpacity))
        let resolved = context.resolve(text)
        let natural = resolved.measure(in: CGSize(width: 4000, height: 400))
        guard natural.width > 0 else { return }
        var drawn = context
        switch PlateFit.of(width: natural.width, height: natural.height, slot: slot) {
        case .across(let k):
            drawn.translateBy(x: frame.origin.x, y: frame.origin.y + 22 * k)
            drawn.scaleBy(x: k, y: k)
            drawn.draw(resolved, at: .zero, anchor: .top)
        case .down(let k):
            // Down the page, from the ground, the letters' tops to the right.
            drawn.translateBy(x: frame.origin.x, y: frame.origin.y + 8)
            drawn.rotate(by: .degrees(90))
            drawn.scaleBy(x: k, y: k)
            drawn.draw(resolved, at: .zero, anchor: .leading)
        case .none:
            break
        }
    }
}

extension WallpaperStyle {

    /// The same look seen through haze: inks mixed `amount` of the way into the paper, so a tree in a
    /// back line is paler. 0 is the look itself.
    func faded(_ amount: Double) -> WallpaperStyle {
        guard amount > 0 else { return self }
        let haze = paper[paper.count / 2]
        var look = self
        look.ink = Self.mix(ink, haze, amount)
        look.branchInks = branchInks.map { Self.mix($0, haze, amount) }
        look.leafInk = Self.mix(leafInk, haze, amount)
        look.captionInk = Self.mix(captionInk, haze, amount)
        return look
    }

    static func mix(_ color: Color, _ other: Color, _ amount: Double) -> Color {
        guard let a = NSColor(color).usingColorSpace(.sRGB), let b = NSColor(other).usingColorSpace(.sRGB) else { return color }
        let t = CGFloat(amount)
        return Color(.sRGB, red: Double(a.redComponent + (b.redComponent - a.redComponent) * t),
                     green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * t),
                     blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * t),
                     opacity: Double(a.alphaComponent))
    }
}
