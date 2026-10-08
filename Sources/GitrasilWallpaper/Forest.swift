import AppKit
import SwiftUI
import GitrasilCore

// The forest spike (docs/forest/PLAN.md): the orchard's trees laid out by `ForestLayout` instead of in
// equal plots. Opt-in (`GITRASIL_BACKGROUND_FOREST`); nothing here runs in the default orchard.

extension Landscape {

    /// A forest's trees and where `ForestLayout` stands them, with the extra ground lines and groves.
    func forestScene(_ panes: [Pane]) -> (planted: [Planted], plan: ForestPlan) {
        let ready = panes.indices.filter { panes[$0].tree != nil }
        let layouts = ready.map { TreeLayout(tree: panes[$0].tree!, seed: panes[$0].seed, shuffle: shuffle) }
        let trees = zip(ready, layouts).map { index, layout -> ForestTree in
            let pane = panes[index], tree = pane.tree!
            return ForestTree(id: pane.seed, group: Self.folder(of: pane.id), left: layout.bounds.minX, right: layout.bounds.maxX,
                              height: layout.bounds.maxY, lastActive: tree.lastActive, activity: tree.activity(now: now))
        }
        let screen = ForestScreen(size: size, groundY: Composition.groundY(size.height), top: Composition.top,
                                  margin: TreeFrame.margin, nominalHeight: Composition.nominalHeight,
                                  heightShare: Self.heightShare)
        let plan = ForestLayout.plan(trees, mode: forest, screen: screen)
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

    /// GITRASIL_FOREST_HEIGHT (0.4…1): how much of the screen's height the forest may fill.
    static let heightShare: CGFloat = ProcessInfo.processInfo.environment["GITRASIL_FOREST_HEIGHT"]
        .flatMap { Double($0) }.map { CGFloat(min(max($0, 0.4), 1)) } ?? 1

    func orchardPlanted(_ panes: [Pane]) -> [Planted] { forestScene(panes).planted }

    /// The folder a repository sits in.
    static func folder(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// The ground under each line behind the front one, and each grove's caption.
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
        for grove in plan.groves {
            let y = grove.y + 74
            var bracket = Path()
            bracket.move(to: CGPoint(x: grove.from, y: y - 8))
            bracket.addLine(to: CGPoint(x: grove.from, y: y))
            bracket.addLine(to: CGPoint(x: grove.to, y: y))
            bracket.addLine(to: CGPoint(x: grove.to, y: y - 8))
            context.stroke(bracket, with: .color(style.ink.opacity(0.28)), lineWidth: style.lineWidth)
            let caption = Text("\((grove.name as NSString).lastPathComponent) · \(grove.count)")
                .font(style.captionFont).foregroundColor(style.captionInk)
            context.draw(caption, at: CGPoint(x: (grove.from + grove.to) / 2, y: y + 6), anchor: .top)
        }
    }
}

extension TreeDrawing {

    /// A repository's name under its tree in a crowd, in the room its neighbours leave: whole when it
    /// fits, smaller when it nearly does, written down the ground when it doesn't, left out when even
    /// that is too small to read. Only the front line is named.
    func forestPlate(_ name: String, line: Int, slot: CGFloat, in context: inout GraphicsContext) {
        guard line == 0 else { return }
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
