import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class WorktreeLifecycleTests: XCTestCase {

    private func tempPath() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gitrasil-wt-\(UUID().uuidString)")
    }

    func testAddWorktreeWithNewBranchRecordsLineage() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        let wt = tempPath(); defer { try? FileManager.default.removeItem(at: wt) }

        try await Mutations.addWorktree(at: wt, newBranch: "feature", base: "main", source: "main", runner: repo.runner)

        let list = try await Derivations.worktrees(runner: repo.runner)
        let created = list.first { $0.branch == "feature" }
        XCTAssertNotNil(created)
        XCTAssertEqual(created?.path.resolvingSymlinksInPath(), wt.resolvingSymlinksInPath())
        let parent = try await Mutations.parentWorktreeBranch(of: "feature", runner: repo.runner)
        XCTAssertEqual(parent, "main")
    }

    func testAddWorktreeWithExistingBranch() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.git(["branch", "other"])
        let wt = tempPath(); defer { try? FileManager.default.removeItem(at: wt) }

        try await Mutations.addWorktree(at: wt, newBranch: nil, base: "other", source: "main", runner: repo.runner)

        let list = try await Derivations.worktrees(runner: repo.runner)
        XCTAssertTrue(list.contains { $0.branch == "other" })
    }

    func testRemoveWorktreeClearsLineage() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        let wt = tempPath(); defer { try? FileManager.default.removeItem(at: wt) }
        try await Mutations.addWorktree(at: wt, newBranch: "feature", base: "main", source: "main", runner: repo.runner)
        let before = try await Mutations.parentWorktreeBranch(of: "feature", runner: repo.runner)
        XCTAssertEqual(before, "main")

        try await Mutations.removeWorktree(at: wt, branch: "feature", force: false, runner: repo.runner)

        let list = try await Derivations.worktrees(runner: repo.runner)
        XCTAssertFalse(list.contains { $0.branch == "feature" })
        let after = try await Mutations.parentWorktreeBranch(of: "feature", runner: repo.runner)
        XCTAssertNil(after)
    }

    func testBackfillLineageAdoptsReflogSource() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.git(["branch", "parent-branch"])
        try await repo.git(["branch", "child", "parent-branch"])   // reflog: Created from parent-branch

        let before = try await Mutations.parentWorktreeBranch(of: "child", runner: repo.runner)
        XCTAssertNil(before)
        let adopted = try await Mutations.backfillLineage(for: "child", runner: repo.runner)
        XCTAssertEqual(adopted, "parent-branch")
        let after = try await Mutations.parentWorktreeBranch(of: "child", runner: repo.runner)
        XCTAssertEqual(after, "parent-branch")
    }

    func testBackfillLineageIgnoresShaSource() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        let root = try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.git(["branch", "child", root])   // reflog: Created from <sha> — ambiguous, skip

        let adopted = try await Mutations.backfillLineage(for: "child", runner: repo.runner)
        XCTAssertNil(adopted)
    }

    func testAddWorktreeFailsForAlreadyCheckedOutBranch() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        let wt = tempPath(); defer { try? FileManager.default.removeItem(at: wt) }
        do {
            // `main` is checked out in the fixture's own worktree; a second checkout must fail.
            try await Mutations.addWorktree(at: wt, newBranch: nil, base: "main", source: nil, runner: repo.runner)
            XCTFail("expected failure adding a worktree on an already-checked-out branch")
        } catch MutationError.failed {
            // expected — surfaced as a user-facing message
        }
    }
}
