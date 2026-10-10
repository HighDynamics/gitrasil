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

    func testAHangingPennantIsLiftedByAGustAndFallsBack() {
        let still = BannerLayer.lift("fix/x", side: 1, droop: 72, strength: 0, seconds: 100)
        XCTAssertEqual(still, 72, accuracy: 1e-9, "still, it dangles")
        XCTAssertEqual(BannerLayer.lift("fix/x", side: -1, droop: 72, strength: 0, seconds: 100), -72, accuracy: 1e-9)
        for seconds in stride(from: 0.0, to: 6, by: 0.25) {
            let peak = BannerLayer.lift("fix/x", side: 1, droop: 72, strength: 1, seconds: seconds)
            XCTAssertEqual(peak, BannerLayer.lifted, accuracy: 3.4 * 1.8 + 1e-9, "at the gust's peak it's held up near level")
        }
    }
}
