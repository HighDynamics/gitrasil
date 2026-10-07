import Foundation

/// What makes a line look drawn by hand rather than ruled: a slow seeded wobble along it, and the
/// grain a dry medium leaves. Everything here is a pure function of a seed and a place (a distance
/// along a line, a pixel in a tile), never of time or of anything else drawn, so a stroke keeps its
/// shape between redraws, a line that grows longer keeps the wobble it had, and a texture is the
/// same every time it's made.
public enum HandDrawn {

    /// A seed for one line, from what it draws (a branch's name, a banner's id) and an index.
    public static func seed(_ key: String, _ index: Int = 0) -> UInt64 {
        SeededRandom.hash(key) ^ (UInt64(bitPattern: Int64(index)) &* 0xD1B54A32D192ED03)
    }

    /// Smooth seeded noise in -1...1 at `x` (in wavelengths): two octaves of value noise, eased
    /// between whole numbers, so it's continuous and drifts about once per unit.
    public static func wobble(_ seed: UInt64, at x: Double) -> Double {
        0.72 * octave(seed, x) + 0.28 * octave(seed ^ 0x5851F42D4C957F2D, x * 2.7 + 13.1)
    }

    private static func octave(_ seed: UInt64, _ x: Double) -> Double {
        let i = floor(x), f = x - i
        let a = lattice(seed, Int64(i)), b = lattice(seed, Int64(i) + 1)
        let t = f * f * (3 - 2 * f)
        return a + (b - a) * t
    }

    /// A seeded value in -1...1 for one whole number.
    private static func lattice(_ seed: UInt64, _ i: Int64) -> Double {
        var rng = SeededRandom(seed: seed ^ (UInt64(bitPattern: i) &* 0x9E3779B97F4A7C15))
        return rng.next() * 2 - 1
    }

    /// `points` nudged off the line they make, each along its normal by `amplitude` times the
    /// wobble at its distance along the line (`wavelength` apart). The nudge depends only on the
    /// seed and the distance from the first point, so a line drawn further keeps its earlier points
    /// where they were (all but the last, whose normal turns with the new stretch).
    public static func displace(_ points: [CGPoint], seed: UInt64, amplitude: Double, wavelength: Double) -> [CGPoint] {
        guard points.count >= 2, amplitude != 0 else { return points }
        var distance = 0.0
        return points.indices.map { i in
            if i > 0 { distance += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y) }
            let a = points[max(i - 1, 0)], b = points[min(i + 1, points.count - 1)]
            let length = max(hypot(b.x - a.x, b.y - a.y), 0.000_001)
            let normal = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
            let offset = amplitude * wobble(seed, at: distance / wavelength)
            return CGPoint(x: points[i].x + normal.x * offset, y: points[i].y + normal.y * offset)
        }
    }

    /// A square tile of seeded noise, `size` pixels a side, in 0...1, row by row, that repeats
    /// seamlessly: value noise at each wavelength (in pixels, each dividing `size`) weighted and
    /// summed, plus `speckle` of fine white noise. The paper's tooth and a medium's grain are made
    /// from it once and tiled.
    public static func noiseTile(size: Int, seed: UInt64, octaves: [(wavelength: Int, weight: Double)],
                                 speckle: Double = 0) -> [Double] {
        var values = [Double](repeating: 0, count: size * size)
        let total = octaves.map(\.weight).reduce(speckle, +)
        guard total > 0 else { return values }
        for (index, octave) in octaves.enumerated() {
            let period = max(size / max(octave.wavelength, 1), 1)
            let lattice: [Double] = (0..<(period * period)).map { k in
                var rng = SeededRandom(seed: seed ^ UInt64(index &* 7919) ^ (UInt64(k) &* 0x9E3779B97F4A7C15))
                return rng.next()
            }
            let step = Double(period) / Double(size)
            for y in 0..<size {
                let fy = Double(y) * step, iy = Int(fy), ty = smooth(fy - Double(iy))
                let y0 = iy % period, y1 = (iy + 1) % period
                for x in 0..<size {
                    let fx = Double(x) * step, ix = Int(fx), tx = smooth(fx - Double(ix))
                    let x0 = ix % period, x1 = (ix + 1) % period
                    let top = lattice[y0 * period + x0] + (lattice[y0 * period + x1] - lattice[y0 * period + x0]) * tx
                    let bottom = lattice[y1 * period + x0] + (lattice[y1 * period + x1] - lattice[y1 * period + x0]) * tx
                    values[y * size + x] += (top + (bottom - top) * ty) * octave.weight
                }
            }
        }
        if speckle > 0 {
            var rng = SeededRandom(seed: seed ^ 0xA24BAED4963EE407)
            for i in values.indices { values[i] += rng.next() * speckle }
        }
        return values.map { $0 / total }
    }

    private static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}
