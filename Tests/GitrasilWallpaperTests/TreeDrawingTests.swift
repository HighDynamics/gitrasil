import XCTest
import SwiftUI
import GitrasilCore
@testable import GitrasilWallpaper

/// The wood's outline as the drawing builds it: the width samples the shapes are made of, in points.
final class TreeDrawingTests: XCTestCase {

    private func commits(_ prefix: String, _ count: Int) -> [RepoTree.Commit] {
        (0..<count).map { RepoTree.Commit(sha: "\(prefix)\($0)", date: Date(timeIntervalSince1970: Double($0))) }
    }

    /// A trunk, limbs from one commit to a dozen, a bud inside its parent's collar, a sub-limb and a
    /// limb at the trunk's very tip.
    private func layout(growIn: Double? = nil) -> TreeLayout {
        let limbs = [
            RepoTree.Limb(name: "one", commits: commits("a", 1), parent: .trunk(node: 60), isCheckedOut: false),
            RepoTree.Limb(name: "long", commits: commits("b", 12), parent: .trunk(node: 80), isCheckedOut: false),
            RepoTree.Limb(name: "long-sub", commits: commits("c", 3), parent: .limb(index: 1, node: 8), isCheckedOut: false),
            RepoTree.Limb(name: "bud", commits: [], parent: .trunk(node: 40), isCheckedOut: false),
            RepoTree.Limb(name: "mid", commits: commits("d", 5), parent: .trunk(node: 140), isCheckedOut: true),
            RepoTree.Limb(name: "at-the-tip", commits: commits("e", 2), parent: .trunk(node: 200), isCheckedOut: false)
        ]
        let tree = RepoTree(trunkName: "main", trunk: commits("t", 200), limbs: limbs, isTrunkCheckedOut: true)
        return TreeLayout(tree: tree, seed: "ash", growIn: growIn)
    }

    private func drawing(_ layout: TreeLayout, scale: CGFloat) -> TreeDrawing {
        let frame = TreeFrame(size: CGSize(width: 4000, height: 4000), bounds: layout.bounds, nominalHeight: 1.45, scale: scale,
                              maxWidth: 4000, x: 2000)
        XCTAssertEqual(frame.scale, scale, "the frame draws at the scale asked for")
        return TreeDrawing(style: .make(.chalk, dark: false), now: Date(), frame: frame)
    }

    /// Each sample's distance from the outline's end, along it.
    private func distancesToTip(_ samples: [(point: CGPoint, width: CGFloat)]) -> [CGFloat] {
        var distances = [CGFloat](repeating: 0, count: samples.count)
        for i in samples.indices.reversed().dropFirst() {
            distances[i] = distances[i + 1] + hypot(samples[i + 1].point.x - samples[i].point.x, samples[i + 1].point.y - samples[i].point.y)
        }
        return distances
    }

    func testEveryStemsOutlineEndsInAPointAtTheDrawingsFloor() {
        let layout = layout()
        let drawing = drawing(layout, scale: 800)
        for stem in layout.stems {
            let samples = drawing.outline(stem)
            XCTAssertGreaterThanOrEqual(samples.count, 2, stem.name ?? "?")
            // 0.9 pt is the drawing's floor. A collar flared over the end (the taper applied before the
            // collar, so the collar widens the tip again) or the width never tapering (the layout's
            // own tip is 4–10 pt at this scale) both show up here.
            XCTAssertEqual(samples.last?.width ?? 0, 0.9, accuracy: 1e-9, "\(stem.name ?? "?") ends in a point")
        }
    }

    func testTheTaperStartsFromTheTipAndLeavesTheBaseAlone() {
        let layout = layout()
        let drawing = drawing(layout, scale: 800)
        for name in ["main", "long", "mid"] {
            let stem = layout.stems.first { $0.name == name }!
            let samples = drawing.outline(stem)
            // Tapered from the wrong end, or not at all at the base: the base would be a point.
            let base = stem.nodes[0].width * 800
            XCTAssertGreaterThan(samples[0].width, base * 0.9 - 1e-6, "\(name)'s base is its own width, not tapered")
            if name != "main" { XCTAssertGreaterThanOrEqual(samples[0].width, base - 1e-6) }
        }
    }

    func testTheTaperIsMeasuredInTreeUnitsNotPoints() {
        let layout = layout()
        for scale in [400.0, 800.0, 1500.0] {
            let drawing = drawing(layout, scale: CGFloat(scale))
            for name in ["main", "long"] {
                let stem = layout.stems.first { $0.name == name }!
                let samples = drawing.outline(stem), toTip = distancesToTip(samples)
                let length = stem.tipTaper.length * scale
                // Where the taper starts the wood is as wide as it was (it eases in), and half way along
                // it's already narrowing: if distances weren't divided by the scale the taper would be
                // `scale` times too short and half way along it would still be full width.
                func width(at distance: CGFloat) -> CGFloat {
                    samples[toTip.indices.min { abs(toTip[$0] - distance) < abs(toTip[$1] - distance) }!].width
                }
                XCTAssertLessThan(width(at: CGFloat(length * 0.5)), width(at: CGFloat(length * 1.1)) * 0.9,
                                  "\(name) at \(scale): narrowing half way along its taper")
                XCTAssertLessThan(width(at: CGFloat(length * 0.1)), width(at: CGFloat(length * 0.5)),
                                  "\(name) at \(scale): narrower still nearer the tip")
                XCTAssertGreaterThan(length, 8, "\(name) at \(scale): a taper you can see")
            }
        }
    }

    func testTheCollarIsNotTaperedAndABudsTaperLeavesNoStub() {
        let layout = layout()
        let drawing = drawing(layout, scale: 800)
        let bud = layout.stems.first { $0.name == "bud" }!
        let samples = drawing.outline(bud)
        let fork = bud.fork!, own = bud.nodes[0].width
        // At its base the bud flares into its parent, as `collarWidth` says: the collar comes first, the
        // taper after, and the taper hasn't started at the base.
        let flared = TreeLayout.collarWidth(at: 0, own: own, parentWidth: fork.width,
                                            angle: bud.nodes[0].heading - fork.heading) * 800
        XCTAssertGreaterThan(flared, own * 800 * 1.05, "this bud does flare")
        XCTAssertEqual(samples[0].width, flared, accuracy: 1e-6)
    }

    func testAStemPartWayThroughAGrowInTapersToWhereItHasGot() {
        for growIn in [0.2, 0.5, 0.8] {
            let layout = layout(growIn: growIn)
            let drawing = drawing(layout, scale: 800)
            for stem in layout.stems where stem.curve.count >= 2 {
                let samples = drawing.outline(stem)
                // A young trunk is still thick (its 30 pt wide foot is a quarter of the way up), so its point
                // is `TipTaper.point` of that, a little over the floor; before the taper it was the full width.
                XCTAssertLessThan(samples.last?.width ?? 0, 2, "\(stem.name ?? "?") at \(growIn) is cut to a point")
                XCTAssertLessThan(samples.last?.width ?? 0, 0.1 * (stem.curve.last?.width ?? 0) * 800 + 0.9 + 1e-9)
            }
        }
    }
}
