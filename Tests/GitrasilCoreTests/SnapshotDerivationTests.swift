import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class SnapshotDerivationTests: XCTestCase {

    func testCleanSnapshotHasNoBadge() async throws {
        let repo = try await Topology.caseA()
        let snapshot = try await Derivations.worktreeSnapshot(runner: repo.runner)

        XCTAssertEqual(snapshot.branch, .branch("cw"))
        XCTAssertNil(snapshot.badge)
        XCTAssertNil(snapshot.inProgress)
        XCTAssertFalse(snapshot.isDetached)
        XCTAssertEqual(snapshot.graph.segments.first?.kind, .currentWorktree)
    }

    func testModifiedBadgeWhenDirty() async throws {
        let repo = try await Topology.caseA()
        try repo.writeFile("cw1.txt", "dirty")
        let snapshot = try await Derivations.worktreeSnapshot(runner: repo.runner)

        XCTAssertTrue(snapshot.statusFacts.dirty)
        XCTAssertEqual(snapshot.badge, .modified)
    }

    func testBehindBadgeWhenTrunkAhead() async throws {
        let repo = try await Topology.caseB()
        let snapshot = try await Derivations.worktreeSnapshot(runner: repo.runner)

        XCTAssertTrue(snapshot.statusFacts.behind)
        XCTAssertFalse(snapshot.statusFacts.dirty)
        XCTAssertEqual(snapshot.badge, .behind)
    }

    func testModifiedBeatsBehindInSnapshot() async throws {
        let repo = try await Topology.caseB()
        try repo.writeFile("cw1.txt", "dirty")
        let snapshot = try await Derivations.worktreeSnapshot(runner: repo.runner)

        XCTAssertTrue(snapshot.statusFacts.behind)
        XCTAssertTrue(snapshot.statusFacts.dirty)
        XCTAssertEqual(snapshot.badge, .modified, "modified outranks behind")
    }

    func testConflictedRebaseIsInProgressAndConflictedBadge() async throws {
        let repo = try await Topology.conflictedRebase()
        let snapshot = try await Derivations.worktreeSnapshot(runner: repo.runner)

        XCTAssertEqual(snapshot.inProgress, .rebase)
        XCTAssertEqual(snapshot.badge, .conflicted, "an in-progress operation outranks everything")
    }

    func testRebaseKeepsBranchLabelNotDetached() async throws {
        let repo = try await Topology.conflictedRebase()
        let snapshot = try await Derivations.worktreeSnapshot(runner: repo.runner)

        // git detaches HEAD mid-rebase, but the tab keeps naming the branch being replayed.
        XCTAssertEqual(snapshot.branch, .branch("cw"))
        XCTAssertFalse(snapshot.isDetached)
    }

    func testDetachedIdentity() async throws {
        let repo = try await Topology.detached()
        let snapshot = try await Derivations.worktreeSnapshot(runner: repo.runner)

        XCTAssertTrue(snapshot.isDetached)
        if case .detached(let sha) = snapshot.branch {
            XCTAssertFalse(sha.isEmpty)
        } else {
            XCTFail("expected detached identity")
        }
    }

    func testEmptyRepoSnapshot() async throws {
        let repo = try await Topology.empty()
        let snapshot = try await Derivations.worktreeSnapshot(runner: repo.runner)

        XCTAssertTrue(snapshot.graph.isEmpty)
        XCTAssertNil(snapshot.badge)
        XCTAssertEqual(snapshot.branch, .branch("main"), "unborn HEAD still names its branch")
    }
}
