import XCTest
@testable import GitrasilCore

final class GrowInWaitTests: XCTestCase {

    func testWithEveryTreeReadItGrowsAtOnce() {
        var wait = GrowInWait()
        XCTAssertEqual(wait.start(allSettled: true), .growNow)
        XCTAssertFalse(wait.isWaiting)
        XCTAssertFalse(wait.settled(allSettled: true), "nothing to end")
    }

    func testTheLastRepositoryReadEndsTheWaitEarly() {
        var wait = GrowInWait()
        guard case .wait(let round) = wait.start(allSettled: false) else { return XCTFail("it waits") }
        XCTAssertTrue(wait.isWaiting)
        XCTAssertFalse(wait.settled(allSettled: false), "one tree in, others still being read")
        XCTAssertTrue(wait.isWaiting)
        // The last one in, with a tree or a problem: either way it's read.
        XCTAssertTrue(wait.settled(allSettled: true))
        XCTAssertFalse(wait.isWaiting)
        XCTAssertFalse(wait.timedOut(round: round), "the limit passing later grows nothing more")
        XCTAssertFalse(wait.settled(allSettled: true))
    }

    func testTheLimitEndsAWaitThatsStillOn() {
        var wait = GrowInWait()
        guard case .wait(let round) = wait.start(allSettled: false) else { return XCTFail("it waits") }
        XCTAssertTrue(wait.timedOut(round: round))
        XCTAssertFalse(wait.isWaiting)
        XCTAssertFalse(wait.settled(allSettled: true), "a tree arriving after the limit doesn't grow it again")
    }

    func testANewGrowInReplacesTheWaitUnderWay() {
        var wait = GrowInWait()
        guard case .wait(let first) = wait.start(allSettled: false),
              case .wait(let second) = wait.start(allSettled: false) else { return XCTFail("both wait") }
        XCTAssertFalse(wait.timedOut(round: first), "the first wait's limit is stale")
        XCTAssertTrue(wait.isWaiting)
        XCTAssertTrue(wait.timedOut(round: second))
    }

    func testOutOfSightItStopsWaitingWithoutGrowing() {
        var wait = GrowInWait()
        guard case .wait(let round) = wait.start(allSettled: false) else { return XCTFail("it waits") }
        wait.cancel()
        XCTAssertFalse(wait.isWaiting)
        XCTAssertFalse(wait.settled(allSettled: true))
        XCTAssertFalse(wait.timedOut(round: round))
    }
}
