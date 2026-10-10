import SwiftUI
import GitrasilCore

/// A tree's leaves, sprays and twigs: drawn by `TreeDrawing`.
extension TreeDrawing {
    /// Leafy twigs along a bough (`draw`'s `foliage`): at most `twigs` on one, fewer on a bough of few
    /// commits.
    struct Foliage {
        var twigs: Int
    }

    /// Twigs off a trunk with commits (a bough's main), more for more commits, spread along it and
    /// mostly on its upper side, each with a few leaves along it and a fan at its end: not git's shape,
    /// foliage, in the trunk's leaf ink, so the branches stay the coloured part. A twig shows once the
    /// trunk has grown past it, and is seeded from the repository and its place, so a commit doesn't
    /// move the others.
    func twigs(_ stem: TreeLayout.Stem, _ samples: [(point: CGPoint, width: CGFloat)], repo: String,
               foliage: Foliage, in context: inout GraphicsContext) {
        let commits = stem.commits.count
        guard samples.count >= 2, commits > 0, stem.grown > 0 else { return }
        var along: [CGFloat] = [0]
        for (a, b) in zip(samples, samples.dropFirst()) { along.append(along[along.count - 1] + hypot(b.point.x - a.point.x, b.point.y - a.point.y)) }
        let length = along[along.count - 1], shown = min(stem.grown / Double(commits), 1)
        guard length > 12 else { return }
        let count = min(foliage.twigs, 5 + Int(3 * Double(commits).squareRoot()))
        let key = "\(repo)\u{1F}\(stem.name ?? "trunk")"
        let size = style.leafSize * frame.detail * 1.2
        for k in 0..<count {
            var rng = SeededRandom(key, -40 - k)
            let t = 0.12 + 0.86 * (Double(k) + rng.next(in: 0.1...0.9)) / Double(count)
            guard t <= shown else { continue }
            let at = CGFloat(t / shown) * length
            let i = min(along.lastIndex { $0 <= at } ?? 0, samples.count - 2)
            let a = samples[i], b = samples[i + 1]
            let span = max(hypot(b.point.x - a.point.x, b.point.y - a.point.y), 0.001)
            let d = CGPoint(x: (b.point.x - a.point.x) / span, y: (b.point.y - a.point.y) / span)
            // Its normals; screen y runs down, so the upper one has the smaller y.
            let up = d.x >= 0 ? CGPoint(x: d.y, y: -d.x) : CGPoint(x: -d.y, y: d.x)
            let side: CGFloat = rng.next() < 0.68 ? 1 : -1
            let normal = CGPoint(x: up.x * side, y: up.y * side)
            let f = (at - along[i]) / span
            let point = CGPoint(x: a.point.x + (b.point.x - a.point.x) * f, y: a.point.y + (b.point.y - a.point.y) * f)
            let edge = (a.width + (b.width - a.width) * f) * 0.4
            let base = CGPoint(x: point.x + normal.x * edge, y: point.y + normal.y * edge)
            let angle = rng.next(in: 0.45...1.1)
            var direction = CGPoint(x: d.x * cos(angle) + normal.x * sin(angle), y: d.y * cos(angle) + normal.y * sin(angle) - 0.2)
            let norm = max(hypot(direction.x, direction.y), 0.001)
            direction = CGPoint(x: direction.x / norm, y: direction.y / norm)
            let reach = size * rng.next(in: 1.4...2.6) * (1.15 - 0.35 * t)
            let commit = stem.commits[min(Int(t * Double(commits)), commits - 1)]
            let alpha = 0.65 + 0.35 * vigour(commit)
            let bend = rng.next(in: -0.3...0.3)
            let end = CGPoint(x: base.x + direction.x * reach, y: base.y + direction.y * reach)
            let control = CGPoint(x: base.x + direction.x * reach * 0.5 - direction.y * reach * bend,
                                  y: base.y + direction.y * reach * 0.5 + direction.x * reach * bend)
            var twig = Path()
            twig.move(to: base)
            twig.addQuadCurve(to: end, control: control)
            context.stroke(twig, with: .color(style.ink.opacity(0.85)),
                           style: StrokeStyle(lineWidth: max(style.lineWidth, 1), lineCap: .round))
            func heading(_ v: CGPoint) -> Double { atan2(Double(v.x), Double(-v.y)) }
            let h = heading(direction), leafSeed = HandDrawn.seed(key, -40 - k)
            for (j, u) in [0.3, 0.52, 0.74].enumerated() {
                let p = CGPoint(x: base.x + (control.x - base.x) * 2 * u * (1 - u) + (end.x - base.x) * u * u,
                                y: base.y + (control.y - base.y) * 2 * u * (1 - u) + (end.y - base.y) * u * u)
                let flip = (j + k) % 2 == 0 ? 1.0 : -1.0
                leaf(at: p, heading: h + flip * rng.next(in: 0.7...1.1), length: size * rng.next(in: 0.7...0.95),
                     color: style.leafInk, alpha: alpha, seed: Self.mix(leafSeed, j), in: &context)
            }
            let fan = 4 + (rng.next() < 0.5 ? 1 : 0)
            for j in 0..<fan {
                let spread = Double(j) / Double(fan - 1) * 2 - 1
                leaf(at: end, heading: h + bend + spread * 0.8, length: size * rng.next(in: 0.8...1.05),
                     color: style.leafInk, alpha: alpha, seed: Self.mix(leafSeed, 10 + j), in: &context)
            }
        }
    }

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
