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
}
