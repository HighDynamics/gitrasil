import SwiftUI
import GitrasilCore

/// Lines as a hand draws them (`HandDrawn` in Core): a little off true, swelling and thinning along
/// their length, overshooting where they close, gone over `passes` times. Seeded by what they draw,
/// so a line is the same on every redraw. With a hand of 0 a line is stroked true, exactly as before.
struct Sketch {
    /// How much lines stray (`WallpaperStyle.hand`).
    let hand: CGFloat
    let passes: Int

    init(_ style: WallpaperStyle) {
        hand = style.hand
        passes = style.passes
    }

    /// Strokes `path` in `shading`, `width` wide.
    func stroke(_ path: Path, with shading: GraphicsContext.Shading, width: CGFloat, seed: UInt64,
                in context: inout GraphicsContext) {
        guard hand > 0 else {
            return context.stroke(path, with: shading, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        for pass in 0..<passes {
            let line = lines(path, seed: seed, pass: pass, width: width)
            // A second pass is lighter, as a sketch's going-over is.
            if pass > 0 {
                var light = context
                light.opacity = 0.6
                light.fill(line, with: shading)
            } else {
                context.fill(line, with: shading)
            }
        }
    }

    /// `path` as a hand draws it (its first pass), to fill.
    func shape(_ path: Path, seed: UInt64) -> Path {
        guard hand > 0 else { return path }
        var shape = Path()
        for polyline in Self.polylines(path) {
            let points = HandDrawn.displace(polyline.points, seed: seed, amplitude: 0.7 * hand, wavelength: 26)
            shape.addLines(points)
            if polyline.closed { shape.closeSubpath() }
        }
        return shape
    }

    /// One pass over `path`'s lines, as filled shapes of varying width.
    private func lines(_ path: Path, seed: UInt64, pass: Int, width: CGFloat) -> Path {
        var shape = Path()
        for (index, polyline) in Self.polylines(path).enumerated() {
            let seed = seed &+ UInt64(index &* 7 &+ pass &* 101) &* 0x9E3779B97F4A7C15
            var points = polyline.points
            // A closed line runs on past where it started, so its ends don't meet exactly.
            if polyline.closed, let first = points.first {
                points.append(first)
                var rng = SeededRandom(seed: seed)
                let overshoot = (2 + 3 * rng.next()) * hand
                var run: CGFloat = 0
                for i in 1..<polyline.points.count {
                    let a = polyline.points[i - 1], b = polyline.points[i]
                    let length = hypot(b.x - a.x, b.y - a.y)
                    if run + length >= overshoot {
                        let t = (overshoot - run) / max(length, 0.001)
                        points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                        break
                    }
                    run += length
                    points.append(b)
                }
            }
            let amplitude = (pass == 0 ? 0.7 : 1.1) * hand
            points = HandDrawn.displace(points, seed: seed, amplitude: amplitude, wavelength: 26)
            shape.addPath(Self.ribbon(points, width: width, seed: seed ^ 0xFF51AFD7ED558CCD, swell: 0.3 * min(hand, 1.5)))
        }
        return shape
    }

    /// A line through `points` as a filled outline, `width` wide, swelling and thinning by up to
    /// `swell` of it along its length, tapering a little at each end.
    static func ribbon(_ points: [CGPoint], width: CGFloat, seed: UInt64, swell: Double) -> Path {
        guard points.count >= 2 else { return Path() }
        var distances: [CGFloat] = [0]
        for i in 1..<points.count {
            distances.append(distances[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        let total = max(distances.last ?? 0, 0.001)
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in points.indices {
            let a = points[max(i - 1, 0)], b = points[min(i + 1, points.count - 1)]
            let length = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            let normal = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
            let d = distances[i]
            let ends = min(min(d, total - d) / min(4 * width, total / 2), 1)
            let half = width / 2 * (1 + swell * HandDrawn.wobble(seed, at: Double(d) / 34)) * (0.55 + 0.45 * ends)
            left.append(CGPoint(x: points[i].x + normal.x * half, y: points[i].y + normal.y * half))
            right.append(CGPoint(x: points[i].x - normal.x * half, y: points[i].y - normal.y * half))
        }
        var path = Path()
        path.move(to: left[0])
        for point in left.dropFirst() + right.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// `path` flattened into polylines, curves sampled every few points.
    static func polylines(_ path: Path) -> [(points: [CGPoint], closed: Bool)] {
        var result: [(points: [CGPoint], closed: Bool)] = []
        var current: [CGPoint] = []
        func finish(closed: Bool) {
            if current.count >= 2 { result.append((current, closed)) }
            current = []
        }
        func sample(_ count: Int, _ point: (CGFloat) -> CGPoint) {
            for k in 1...count { current.append(point(CGFloat(k) / CGFloat(count))) }
        }
        func steps(_ from: CGPoint, _ to: CGPoint, _ via: CGPoint...) -> Int {
            var length: CGFloat = 0, last = from
            for p in via + [to] { length += hypot(p.x - last.x, p.y - last.y); last = p }
            return max(2, min(48, Int(length / 4)))
        }
        path.forEach { element in
            switch element {
            case .move(let to):
                finish(closed: false)
                current = [to]
            case .line(let to):
                guard let from = current.last else { current = [to]; return }
                // Long straight runs get midpoints, so they can wobble.
                sample(max(1, Int(hypot(to.x - from.x, to.y - from.y) / 8))) { t in
                    CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                }
            case .quadCurve(let to, let control):
                guard let from = current.last else { current = [to]; return }
                sample(steps(from, to, control)) { t in
                    let u = 1 - t
                    return CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                                   y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
                }
            case .curve(let to, let c1, let c2):
                guard let from = current.last else { current = [to]; return }
                sample(steps(from, to, c1, c2)) { t in
                    let u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    return CGPoint(x: a * from.x + b * c1.x + c * c2.x + d * to.x,
                                   y: a * from.y + b * c1.y + c * c2.y + d * to.y)
                }
            case .closeSubpath:
                if let first = current.first, let last = current.last, hypot(first.x - last.x, first.y - last.y) < 0.01 {
                    current.removeLast()
                }
                finish(closed: true)
            }
        }
        finish(closed: false)
        return result
    }
}
