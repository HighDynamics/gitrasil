import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class RepoGraphDerivationTests: XCTestCase {

    /// Fixture commits are dated 2026-01-01 00:00:NN; "now" a day later keeps every branch recent.
    private let soon = ISO8601DateFormatter().date(from: "2026-01-02T00:00:00Z")!
    /// Half a year on, every branch is stale.
    private let later = ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!

    private func lane(_ graph: HistoryGraph, _ branch: String) -> GraphSegment? {
        graph.revealedLanes.first { $0.kind == .revealed(branch: branch) }
    }

    /// main: root, m1, m2, m3, m4.
    private func trunkRepo() async throws -> FixtureRepo {
        let r = try FixtureRepo()
        try await r.initRepo()
        try await r.commitFile("root.txt", "0", message: "root")
        for i in 1...4 { try await r.commitFile("m\(i).txt", "\(i)", message: "m\(i)") }
        return r
    }

    func testSpineIsTrunksRecentHistoryWithTheOldestAsAnchor() async throws {
        let repo = try await trunkRepo()
        let graph = try await Derivations.repoGraph(
            runner: repo.runner, options: RepoGraphOptions(trunkCommits: 3), now: soon)

        XCTAssertEqual(graph.segments.map(\.kind), [.trunk(branch: "main")])
        XCTAssertEqual(graph.segments.first?.commits.map(\.subject), ["m4", "m3"])
        XCTAssertEqual(graph.meetingCommit?.subject, "m2", "the oldest spine commit anchors the bottom")
        XCTAssertFalse(graph.segments[0].isTruncatable, "the trunk spine is never collapsed")
        XCTAssertTrue(graph.revealedLanes.isEmpty)
        XCTAssertEqual(graph.checkedOutBranches, ["main"])
    }

    func testIsWholeRepoNotRelativeToTheCheckedOutBranch() async throws {
        let repo = try await trunkRepo()
        try await repo.git(["checkout", "-q", "-b", "feature", "HEAD~2"])   // off m2
        try await repo.commitFile("f1.txt", "1", message: "f1")

        let graph = try await Derivations.repoGraph(runner: repo.runner, now: soon)

        XCTAssertEqual(graph.segments.first?.kind, .trunk(branch: "main"), "trunk stays the spine")
        XCTAssertEqual(graph.segments.first?.commits.first?.subject, "m4")
        XCTAssertEqual(lane(graph, "feature")?.commits.map(\.subject), ["f1"])
        let m2 = try await repo.sha("main~2")
        XCTAssertEqual(lane(graph, "feature")?.forkBase, m2)
        XCTAssertEqual(graph.checkedOutBranches, ["feature"])
    }

    func testBranchOffABranchStacksOntoItsBase() async throws {
        let repo = try await trunkRepo()
        try await repo.createBranch("feature/a")
        try await repo.commitFile("a1.txt", "1", message: "a1")
        try await repo.commitFile("a2.txt", "2", message: "a2")
        try await repo.createBranch("feature/b")
        try await repo.commitFile("b1.txt", "1", message: "b1")
        try await repo.checkout("main")

        let graph = try await Derivations.repoGraph(runner: repo.runner, now: soon)

        XCTAssertEqual(lane(graph, "feature/a")?.commits.map(\.subject), ["a2", "a1"])
        let mainTip = try await repo.sha("main"), aTip = try await repo.sha("feature/a")
        XCTAssertEqual(lane(graph, "feature/a")?.forkBase, mainTip)
        XCTAssertEqual(lane(graph, "feature/b")?.commits.map(\.subject), ["b1"], "b keeps only its own commit")
        XCTAssertEqual(lane(graph, "feature/b")?.forkBase, aTip)

        // Laid out, b continues a's lane, and a forks off trunk's tip into its own lane.
        let rows = GraphLayout.rows(for: graph, expanded: true)
        let laneOf = { (subject: String) in rows.first { $0.commit?.subject == subject }?.lane }
        XCTAssertEqual(laneOf("b1"), laneOf("a1"))
        XCTAssertNotEqual(laneOf("a1"), laneOf("m4"), "a branch off trunk's tip forks; trunk doesn't continue into it")
    }

    func testStaleBranchesAreLeftOutUnlessCheckedOut() async throws {
        let repo = try await trunkRepo()
        try await repo.createBranch("old")
        try await repo.commitFile("o.txt", "1", message: "o1")
        try await repo.checkout("main")
        try await repo.createBranch("current")
        try await repo.commitFile("c.txt", "1", message: "c1")   // stays checked out

        let graph = try await Derivations.repoGraph(runner: repo.runner, now: later)

        XCTAssertNil(lane(graph, "old"))
        XCTAssertNotNil(lane(graph, "current"))
    }

    func testBranchCapKeepsTheMostRecent() async throws {
        let repo = try await trunkRepo()
        for name in ["one", "two", "three"] {
            try await repo.checkout("main")
            try await repo.createBranch(name)
            try await repo.commitFile("\(name).txt", "1", message: name)
        }
        try await repo.checkout("main")

        let graph = try await Derivations.repoGraph(
            runner: repo.runner, options: RepoGraphOptions(maxBranches: 2), now: soon)

        XCTAssertEqual(Set(graph.revealedLanes.compactMap(\.branchLabel)), ["two", "three"])
    }

    func testBranchWithNoOwnCommitsIsAPillOnlyWhenItsTipIsDrawn() async throws {
        let repo = try await trunkRepo()
        try await repo.git(["branch", "parked", "main~1"])   // on the spine
        try await repo.git(["branch", "ancient", "main~4"])  // below a 3-commit window

        let graph = try await Derivations.repoGraph(
            runner: repo.runner, options: RepoGraphOptions(trunkCommits: 3), now: soon)

        let parked = try await repo.sha("main~1")
        XCTAssertEqual(graph.revealedPointers[parked], ["parked"])
        XCTAssertFalse(graph.revealedPointers.values.contains { $0.contains("ancient") })
    }

    func testPrefersTheLocalTrunkOverItsRemote() async throws {
        let repo = try await trunkRepo()
        try await repo.git(["update-ref", "refs/remotes/origin/main", "main~2"])
        try await repo.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])

        let graph = try await Derivations.repoGraph(runner: repo.runner, now: soon)

        XCTAssertEqual(graph.segments.first?.kind, .trunk(branch: "main"))
        XCTAssertEqual(graph.segments.first?.commits.first?.subject, "m4")
    }

    func testEmptyRepository() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        let graph = try await Derivations.repoGraph(runner: repo.runner, now: soon)
        XCTAssertTrue(graph.isEmpty)
    }
}
