import XCTest
import SwiftUI
import GitrasilCore
@testable import GitrasilWallpaper

/// Banners at their boughs' depths: what's painted after a depth is cut out of a banner's mask, and
/// nothing else is.
@MainActor
final class OcclusionTests: XCTestCase {

    private func commits(_ prefix: String, _ count: Int) -> [RepoTree.Commit] {
        (0..<count).map { RepoTree.Commit(sha: "\(prefix)\($0)", date: Date(timeIntervalSince1970: Double($0))) }
    }

    /// A trunk with two limbs, drawn at 800 pt a unit, and an occlusion painting it whole.
    private func occlusion() -> (Occlusion, TreeLayout, TreeDrawing) {
        let limbs = [
            RepoTree.Limb(name: "low", commits: commits("a", 8), parent: .trunk(node: 40), isCheckedOut: false),
            RepoTree.Limb(name: "high", commits: commits("b", 8), parent: .trunk(node: 120), isCheckedOut: false)
        ]
        let layout = TreeLayout(tree: RepoTree(trunkName: "main", trunk: commits("t", 160), limbs: limbs, isTrunkCheckedOut: false),
                                seed: "ash")
        let frame = TreeFrame(size: CGSize(width: 2000, height: 2000), bounds: layout.bounds, nominalHeight: 1.45, scale: 800,
                              maxWidth: 2000, x: 1000)
        let drawing = TreeDrawing(style: .make(.chalk, dark: false), now: Date(), frame: frame)
        let occlusion = Occlusion()
        occlusion.add(layout.stems, seeds: layout.stems.map { _ in "ash" }, drawing: drawing, groups: nil, foliage: nil)
        return (occlusion, layout, drawing)
    }

    /// A box on the screen around the middle of the trunk's wood.
    private func boxOnTrunk(_ layout: TreeLayout, _ drawing: TreeDrawing) -> CGRect {
        let outline = drawing.outline(layout.stems[0])
        let middle = outline[outline.count / 2].point
        return CGRect(x: middle.x - 40, y: middle.y - 40, width: 80, height: 80)
    }

    /// The share of the mask's pixels it lets show (alpha over a half).
    private func shown(_ mask: OcclusionMask) -> Double {
        let renderer = ImageRenderer(content: mask)
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            XCTFail("the mask renders")
            return 0
        }
        let pixel = image.bitsPerPixel / 8
        var opaque = 0
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[y * image.bytesPerRow + x * pixel + 3] > 127 { opaque += 1 }
        }
        return Double(opaque) / Double(image.width * image.height)
    }

    func testWhatsPaintedInFrontIsCutOutOfTheMask() {
        let (occlusion, layout, drawing) = occlusion()
        let box = boxOnTrunk(layout, drawing)
        XCTAssertTrue(occlusion.reaches(after: 0, into: box), "the trunk's wood crosses the box")
        let behind = shown(OcclusionMask(occlusion: occlusion, depth: 0, box: box))
        XCTAssertLessThan(behind, 0.9, "the trunk is cut out of a banner behind it")
        XCTAssertGreaterThan(behind, 0.05, "and only the trunk")
    }

    func testNothingIsCutWhenNothingIsInFront() {
        let (occlusion, layout, drawing) = occlusion()
        let box = boxOnTrunk(layout, drawing)
        XCTAssertFalse(occlusion.reaches(after: occlusion.marks.count, into: box), "nothing is painted after the last mark")
        XCTAssertEqual(shown(OcclusionMask(occlusion: occlusion, depth: occlusion.marks.count, box: box)), 1, accuracy: 1e-9)
        let away = CGRect(x: 10, y: 10, width: 40, height: 40)
        XCTAssertFalse(occlusion.reaches(after: 0, into: away), "the tree doesn't reach a far corner of the screen")
    }

    func testANameMostlyLostBehindTheFoliageInFrontComesForward() {
        let (occlusion, layout, drawing) = occlusion()
        let box = boxOnTrunk(layout, drawing)
        let hook = CGPoint(x: box.minX + 10, y: box.midY)
        let rect = BannerLayout.pennant(at: hook, side: 1, size: CGSize(width: 60, height: 20))
        let banner = BannerLayout.Banner(id: "ash\u{1F}low", tip: hook, hook: hook, rect: rect, side: 1)
        var plan = BannerPlan()
        plan.occlusion = occlusion
        plan.banners = [BannerPlan.Hanging(banner: banner, pane: "ash", stem: "low", stretch: layout.schedule.trunk, name: "low",
                                           ink: .black, alpha: 1, fontSize: 12)]
        func hiddenFrom(under front: [CGRect]) -> Int? {
            let fronts = BannerPlan.Fronts(layers: [[], front], places: ["ash": 0])
            return Landscape.hidden(plan, depths: ["ash": 0], fronts: fronts).banners[0].hiddenFrom
        }
        XCTAssertEqual(hiddenFrom(under: []), 0, "the trunk painted after it hides it where it crosses")
        let third = CGRect(x: rect.minX, y: rect.minY, width: rect.width / 3, height: rect.height)
        XCTAssertEqual(hiddenFrom(under: [third]), 0, "a third under the foliage in front: still at its depth")
        XCTAssertNil(hiddenFrom(under: [rect.insetBy(dx: -4, dy: -4)]), "all of it under: it comes forward")
        // Only what's painted after it counts.
        let behind = BannerPlan.Fronts(layers: [[rect.insetBy(dx: -4, dy: -4)], []], places: ["ash": 1])
        XCTAssertEqual(Landscape.hidden(plan, depths: ["ash": 0], fronts: behind).banners[0].hiddenFrom, 0)
    }

    // MARK: Paint order

    /// A single tree of `count` repositories, each a bare trunk.
    private func singleTree(_ count: Int) -> YggdrasilLayout {
        YggdrasilLayout(repos: (0..<count).map { index in
            .init(name: "repo\(index)", tree: RepoTree(trunkName: "main", trunk: commits("r\(index)", 8 + index % 5), limbs: [],
                                                       isTrunkCheckedOut: false))
        }, fit: .fitting(count: count))
    }

    func testBoughsComingTowardTheViewerArePaintedLast() {
        let layout = singleTree(20)
        let shape = YggdrasilLayout.Shape(count: 20)
        let ranks = Landscape.paintRanks(layout)
        XCTAssertEqual(Set(ranks).count, ranks.count, "each bough has its own place")
        let front = (0..<shape.tiers).filter(shape.isFront)
        XCTAssertFalse(front.isEmpty, "a tree this tall has boughs coming toward the viewer")
        let behind = layout.boughs.indices.filter { !front.contains($0) }
        XCTAssertGreaterThan(front.map { ranks[$0] }.min()!, behind.map { ranks[$0] }.max()!)
        // The crown, at the back, first.
        for crown in shape.tiers..<shape.count { XCTAssertLessThan(ranks[crown], ranks[0]) }
    }

    func testASmallTreesBoughsArePaintedInTurn() {
        XCTAssertEqual(Landscape.paintRanks(singleTree(3)), [0, 1, 2])
    }

    // MARK: Gusts

    private func hanging(side: Double, droop: Double = 72) -> BannerLayout.Banner {
        let tip = CGPoint(x: 400, y: 300), hook = CGPoint(x: 400, y: 330), size = CGSize(width: 110, height: 22)
        return BannerLayout.Banner(id: "fix/x", tip: tip, hook: hook, rect: BannerLayout.pennant(at: hook, side: side, size: size),
                                   side: side, droop: droop)
    }

    func testAHangingPennantSwingsOutOnItsThreadInAGustAndFallsBack() {
        for side in [1.0, -1.0] {
            let banner = hanging(side: side)
            let still = BannerLayer.pose(banner, strength: 0, flap: BannerLayer.sway("fix/x", side: 1, lift: 0, strength: 0, seconds: 100))
            XCTAssertEqual(still, BannerLayer.Pose(swing: 0, turn: side * 72), "still, its thread hangs straight down and it dangles")
            for seconds in stride(from: 0.0, to: 6, by: 0.25) {
                let flap = BannerLayer.sway("fix/x", side: 1, lift: 0, strength: 1, seconds: seconds)
                XCTAssertLessThanOrEqual(abs(flap), BannerLayer.flap + 1e-9)
                let peak = BannerLayer.pose(banner, strength: 1, flap: flap)
                XCTAssertEqual(peak.turn, side * BannerLayer.lifted, accuracy: BannerLayer.flap * 1.8 + 1e-9,
                               "at the gust's peak it's held up near level")
                XCTAssertEqual(peak.swing, -side * BannerLayer.swung, accuracy: BannerLayer.flap * 1.3 + 1e-9)
                // Out to the side it streams to, and up.
                let hook = banner.hook(swung: peak.swing)
                XCTAssertGreaterThan((hook.x - banner.tip.x) * side, 0)
                XCTAssertLessThan(hook.y, banner.hook.y)
            }
        }
    }

    func testEveryPoseOfAGustKeepsAStreamingPennantInsideItsBox() {
        // The widest pennants rise the most as they turn; hooks above, level with and below their tips.
        for width in [60.0, 165, 240, 320] {
            for side in [1.0, -1.0] {
                for rise in [-30.0, 0, 30] {
                    let tip = CGPoint(x: 400, y: 300), hook = CGPoint(x: 400 + side * 40, y: 300 + rise)
                    let banner = BannerLayout.Banner(id: "fix/wide", tip: tip, hook: hook,
                                                     rect: BannerLayout.pennant(at: hook, side: side,
                                                                                size: CGSize(width: width, height: 22)),
                                                     side: side)
                    let box = BannerPlan.Hanging.box(of: banner)
                    for step in 0...20 {
                        for seconds in stride(from: 0.0, to: 8, by: 0.05) {
                            let turn = BannerLayer.sway("fix/wide", side: side, lift: BannerLayer.streamLift,
                                                        strength: Double(step) / 20, seconds: seconds)
                            XCTAssertTrue(box.contains(banner.footprint(swung: 0, turned: turn)),
                                          "width \(width), side \(side), rise \(rise), turn \(turn)")
                        }
                    }
                }
            }
        }
    }

    func testNoPoseOfAGustHangsAPennantLowerThanItHangsStill() {
        for droop in [66.0, 72, 80] {
            for side in [1.0, -1.0] {
                let banner = hanging(side: side, droop: droop), floor = banner.footprint.maxY
                for step in 0...40 {
                    let strength = Double(step) / 40
                    for flap in [-1.0, 0, 1] {
                        let pose = BannerLayer.pose(banner, strength: strength, flap: flap * BannerLayer.flap * strength)
                        XCTAssertLessThanOrEqual(banner.footprint(swung: pose.swing, turned: pose.turn).maxY, floor + 1,
                                                 "droop \(droop), side \(side), strength \(strength)")
                    }
                }
            }
        }
    }
}
