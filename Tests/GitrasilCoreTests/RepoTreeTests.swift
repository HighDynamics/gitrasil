import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class RepoTreeTests: XCTestCase {

    /// Fixture commits are dated 2026-01-01; "now" a day later keeps every branch recent.
    private let soon = ISO8601DateFormatter().date(from: "2026-01-02T00:00:00Z")!

    /// main: root, m1…m4. feature/a off m2 (a1, a2); feature/b off a1 (b1); parked at m3 with no
    /// commits of its own; feature/a checked out in a second worktree.
    private func tree() async throws -> (RepoTree, FixtureRepo) {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("root.txt", "0", message: "root")
        for i in 1...4 { try await repo.commitFile("m\(i).txt", "\(i)", message: "m\(i)") }
        try await repo.git(["checkout", "-q", "-b", "feature/a", "main~2"])
        try await repo.commitFile("a1.txt", "1", message: "a1")
        try await repo.commitFile("a2.txt", "2", message: "a2")
        try await repo.git(["checkout", "-q", "-b", "feature/b", "feature/a~1"])
        try await repo.commitFile("b1.txt", "1", message: "b1")
        try await repo.git(["branch", "parked", "main~1"])
        try await repo.checkout("main")
        try await repo.git(["worktree", "add", "-q", repo.url.appendingPathComponent("wt-a").path, "feature/a"])
        let graph = try await Derivations.repoGraph(runner: repo.runner, now: soon)
        return (RepoTree(graph: graph), repo)
    }

    func testTrunkIsTheSpineOldestFirst() async throws {
        let (tree, repo) = try await tree()
        XCTAssertEqual(tree.trunkName, "main")
        let root = try await repo.sha("main~4"), tip = try await repo.sha("main")
        XCTAssertEqual(tree.trunk.first?.sha, root)
        XCTAssertEqual(tree.trunk.last?.sha, tip)
        XCTAssertEqual(tree.trunk.count, 5)
        XCTAssertTrue(tree.isTrunkCheckedOut)
    }

    func testLimbsForkFromTheTrunkOrFromEachOther() async throws {
        let (tree, repo) = try await tree()
        let limb = { (name: String) in tree.limbs.first { $0.name == name } }

        let a = try XCTUnwrap(limb("feature/a"))
        XCTAssertEqual(a.commits.count, 2)
        let a1 = try await repo.sha("feature/a~1")
        XCTAssertEqual(a.commits.first?.sha, a1, "oldest first")
        XCTAssertEqual(a.parent, .trunk(node: 3), "forks from m2, the trunk's third commit")
        XCTAssertTrue(a.isCheckedOut)

        let b = try XCTUnwrap(limb("feature/b"))
        let aIndex = try XCTUnwrap(tree.limbs.firstIndex { $0.name == "feature/a" })
        XCTAssertEqual(b.parent, .limb(index: aIndex, node: 1), "a sub-branch off a's first commit")
        XCTAssertGreaterThan(tree.limbs.firstIndex { $0.name == "feature/b" }!, aIndex, "after its parent")
        XCTAssertFalse(b.isCheckedOut)

        let parked = try XCTUnwrap(limb("parked"))
        XCTAssertTrue(parked.isBud)
        XCTAssertEqual(parked.parent, .trunk(node: 4), "a bud on m3")
    }

    func testCommitCountsCountBudsAsOne() async throws {
        let (tree, _) = try await tree()
        XCTAssertEqual(tree.commitCounts, ["main": 5, "feature/a": 2, "feature/b": 1, "parked": 1])
    }
}
