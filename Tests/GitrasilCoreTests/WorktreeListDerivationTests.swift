import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class WorktreeListDerivationTests: XCTestCase {

    func testSingleWorktreeReportsOneMainEntry() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")

        let list = try await Derivations.worktrees(runner: repo.runner)
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(list[0].isMain)
        XCTAssertEqual(list[0].branch, "main")
        XCTAssertFalse(list[0].isBare)
        XCTAssertFalse(list[0].isDetached)
    }

    func testLinkedWorktreeIsEnumeratedAfterMain() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")

        let wt = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitrasil-wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: wt) }
        try await repo.git(["worktree", "add", wt.path, "-b", "feat"])

        let list = try await Derivations.worktrees(runner: repo.runner)
        XCTAssertEqual(list.count, 2)

        XCTAssertTrue(list[0].isMain, "the repository's original checkout is reported first")
        XCTAssertEqual(list[0].branch, "main")

        XCTAssertFalse(list[1].isMain)
        XCTAssertEqual(list[1].branch, "feat")
        XCTAssertEqual(list[1].path.resolvingSymlinksInPath(), wt.resolvingSymlinksInPath())
        XCTAssertNotNil(list[1].head)
    }

    func testDetachedWorktreeHasNoBranch() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        let root = try await repo.commitFile("a.txt", "a\n", message: "root")

        let wt = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitrasil-wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: wt) }
        // --detach checks out the commit directly, leaving the linked worktree on a detached HEAD.
        try await repo.git(["worktree", "add", "--detach", wt.path, root])

        let list = try await Derivations.worktrees(runner: repo.runner)
        let detached = try XCTUnwrap(list.first { $0.path.resolvingSymlinksInPath() == wt.resolvingSymlinksInPath() })
        XCTAssertTrue(detached.isDetached)
        XCTAssertNil(detached.branch)
        XCTAssertEqual(detached.head, root)
    }
}
