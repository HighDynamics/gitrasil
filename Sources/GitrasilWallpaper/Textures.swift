import AppKit
import SwiftUI
import GitrasilCore

/// The dry media's textures, each made once (per medium, mode and display scale) from seeded noise
/// (`HandDrawn.noiseTile`, itself made once per medium and scale), kept, and tiled: never computed
/// per frame.
///
/// - The *surface* shows over the paper: charcoal paper's tooth (its valleys shaded), a chalk
///   board's dust (light specks).
/// - The *grain* is where a stroke loses its pigment: the paper's valleys, from the same noise as the
///   tooth, so a stroke breaks up where the paper dips. Drawn with `destinationOut` over what's
///   drawn (`Textures.grained`).
enum Textures {

    /// A tile's side in points; it repeats seamlessly.
    static let tile: CGFloat = 256

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: Any] = [:]

    /// The surface over the paper, or nil for a medium without one.
    static func surface(_ style: WallpaperStyle, dark: Bool, scale: CGFloat) -> Image? {
        guard style.surface > 0 else { return nil }
        // The board's dust is the same in light and dark mode.
        let mode = style.medium == .chalk ? "" : "-\(dark)"
        return cached("surface-\(style.medium.rawValue)\(mode)-\(scale)") {
            let noise = noise(style.medium, scale: scale)
            switch style.medium {
            case .chalk:
                // Dust: light specks where the board is high.
                let (low, high) = noise.quantiles(0.85, 0.998)
                return image(noise, scale: scale, color: (0.9, 0.92, 0.88)) { min(max(($0 - low) / (high - low), 0), 1) * 0.4 }
            default:
                // Tooth: the valleys in shadow, the peaks catching light.
                let (low, high) = noise.quantiles(0.02, 0.5)
                let shade: (Double, Double, Double) = dark ? (0.05, 0.04, 0.03) : (0.32, 0.26, 0.18)
                return image(noise, scale: scale, color: shade) { min(max((high - $0) / (high - low), 0), 1) * 0.35 }
            }
        }
    }

    /// The grain a stroke loses its pigment to, or nil for a medium without one.
    static func grain(_ style: WallpaperStyle, scale: CGFloat) -> Image? {
        guard style.grain > 0 else { return nil }
        return cached("grain-\(style.medium.rawValue)-\(scale)") {
            let noise = noise(style.medium, scale: scale)
            // Chalk breaks up more than charcoal: more of the surface is too low to catch it.
            let (low, high) = style.medium == .chalk ? noise.quantiles(0.3, 0.62) : noise.quantiles(0.06, 0.45)
            return image(noise, scale: scale, color: (0, 0, 0)) { min(max((high - $0) / (high - low), 0), 1) }
        }
    }

    /// Draws `content`, then takes away the grain from it (when the style has one), so every stroke in
    /// it breaks up on the tooth. `origin` is where the screen's top-left is in this context, so the
    /// grain lines up with the paper's tooth under it.
    static func grained(_ style: WallpaperStyle, in context: inout GraphicsContext, size: CGSize,
                        origin: CGPoint = .zero, _ content: (inout GraphicsContext) -> Void) {
        guard let grain = grain(style, scale: context.environment.displayScale) else { return content(&context) }
        context.drawLayer { layer in
            content(&layer)
            layer.blendMode = .destinationOut
            layer.opacity = style.grain
            layer.fill(Path(CGRect(origin: .zero, size: size)), with: .tiledImage(grain, origin: origin))
        }
    }

    // MARK: Making them

    /// The value kept under `key`, made by `make` the first time. Made outside the lock, so making one
    /// (a surface) can ask for another (its noise).
    private static func cached<Value>(_ key: String, _ make: () -> Value) -> Value {
        lock.lock()
        let kept = cache[key] as? Value
        lock.unlock()
        if let kept { return kept }
        let value = make()
        lock.lock()
        defer { lock.unlock() }
        if let kept = cache[key] as? Value { return kept }
        cache[key] = value
        return value
    }

    /// A noise tile, and its values in order (for its quantiles).
    private struct Noise {
        let values: [Double]
        let sorted: [Double]

        /// The values below which fractions `a` and `b` of the noise lie.
        func quantiles(_ a: Double, _ b: Double) -> (Double, Double) {
            func at(_ q: Double) -> Double { sorted[min(Int(q * Double(sorted.count)), sorted.count - 1)] }
            return (at(a), at(b))
        }
    }

    /// The medium's noise: a fine tooth with some mottling for charcoal paper; finer and more
    /// speckled for a board. Made once per medium and scale, for both its surface and its grain.
    private static func noise(_ medium: Medium, scale: CGFloat) -> Noise {
        cached("noise-\(medium.rawValue)-\(scale)") {
            let size = Int(tile * scale), s = Int(max(scale, 1))
            let values = switch medium {
            case .chalk:
                HandDrawn.noiseTile(size: size, seed: 0xC4A1, octaves: [(2 * s, 0.5), (8 * s, 0.2)], speckle: 0.5)
            default:
                HandDrawn.noiseTile(size: size, seed: 0xC4A2, octaves: [(2 * s, 0.55), (4 * s, 0.3), (8 * s, 0.12)],
                                    speckle: 0.5)
            }
            return Noise(values: values, sorted: values.sorted())
        }
    }

    /// One colour, its alpha at each pixel `alpha(noise)`.
    private static func image(_ noise: Noise, scale: CGFloat, color: (Double, Double, Double),
                              alpha: (Double) -> Double) -> Image {
        let side = Int(Double(noise.values.count).squareRoot())
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for (i, value) in noise.values.enumerated() {
            let a = alpha(value)
            bytes[i * 4] = UInt8(color.0 * a * 255)
            bytes[i * 4 + 1] = UInt8(color.1 * a * 255)
            bytes[i * 4 + 2] = UInt8(color.2 * a * 255)
            bytes[i * 4 + 3] = UInt8(a * 255)
        }
        // The image keeps its own copy of the pixels.
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!,
                            decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return Image(decorative: image, scale: scale)
    }
}
