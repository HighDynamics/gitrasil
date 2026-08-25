import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class GraphDerivationTests: XCTestCase {

    func testCaseA_singleLaneNoFork() async throws {
        let repo = try await Topology.caseA()
        let graph = try await Derivations.historyGraph(runner: repo.runner)

        XCTAssertEqual(graph.segments.count, 1)
        XCTAssertEqual(graph.segments.first?.kind, .currentWorktree)
        XCTAssertEqual(graph.segments.first?.commits.map(\.subject), ["cw-2", "cw-1"])
        XCTAssertNil(graph.trunkAhead, "main is not ahead")
        XCTAssertEqual(graph.branchesBetween, 0)
        XCTAssertEqual(graph.meetingCommit?.subject, "root")
        XCTAssertFalse(graph.hasUncommittedChanges)
    }

    func testCaseB_trunkAheadForkLane() async throws {
        let repo = try await Topology.caseB()
        let graph = try await Derivations.historyGraph(runner: repo.runner)

        XCTAssertEqual(graph.segments.map(\.kind), [.currentWorktree])
        XCTAssertEqual(graph.segments.first?.commits.map(\.subject), ["cw-1"])
        XCTAssertEqual(graph.trunkAhead?.kind, .trunkAhead(branch: "main"))
        XCTAssertEqual(graph.trunkAhead?.commits.map(\.subject), ["main-ahead-2", "main-ahead-1"])
        XCTAssertEqual(graph.meetingCommit?.subject, "root")
    }

    func testCaseC_oneIntermediateSegment() async throws {
        let repo = try await Topology.caseC()
        let graph = try await Derivations.historyGraph(runner: repo.runner)

        XCTAssertEqual(graph.segments.map(\.kind), [.currentWorktree, .intermediate(branch: "feature")])
        XCTAssertEqual(graph.segments[0].commits.map(\.subject), ["cw-1"])
        XCTAssertEqual(graph.segments[1].commits.map(\.subject), ["feature-2", "feature-1"])
        XCTAssertEqual(graph.branchesBetween, 1)
        XCTAssertNil(graph.trunkAhead)
    }

    func testChained_twoIntermediatesInAncestryOrder() async throws {
        let repo = try await Topology.chained()
        let graph = try await Derivations.historyGraph(runner: repo.runner)

        XCTAssertEqual(graph.segments.map(\.kind),
                       [.currentWorktree, .intermediate(branch: "feature-b"), .intermediate(branch: "feature-a")])
        XCTAssertEqual(graph.segments[1].commits.map(\.subject), ["fb-2", "fb-1"])
        XCTAssertEqual(graph.segments[2].commits.map(\.subject), ["fa-2", "fa-1"])
        XCTAssertEqual(graph.branchesBetween, 2)
    }

    func testTruncation_intermediateCollapsesToTip() async throws {
        let repo = try await Topology.truncatedIntermediate(count: 7)
        let graph = try await Derivations.historyGraph(runner: repo.runner)

        let feature = graph.segments.first { $0.kind == .intermediate(branch: "feature") }
        XCTAssertNotNil(feature)
        XCTAssertEqual(feature?.commits.count, 7, "full run is preserved")
        XCTAssertTrue(feature?.isTruncatable ?? false)
        XCTAssertEqual(feature?.hiddenCount, 6)
        XCTAssertEqual(feature?.collapsedCommits.count, 1, "collapses to just its tip")
        XCTAssertEqual(feature?.collapsedCommits.first?.subject, "feature-7")
    }

    func testCurrentWorktreeIsNeverTruncated() async throws {
        let repo = try await Topology.longCurrentWorktree(count: 7)
        let graph = try await Derivations.historyGraph(runner: repo.runner)

        let cw = graph.segments.first
        XCTAssertEqual(cw?.kind, .currentWorktree)
        XCTAssertEqual(cw?.commits.count, 7)
        XCTAssertFalse(cw?.isTruncatable ?? true, "cw is exempt from truncation")
        XCTAssertEqual(cw?.hiddenCount, 0)
        XCTAssertEqual(cw?.collapsedCommits.count, 7)
    }

    func testMergeCommitsCollapseToFirstParent() async throws {
        let repo = try await Topology.mergeOnCurrentWorktree()
        let graph = try await Derivations.historyGraph(runner: repo.runner)

        let subjects = graph.segments.flatMap { $0.commits.map(\.subject) }
        XCTAssertTrue(subjects.contains("merge-side"))
        XCTAssertTrue(subjects.contains("cw-2"))
        XCTAssertTrue(subjects.contains("cw-1"))
        XCTAssertFalse(subjects.contains("side-1"), "second-parent commit must not appear")
    }

    func testEmptyRepo() async throws {
        let repo = try await Topology.empty()
        let graph = try await Derivations.historyGraph(runner: repo.runner)
        XCTAssertTrue(graph.isEmpty)
        XCTAssertNil(graph.meetingCommit)
    }

    func testDetachedHead() async throws {
        let repo = try await Topology.detached()
        let graph = try await Derivations.historyGraph(runner: repo.runner)
        XCTAssertTrue(graph.isDetached)
        XCTAssertFalse(graph.isEmpty)
    }

    func testOnTrunk() async throws {
        let repo = try await Topology.onTrunk()
        let graph = try await Derivations.historyGraph(runner: repo.runner)
        XCTAssertTrue(graph.isOnTrunk)
        XCTAssertTrue(graph.segments.isEmpty, "no divergence, so no cw commits")
        XCTAssertNil(graph.trunkAhead)
        XCTAssertEqual(graph.meetingCommit?.subject, "root-2")
    }

    func testUncommittedChangesFlag() async throws {
        let repo = try await Topology.caseA()
        try repo.writeFile("cw1.txt", "dirty")
        let graph = try await Derivations.historyGraph(runner: repo.runner)
        XCTAssertTrue(graph.hasUncommittedChanges)
    }
}
