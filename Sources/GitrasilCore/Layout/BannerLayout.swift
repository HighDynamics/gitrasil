import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where branch names hang: each on a small pennant tied to its tip by a thread that runs outward,
/// away from the crown. In screen points, y down. Pure, so a redraw places the same banners.
///
/// A pennant hangs from its hook by its upper inner corner and streams outward (to the right of the
/// hook on the right of the tree, to the left on the left). Tips are placed in the order given (the
/// most important first); each tries hooks at a few distances and angles out from its tip, on its
/// outward side first. A spot must keep the pennant (with a margin for its sway) and its thread off
/// every pennant placed before it, inside the bounds; among those it takes the first that's clear of
/// the crown (the obstacles), else the one that covers the least of it. A tip with no such spot gets
/// no banner, rather than one piled on another.
public enum BannerLayout {

    public struct Request: Sendable, Equatable {
        public let id: String
        /// The tip the thread is tied to.
        public let tip: CGPoint
        /// Which side the banner prefers: -1 left, 1 right.
        public let outward: Double
        /// The pennant's size.
        public let size: CGSize

        public init(id: String, tip: CGPoint, outward: Double, size: CGSize) {
            self.id = id
            self.tip = tip
            self.outward = outward
            self.size = size
        }
    }

    public struct Banner: Sendable, Equatable {
        public let id: String
        public let tip: CGPoint
        /// Where the thread ends and the pennant hangs from: its upper inner corner.
        public let hook: CGPoint
        /// The pennant, unswayed.
        public let rect: CGRect
        /// The side it streams to: -1 left, 1 right.
        public let side: Double
    }

    /// Room kept around each pennant for its sway and for breathing space.
    public static let margin: CGFloat = 5

    /// Thread lengths tried, and angles below the horizontal (radians; positive hangs lower).
    static let reaches: [CGFloat] = [24, 36, 50, 66, 86, 110, 140, 175]
    static let angles: [Double] = [0.3, 0.6, 0.05, 0.9, -0.25, 1.2, -0.55, -0.85]

    /// - Parameters:
    ///   - obstacles: the crown (wood and leaves), as rects to keep pennants off.
    ///   - taken: anything already on screen that pennants must not cover (other text).
    ///   - bounds: where pennants may go.
    public static func place(_ requests: [Request], obstacles: [CGRect], taken: [CGRect] = [],
                             bounds: CGRect) -> [Banner] {
        var placed: [CGRect] = taken
        var banners: [Banner] = []
        for request in requests {
            var best: (banner: Banner, cost: CGFloat)?
            search: for side in [request.outward >= 0 ? 1.0 : -1.0, request.outward >= 0 ? -1.0 : 1.0] {
                for reach in reaches {
                    for angle in angles {
                        let hook = CGPoint(x: request.tip.x + CGFloat(side * cos(angle)) * reach,
                                           y: request.tip.y + CGFloat(sin(angle)) * reach)
                        let rect = pennant(at: hook, side: side, size: request.size)
                        let padded = rect.insetBy(dx: -margin, dy: -margin)
                        guard bounds.contains(rect),
                              !placed.contains(where: { $0.intersects(padded) || crosses(request.tip, hook, $0) })
                        else { continue }
                        let cover = covered(rect, by: obstacles)
                        let banner = Banner(id: request.id, tip: request.tip, hook: hook, rect: rect, side: side)
                        if cover == 0 { best = (banner, 0); break search }
                        // A little extra cover is worth a shorter thread and the outward side.
                        let cost = cover + reach * 2 + (side == (request.outward >= 0 ? 1 : -1) ? 0 : 400)
                        if best == nil || cost < best!.cost { best = (banner, cost) }
                    }
                }
            }
            guard let chosen = best?.banner else { continue }
            banners.append(chosen)
            placed.append(chosen.rect)
        }
        return banners
    }

    /// The pennant hanging from `hook` and streaming to `side`.
    public static func pennant(at hook: CGPoint, side: Double, size: CGSize) -> CGRect {
        CGRect(x: side > 0 ? hook.x : hook.x - size.width, y: hook.y, width: size.width, height: size.height)
    }

    /// How much of `rect` the obstacles cover (overlaps counted again).
    static func covered(_ rect: CGRect, by obstacles: [CGRect]) -> CGFloat {
        obstacles.reduce(0) { total, obstacle in
            let overlap = rect.intersection(obstacle)
            return overlap.isNull ? total : total + overlap.width * overlap.height
        }
    }

    /// Whether the thread from `a` to `b` passes through `rect`.
    static func crosses(_ a: CGPoint, _ b: CGPoint, _ rect: CGRect) -> Bool {
        let steps = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 4))
        return (0...steps).contains { i in
            let t = CGFloat(i) / CGFloat(steps)
            return rect.contains(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
    }
}
