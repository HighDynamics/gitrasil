import XCTest
@testable import GitrasilCore

final class StatusBadgeTests: XCTestCase {

    func testPrecedenceConflictedWinsAll() {
        let facts = WorktreeStatusFacts(inProgress: true, dirty: true, behind: true)
        XCTAssertEqual(facts.badge, .conflicted)
    }

    func testModifiedBeatsBehind() {
        let facts = WorktreeStatusFacts(inProgress: false, dirty: true, behind: true)
        XCTAssertEqual(facts.badge, .modified)
    }

    func testBehindWhenOnlyBehind() {
        let facts = WorktreeStatusFacts(inProgress: false, dirty: false, behind: true)
        XCTAssertEqual(facts.badge, .behind)
    }

    func testCleanShowsNoBadge() {
        XCTAssertNil(WorktreeStatusFacts().badge)
    }
}
