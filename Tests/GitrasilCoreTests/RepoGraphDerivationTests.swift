import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class RepoGraphDerivationTests: XCTestCase {

    /// Fixture commits are dated 2026-01-01 00:00:NN; "now" a day later keeps every branch recent.
    private let soon = ISO8601DateFormatter().date(from: "2026-01-02T00:00:00Z")!
    /// Half a year on, every branch is stale.
    private let later = ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!

    private func branch(_ graph: RepoGraph, _ name: String) -> RepoGraph.Branch? {
        graph.branches.first { $0.name == name }
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

        XCTAssertEqual(graph.trunkName, "main")
        XCTAssertEqual(graph.trunk.map(\.subject), ["m4", "m3", "m2"], "newest first; the oldest anchors the bottom")
        XCTAssertTrue(graph.branches.isEmpty)
        XCTAssertEqual(graph.checkedOutBranches, ["main"])
    }

    func testIsWholeRepoNotRelativeToTheCheckedOutBranch() async throws {
        let repo = try await trunkRepo()
        try await repo.git(["checkout", "-q", "-b", "feature", "HEAD~2"]) // off m2
        try await repo.commitFile("f1.txt", "1", message: "f1")

        let graph = try await Derivations.repoGraph(runner: repo.runner, now: soon)

        XCTAssertEqual(graph.trunkName, "main", "trunk stays the spine")
        XCTAssertEqual(graph.trunk.first?.subject, "m4")
        XCTAssertEqual(branch(graph, "feature")?.commits.map(\.subject), ["f1"])
        let m2 = try await repo.sha("main~2")
        XCTAssertEqual(branch(graph, "feature")?.forkBase, m2)
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

        XCTAssertEqual(branch(graph, "feature/a")?.commits.map(\.subject), ["a2", "a1"])
        let mainTip = try await repo.sha("main"), aTip = try await repo.sha("feature/a")
        XCTAssertEqual(branch(graph, "feature/a")?.forkBase, mainTip)
        XCTAssertEqual(branch(graph, "feature/b")?.commits.map(\.subject), ["b1"], "b keeps only its own commit")
        XCTAssertEqual(branch(graph, "feature/b")?.forkBase, aTip)
    }

    func testStaleBranchesAreLeftOutUnlessCheckedOut() async throws {
        let repo = try await trunkRepo()
        try await repo.createBranch("old")
        try await repo.commitFile("o.txt", "1", message: "o1")
        try await repo.checkout("main")
        try await repo.createBranch("current")
        try await repo.commitFile("c.txt", "1", message: "c1") // stays checked out

        let graph = try await Derivations.repoGraph(runner: repo.runner, now: later)

        XCTAssertNil(branch(graph, "old"))
        XCTAssertNotNil(branch(graph, "current"))
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

        XCTAssertEqual(Set(graph.branches.map(\.name)), ["two", "three"])
    }

    func testBranchWithNoOwnCommitsIsABudOnlyWhenItsTipIsDrawn() async throws {
        let repo = try await trunkRepo()
        try await repo.git(["branch", "parked", "main~1"]) // on the spine
        try await repo.git(["branch", "ancient", "main~4"]) // below a 3-commit window

        let graph = try await Derivations.repoGraph(
            runner: repo.runner, options: RepoGraphOptions(trunkCommits: 3), now: soon)

        let parked = try await repo.sha("main~1")
        XCTAssertEqual(graph.buds[parked], ["parked"])
        XCTAssertFalse(graph.buds.values.contains { $0.contains("ancient") })
    }

    func testPrefersTheLocalTrunkOverItsRemote() async throws {
        let repo = try await trunkRepo()
        try await repo.git(["update-ref", "refs/remotes/origin/main", "main~2"])
        try await repo.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])

        let graph = try await Derivations.repoGraph(runner: repo.runner, now: soon)

        XCTAssertEqual(graph.trunkName, "main")
        XCTAssertEqual(graph.trunk.first?.subject, "m4")
    }

    func testEmptyRepository() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        let graph = try await Derivations.repoGraph(runner: repo.runner, now: soon)
        XCTAssertTrue(graph.isEmpty)
    }

    func testCommitsCarryTheirCommitterDate() async throws {
        let repo = try await trunkRepo()
        let graph = try await Derivations.repoGraph(runner: repo.runner, now: soon)
        let committed = try await repo.git(["log", "-1", "--format=%ct"])
        let seconds = try XCTUnwrap(TimeInterval(committed))
        XCTAssertEqual(graph.trunk.first?.date, Date(timeIntervalSince1970: seconds))
    }
}
