import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where names hang. Branch names go on small pennants, each tied to its tip by a thread that runs
/// outward, away from the crown; in the single tree, repository names go on larger ribbons hung
/// under their boughs (see `hang`). In screen points, y down. Pure, so a redraw places the same
/// banners.
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
        let crown = Crown(obstacles)
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
                        let cover = crown.covered(rect)
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

    // MARK: Ribbons

    /// A repository's name in the single tree: a ribbon, larger than a pennant, hung by two cords
    /// from a point under its bough.
    public struct RibbonRequest: Sendable, Equatable {
        public let id: String
        /// Points under the bough it may hang from, the preferred first.
        public let anchors: [CGPoint]
        /// The ribbon's size.
        public let size: CGSize

        public init(id: String, anchors: [CGPoint], size: CGSize) {
            self.id = id
            self.anchors = anchors
            self.size = size
        }
    }

    public struct Ribbon: Sendable, Equatable {
        public let id: String
        /// Where both cords are tied.
        public let anchor: CGPoint
        /// The ribbon, unswayed.
        public let rect: CGRect

        /// Where the cords meet the ribbon's top edge.
        public var cordEnds: (CGPoint, CGPoint) {
            (CGPoint(x: rect.minX + rect.width * BannerLayout.cordInset, y: rect.minY),
             CGPoint(x: rect.maxX - rect.width * BannerLayout.cordInset, y: rect.minY))
        }

        /// The ribbon with its cords, for keeping pennants off both.
        public var footprint: CGRect { rect.union(CGRect(origin: anchor, size: .zero)) }
    }

    /// How far in from each end the cords meet the ribbon, as a fraction of its width.
    public static let cordInset: CGFloat = 0.3
    /// How far below its anchor a ribbon may hang, and where along it the anchor may be (0.5 hangs
    /// it centred; off centre it hangs beside an upright bough).
    static let drops: [CGFloat] = [14, 24, 36, 50, 66, 86]
    static let hangs: [CGFloat] = [0.5, 0.3, 0.7, 0.15, 0.85]

    /// Hangs each ribbon (in the order given) from one of its anchors: never on another ribbon, its
    /// cords never through one, inside the bounds; among those, the spot that covers the least of the
    /// crown, weighing a preferred anchor, a short drop and hanging centred against a little cover.
    /// A ribbon with no such spot is left out.
    public static func hang(_ requests: [RibbonRequest], obstacles: [CGRect], taken: [CGRect] = [],
                            bounds: CGRect) -> [Ribbon] {
        let crown = Crown(obstacles)
        var placed: [CGRect] = taken
        var ribbons: [Ribbon] = []
        for request in requests {
            var best: (ribbon: Ribbon, cost: CGFloat)?
            for (rank, anchor) in request.anchors.enumerated() {
                for drop in drops {
                    for (offset, hang) in hangs.enumerated() {
                        let rect = CGRect(x: anchor.x - request.size.width * hang, y: anchor.y + drop,
                                          width: request.size.width, height: request.size.height)
                        let ribbon = Ribbon(id: request.id, anchor: anchor, rect: rect)
                        let padded = rect.insetBy(dx: -margin, dy: -margin)
                        guard bounds.contains(rect), !placed.contains(where: { other in
                            other.intersects(padded) || crosses(anchor, ribbon.cordEnds.0, other)
                                || crosses(anchor, ribbon.cordEnds.1, other)
                        }) else { continue }
                        let cost = crown.covered(rect) + CGFloat(rank) * 40 + drop * 3 + CGFloat(offset) * 60
                        if best == nil || cost < best!.cost { best = (ribbon, cost) }
                    }
                }
            }
            guard let chosen = best?.ribbon else { continue }
            ribbons.append(chosen)
            placed.append(chosen.footprint)
        }
        return ribbons
    }

    // MARK: Geometry

    /// The pennant hanging from `hook` and streaming to `side`.
    public static func pennant(at hook: CGPoint, side: Double, size: CGSize) -> CGRect {
        CGRect(x: side > 0 ? hook.x : hook.x - size.width, y: hook.y, width: size.width, height: size.height)
    }

    /// How much of `rect` the obstacles cover (overlaps counted again), by brute force.
    static func covered(_ rect: CGRect, by obstacles: [CGRect]) -> CGFloat {
        obstacles.reduce(0) { total, obstacle in
            let overlap = rect.intersection(obstacle)
            return overlap.isNull ? total : total + overlap.width * overlap.height
        }
    }

    /// The crown's rects bucketed in a grid, so measuring a candidate's cover only looks at the rects
    /// near it: a dense crown has thousands, and every banner tries dozens of spots.
    struct Crown {
        static let cell: CGFloat = 48
        private let rects: [CGRect]
        /// Rect indices per cell, row by row, over the cells the rects span from `origin`.
        private var cells: [[Int]] = []
        private var origin = (x: 0, y: 0), columns = 0, rows = 0

        init(_ rects: [CGRect]) {
            self.rects = rects.filter { !$0.isNull && !$0.isInfinite }
            guard let first = self.rects.first else { return }
            let low = Self.cell(first.minX, first.minY), high = Self.cell(first.maxX, first.maxY)
            var minX = low.x, minY = low.y, maxX = high.x, maxY = high.y
            for rect in self.rects {
                let low = Self.cell(rect.minX, rect.minY), high = Self.cell(rect.maxX, rect.maxY)
                minX = min(minX, low.x); minY = min(minY, low.y); maxX = max(maxX, high.x); maxY = max(maxY, high.y)
            }
            origin = (minX, minY)
            columns = maxX - minX + 1
            rows = maxY - minY + 1
            cells = Array(repeating: [], count: columns * rows)
            for (index, rect) in self.rects.enumerated() {
                let low = Self.cell(rect.minX, rect.minY), high = Self.cell(rect.maxX, rect.maxY)
                for y in low.y...high.y {
                    for x in low.x...high.x { cells[(y - minY) * columns + x - minX].append(index) }
                }
            }
        }

        /// The same as `BannerLayout.covered(_:by:)`. A rect spanning several cells is counted once,
        /// in the cell holding its overlap's top-left corner.
        func covered(_ rect: CGRect) -> CGFloat {
            guard !cells.isEmpty, !rect.isNull else { return 0 }
            let low = Self.cell(rect.minX, rect.minY), high = Self.cell(rect.maxX, rect.maxY)
            let x0 = max(low.x, origin.x), x1 = min(high.x, origin.x + columns - 1)
            let y0 = max(low.y, origin.y), y1 = min(high.y, origin.y + rows - 1)
            guard x0 <= x1, y0 <= y1 else { return 0 }
            var total: CGFloat = 0
            for y in y0...y1 {
                for x in x0...x1 {
                    for index in cells[(y - origin.y) * columns + x - origin.x] {
                        let overlap = rect.intersection(rects[index])
                        guard !overlap.isNull, Self.cell(overlap.minX, overlap.minY) == (x, y) else { continue }
                        total += overlap.width * overlap.height
                    }
                }
            }
            return total
        }

        private static func cell(_ x: CGFloat, _ y: CGFloat) -> (x: Int, y: Int) {
            (Int((x / cell).rounded(.down)), Int((y / cell).rounded(.down)))
        }
    }

    /// Whether the thread from `a` to `b` passes through `rect`.
    static func crosses(_ a: CGPoint, _ b: CGPoint, _ rect: CGRect) -> Bool {
        // Most placed banners are nowhere near the thread.
        if max(a.x, b.x) < rect.minX || min(a.x, b.x) > rect.maxX || max(a.y, b.y) < rect.minY
            || min(a.y, b.y) > rect.maxY { return false }
        let steps = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 4))
        return (0...steps).contains { i in
            let t = CGFloat(i) / CGFloat(steps)
            return rect.contains(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
    }
}
