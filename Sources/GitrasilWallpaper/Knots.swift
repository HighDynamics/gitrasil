import AppKit
import SwiftUI
import GitrasilCore

/// Knots in the wood at some of a stem's joints (`TreeLayout.Knot`), drawn with its bark (`TreeDrawing.draw`).
extension TreeDrawing {
    /// A knot as drawn: an oval along the wood around `centre`, `across` points wide, turned to `axis`
    /// (the stem's direction there).
    struct Knot {
        var centre: CGPoint
        var axis: CGPoint
        var across: CGFloat

        private var placed: CGAffineTransform {
            CGAffineTransform(a: axis.x, b: axis.y, c: -axis.y, d: axis.x, tx: centre.x, ty: centre.y)
        }

        /// Its outline, `scale` times its size: half as long again along the wood as across it.
        func oval(_ scale: CGFloat) -> Path {
            let w = across * scale, l = across * scale * 1.5
            return Path(ellipseIn: CGRect(x: -l / 2, y: -w / 2, width: l, height: w)).applying(placed)
        }

        /// The grain parting around it, `scale` times its size: the oval's two long sides, open at its ends,
        /// where the grain runs on along the wood.
        func grain(_ scale: CGFloat) -> Path {
            let a = across * scale * 0.75, b = across * scale * 0.5
            var path = Path()
            for (from, to) in [(0.12, 0.88), (1.12, 1.88)] {
                let points = stride(from: from, through: to, by: 0.04).map { CGPoint(x: a * cos($0 * .pi), y: b * sin($0 * .pi)) }
                path.addLines(points)
            }
            return path.applying(placed)
        }
    }

    /// Where `stem`'s knots (`TreeLayout.Knot`) fall on its wood as drawn (`samples`): each a little to the
    /// outside of its turn. None on wood too fine to show one.
    func knots(_ stem: TreeLayout.Stem, _ samples: [(point: CGPoint, width: CGFloat)]) -> [Knot] {
        guard style.barkOpacity > 0, samples.count > 2 else { return [] }
        return stem.knots.compactMap { knot in
            guard stem.curve.indices.contains(knot.index) else { return nil }
            let wood = frame.point(stem.curve[knot.index].point)
            let i = samples.indices.min { a, b in
                hypot(samples[a].point.x - wood.x, samples[a].point.y - wood.y) < hypot(samples[b].point.x - wood.x, samples[b].point.y - wood.y)
            }!
            let width = samples[i].width
            guard width > 3.5 else { return nil }
            let a = samples[max(i - 1, 0)].point, b = samples[min(i + 1, samples.count - 1)].point
            let span = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            let axis = CGPoint(x: (b.x - a.x) / span, y: (b.y - a.y) / span)
            // Its right as it heads out, on the page (y down).
            let right = CGPoint(x: -axis.y, y: axis.x), off = CGFloat(knot.side) * width * 0.12
            return Knot(centre: CGPoint(x: samples[i].point.x + right.x * off, y: samples[i].point.y + right.y * off),
                        axis: axis, across: width * CGFloat(knot.size) * 0.8)
        }
    }

    /// Knots in the wood: an eye of deeper wood, rimmed, with the grain parting around it in the medium's
    /// own bark marks (light on brush ink, dark on charcoal, chalk on chalk).
    func draw(_ knots: [Knot], in context: inout GraphicsContext) {
        guard !knots.isEmpty else { return }
        let grain = style.streaksInInk ? style.ink : style.paper[1]
        // Deeper is darker: the ink on a light page, the page (or the board) where the ink is light.
        let eye = Self.brightness(style.ink) < Self.brightness(style.paper[1]) ? style.ink : style.paper[1]
        let rim = eye == style.ink ? style.paper[1] : style.ink
        let strength = min(style.barkOpacity * 2.2, 0.9)
        for knot in knots {
            let line = min(max(knot.across * 0.09, 0.8), 1.4)
            context.stroke(knot.oval(0.5), with: .color(rim.opacity(strength * 0.7)), style: StrokeStyle(lineWidth: line))
            context.fill(knot.oval(0.42), with: .color(eye.opacity(0.85)))
            context.stroke(knot.grain(1), with: .color(grain.opacity(strength)),
                           style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
        }
    }

    /// How light `color` is, 0 to 1.
    static func brightness(_ color: Color) -> CGFloat {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }
}
