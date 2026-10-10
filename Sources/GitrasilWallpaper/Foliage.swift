import SwiftUI
import GitrasilCore

/// A tree's leaves and sprays: drawn by `TreeDrawing`.
extension TreeDrawing {
    /// A short, slightly curved twig with a fan of leaves at its end and one partway along.
    func spray(from base: CGPoint, heading: Double, length: CGFloat, leaves: Int, seed rng: inout SeededRandom,
               leafSeed: UInt64, color: Color, alpha: Double, in context: inout GraphicsContext) {
        guard length > 1 else { return }
        let direction = TreeFrame.direction(heading)
        let bend = rng.next(in: -0.35...0.35)
        let end = CGPoint(x: base.x + direction.x * length, y: base.y + direction.y * length)
        let control = CGPoint(x: base.x + direction.x * length * 0.5 + cos(heading) * length * bend,
                              y: base.y + direction.y * length * 0.5 + sin(heading) * length * bend)
        var twig = Path()
        twig.move(to: base)
        twig.addQuadCurve(to: end, control: control)
        context.stroke(twig, with: .color(style.ink.opacity(0.6 * alpha)), lineWidth: style.lineWidth * 0.8)
        let size = style.leafSize * frame.detail * 0.8
        let scale = min(1, length / (style.leafSize * frame.detail * 1.2))
        leaf(at: control, heading: heading + (bend > 0 ? -0.9 : 0.9), length: size * 0.8 * scale,
             color: color, alpha: alpha, seed: leafSeed, in: &context)
        for i in 0..<leaves {
            let spread = leaves > 1 ? Double(i) / Double(leaves - 1) * 2 - 1 : 0
            leaf(at: end, heading: heading + bend + spread * 0.75, length: size * rng.next(in: 0.85...1.15) * scale,
                 color: color, alpha: alpha, seed: Self.mix(leafSeed, i + 1), in: &context)
        }
    }

    /// Seed `seed`'s `index`th neighbour: for the leaves of one node or cluster.
    static func mix(_ seed: UInt64, _ index: Int) -> UInt64 {
        seed &+ UInt64(bitPattern: Int64(index + 1)) &* 0x9E3779B97F4A7C15
    }

    /// One leaf: an almond in the ink at `alpha`, outlined, with a midrib. Drawn by hand, each is a
    /// touch lopsided (its tip, sides and swell nudged by its seed).
    func leaf(at base: CGPoint, heading: Double, length: CGFloat, color: Color, alpha: Double,
              seed: UInt64, in context: inout GraphicsContext) {
        guard length > 0.5 else { return }
        var tip = CGPoint(x: length, y: 0)
        var upper = length * 0.36, lower = length * 0.36, swell = length * 0.45
        if style.hand > 0 {
            var rng = SeededRandom(seed: seed)
            let hand = style.hand
            tip = CGPoint(x: length * (1 + 0.08 * hand * (rng.next() * 2 - 1)), y: length * 0.07 * hand * (rng.next() * 2 - 1))
            upper *= 1 + 0.22 * hand * (rng.next() * 2 - 1)
            lower *= 1 + 0.22 * hand * (rng.next() * 2 - 1)
            swell += length * 0.08 * hand * (rng.next() * 2 - 1)
        }
        var shape = Path()
        shape.move(to: .zero)
        shape.addQuadCurve(to: tip, control: CGPoint(x: swell, y: -upper))
        shape.addQuadCurve(to: .zero, control: CGPoint(x: swell, y: lower))
        var rib = Path()
        rib.move(to: .zero)
        rib.addLine(to: CGPoint(x: tip.x * 0.8, y: tip.y * 0.8))
        let transform = CGAffineTransform(translationX: base.x, y: base.y).rotated(by: heading - .pi / 2)
        context.fill(shape.applying(transform), with: .color(color.opacity(style.leafOpacity * alpha)))
        context.stroke(shape.applying(transform), with: .color(color.opacity(style.leafLine * alpha)), lineWidth: style.lineWidth * 0.6)
        context.stroke(rib.applying(transform), with: .color(color.opacity(0.7 * alpha)), lineWidth: style.lineWidth * 0.45)
    }
}
