import XCTest
@testable import GitrasilCore

final class BannerLayoutTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 1440, height: 800)

    /// A crown of tips around (700, 400), each wanting a banner on its own side.
    private func requests(_ count: Int, size: CGSize = CGSize(width: 120, height: 22)) -> [BannerLayout.Request] {
        (0..<count).map { i in
            let angle = Double(i) / Double(count) * .pi * 2
            let tip = CGPoint(x: 700 + cos(angle) * 160, y: 400 + sin(angle) * 120)
            return .init(id: "b\(i)", tip: tip, outward: cos(angle) >= 0 ? 1 : -1, size: size)
        }
    }

    /// The crown: a block of wood and leaves around the tips.
    private let crown = [CGRect(x: 560, y: 300, width: 280, height: 200)]

    func testBannersNeverOverlapEachOther() {
        let banners = BannerLayout.place(requests(24), obstacles: crown, bounds: bounds)
        XCTAssertGreaterThan(banners.count, 12)
        for (i, a) in banners.enumerated() {
            for b in banners[(i + 1)...] {
                XCTAssertFalse(a.rect.insetBy(dx: -BannerLayout.margin, dy: -BannerLayout.margin).intersects(b.rect),
                               "\(a.id) and \(b.id)")
                XCTAssertFalse(BannerLayout.crosses(b.tip, b.hook, a.rect), "\(b.id)'s thread crosses \(a.id)")
            }
        }
    }

    func testBannersHangOutwardClearOfTheCrownWhenThereIsRoom() {
        let banners = BannerLayout.place(requests(6), obstacles: crown, bounds: bounds)
        XCTAssertEqual(banners.count, 6)
        for banner in banners {
            XCTAssertFalse(banner.rect.intersects(crown[0]), banner.id)
            XCTAssertTrue(bounds.contains(banner.rect))
            XCTAssertEqual(banner.side > 0, banner.hook.x > banner.tip.x, "the thread runs the way it streams")
        }
        let right = banners.filter { $0.tip.x > 700 }
        XCTAssertTrue(right.allSatisfy { $0.side > 0 }, "tips on the right stream right")
    }

    func testAPennantHangsFromItsUpperInnerCorner() {
        let size = CGSize(width: 90, height: 20)
        let right = BannerLayout.pennant(at: CGPoint(x: 100, y: 50), side: 1, size: size)
        let left = BannerLayout.pennant(at: CGPoint(x: 100, y: 50), side: -1, size: size)
        XCTAssertEqual(right, CGRect(x: 100, y: 50, width: 90, height: 20))
        XCTAssertEqual(left, CGRect(x: 10, y: 50, width: 90, height: 20))
    }

    func testTheSameTipsGetTheSameBanners() {
        let a = BannerLayout.place(requests(16), obstacles: crown, bounds: bounds)
        let b = BannerLayout.place(requests(16), obstacles: crown, bounds: bounds)
        XCTAssertEqual(a, b)
    }

    func testATipWithNoRoomGetsNoBanner() {
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 60)
        let crowded = (0..<6).map { BannerLayout.Request(id: "\($0)", tip: CGPoint(x: 100, y: 10), outward: 1,
                                                          size: CGSize(width: 80, height: 20)) }
        let banners = BannerLayout.place(crowded, obstacles: [], bounds: tiny)
        XCTAssertLessThan(banners.count, 6)
        XCTAssertTrue(banners.allSatisfy { tiny.contains($0.rect) })
    }

    func testBannersKeepOffWhatsAlreadyTaken() {
        let request = BannerLayout.Request(id: "x", tip: CGPoint(x: 400, y: 400), outward: 1, size: CGSize(width: 100, height: 20))
        let first = BannerLayout.place([request], obstacles: [], bounds: bounds)[0]
        let moved = BannerLayout.place([request], obstacles: [], taken: [first.rect], bounds: bounds)[0]
        XCTAssertFalse(moved.rect.intersects(first.rect))
    }

    // MARK: Ribbons

    /// Three boughs fanning out of a crotch at (700, 500), each with anchors along its underside.
    private func ribbonRequests(size: CGSize = CGSize(width: 220, height: 44)) -> [BannerLayout.RibbonRequest] {
        [(-1.0, "left"), (0.0, "middle"), (1.0, "right")].map { lean, name in
            let anchors = (1...6).map { k -> CGPoint in
                let step = CGFloat(k)
                return CGPoint(x: 700 + CGFloat(lean) * step * 45, y: 500 - step * (lean == 0 ? 40 : 18))
            }
            return .init(id: name, anchors: anchors, size: size)
        }
    }

    func testRibbonsNeverOverlapEachOtherOrTheirCords() {
        let ribbons = BannerLayout.hang(ribbonRequests(), obstacles: crown, bounds: bounds)
        XCTAssertEqual(ribbons.count, 3)
        for (i, a) in ribbons.enumerated() {
            XCTAssertTrue(bounds.contains(a.rect))
            XCTAssertGreaterThan(a.rect.minY, a.anchor.y, "\(a.id) hangs below its anchor")
            for b in ribbons[(i + 1)...] {
                XCTAssertFalse(a.rect.insetBy(dx: -BannerLayout.margin, dy: -BannerLayout.margin).intersects(b.rect),
                               "\(a.id) and \(b.id)")
                XCTAssertFalse(BannerLayout.crosses(b.anchor, b.cordEnds.0, a.rect))
                XCTAssertFalse(BannerLayout.crosses(b.anchor, b.cordEnds.1, a.rect))
            }
        }
    }

    func testRibbonsHangClearOfTheCrownWhenThereIsRoom() {
        let wood = [CGRect(x: 690, y: 300, width: 20, height: 200)]
        let ribbon = BannerLayout.hang([ribbonRequests()[1]], obstacles: wood, bounds: bounds)[0]
        XCTAssertFalse(ribbon.rect.intersects(wood[0]), "an upright bough's ribbon hangs beside it")
    }

    func testPennantsKeepOffTheRibbons() {
        let ribbons = BannerLayout.hang(ribbonRequests(), obstacles: [], bounds: bounds)
        let tips = (0..<20).map { i -> BannerLayout.Request in
            let tip = CGPoint(x: 560 + CGFloat(i % 5) * 70, y: 420 + CGFloat(i / 5) * 40)
            return BannerLayout.Request(id: "b\(i)", tip: tip, outward: i % 2 == 0 ? 1 : -1,
                                        size: CGSize(width: 110, height: 22))
        }
        let banners = BannerLayout.place(tips, obstacles: [], taken: ribbons.map(\.footprint), bounds: bounds)
        XCTAssertFalse(banners.isEmpty)
        for banner in banners {
            for ribbon in ribbons {
                XCTAssertFalse(banner.rect.intersects(ribbon.footprint), "\(banner.id) on \(ribbon.id)")
            }
        }
    }

    func testTheSameBoughsGetTheSameRibbons() {
        XCTAssertEqual(BannerLayout.hang(ribbonRequests(), obstacles: crown, bounds: bounds),
                       BannerLayout.hang(ribbonRequests(), obstacles: crown, bounds: bounds))
    }

    func testTheCrownGridMeasuresCoverLikeBruteForce() {
        var rng = SeededRandom(seed: 7)
        func random(_ scale: CGFloat) -> CGRect {
            CGRect(x: rng.next() * 1400 - 20, y: rng.next() * 800 - 20,
                   width: rng.next() * scale, height: rng.next() * scale)
        }
        let obstacles = (0..<2000).map { _ in random(60) } + [CGRect(x: 96, y: 96, width: 48, height: 48), .zero]
        let crown = BannerLayout.Crown(obstacles)
        for _ in 0..<300 {
            let rect = random(200)
            XCTAssertEqual(crown.covered(rect), BannerLayout.covered(rect, by: obstacles), accuracy: 0.01, "\(rect)")
        }
    }
}
