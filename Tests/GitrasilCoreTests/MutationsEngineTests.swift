import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class MutationsEngineTests: XCTestCase {

    private func subjects(_ repo: FixtureRepo) async throws -> [String] {
        try await repo.git(["log", "--format=%s"]).split(separator: "\n").map(String.init)
    }

    func testDropMiddleCommit() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.createBranch("cw")
        try await repo.commitFile("b.txt", "b\n", message: "c1")
        let c2 = try await repo.commitFile("c.txt", "c\n", message: "c2")
        try await repo.commitFile("d.txt", "d\n", message: "c3")

        let outcome = try await Mutations.drop(oldest: c2, newest: c2, branch: "cw", runner: repo.runner)
        XCTAssertEqual(outcome, .completed)

        let subs = try await subjects(repo)
        XCTAssertEqual(subs, ["c3", "c1", "root"], "c2 dropped, c3 replayed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("c.txt").path))
    }

    func testUndoRestoresDroppedCommit() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.createBranch("cw")
        let c1 = try await repo.commitFile("b.txt", "b\n", message: "c1")
        try await repo.commitFile("c.txt", "c\n", message: "c2")
        let before = try await repo.sha("HEAD")

        _ = try await Mutations.drop(oldest: c1, newest: c1, branch: "cw", runner: repo.runner)
        let afterDrop = try await repo.sha("HEAD")
        XCTAssertNotEqual(afterDrop, before)

        try await Mutations.undo(branch: "cw", runner: repo.runner)
        let afterUndo = try await repo.sha("HEAD")
        XCTAssertEqual(afterUndo, before, "undo resets to the pre-drop tip")
    }

    func testRebaseOntoTrunk() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.createBranch("cw")
        try await repo.commitFile("cw.txt", "cw\n", message: "cw-1")
        try await repo.checkout("main")
        try await repo.commitFile("m.txt", "m\n", message: "main-1")
        let mainTip = try await repo.sha("main")
        try await repo.checkout("cw")

        let outcome = try await Mutations.rebaseOnto(target: "main", branch: "cw", runner: repo.runner)
        XCTAssertEqual(outcome, .completed)
        let mergeBase = try await repo.git(["merge-base", "main", "HEAD"])
        XCTAssertEqual(mergeBase, mainTip, "cw now sits on main's tip")
        let ahead = try await repo.git(["rev-list", "--count", "main..HEAD"])
        XCTAssertEqual(ahead, "1")
    }

    func testCherryPickBringsCommitIn() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.createBranch("other")
        let pick = try await repo.commitFile("z.txt", "z\n", message: "on-other")
        try await repo.checkout("main")
        try await repo.createBranch("cw")

        let outcome = try await Mutations.cherryPick(oldest: pick, newest: pick, branch: "cw", runner: repo.runner)
        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("z.txt").path))
        let subs = try await subjects(repo)
        XCTAssertEqual(subs.first, "on-other")
    }

    func testDropConflictPausesThenAborts() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "0\n", message: "root")
        try await repo.createBranch("cw")
        let c1 = try await repo.commitFile("a.txt", "1\n", message: "c1")
        try await repo.commitFile("a.txt", "2\n", message: "c2")
        let before = try await repo.sha("HEAD")

        // Dropping c1 forces c2 (which expects a="1") to replay onto a="0" → conflict.
        let outcome = try await Mutations.drop(oldest: c1, newest: c1, branch: "cw", runner: repo.runner)
        XCTAssertEqual(outcome, .conflicted(.rebase))

        try await Mutations.abortOperation(.rebase, runner: repo.runner)
        let afterAbort = try await repo.sha("HEAD")
        XCTAssertEqual(afterAbort, before, "abort returns to the original tip")
        let stillInProgress = try await Derivations.inProgressOperation(runner: repo.runner)
        XCTAssertNil(stillInProgress)
    }

    func testUndoBlockedOnDirtyTree() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.createBranch("cw")
        let c1 = try await repo.commitFile("b.txt", "b\n", message: "c1")
        _ = try await Mutations.drop(oldest: c1, newest: c1, branch: "cw", runner: repo.runner)

        try repo.writeFile("a.txt", "dirty\n")   // dirty the tree
        do {
            try await Mutations.undo(branch: "cw", runner: repo.runner)
            XCTFail("undo must not reset --hard over uncommitted work")
        } catch MutationError.workingTreeDirty {
            // expected — undo blocks like every other mutation
        }
    }

    func testDirtyTreeBlocksMutation() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.createBranch("cw")
        let c1 = try await repo.commitFile("b.txt", "b\n", message: "c1")
        try repo.writeFile("b.txt", "dirty\n")

        do {
            _ = try await Mutations.drop(oldest: c1, newest: c1, branch: "cw", runner: repo.runner)
            XCTFail("should have thrown")
        } catch MutationError.workingTreeDirty {
            // expected
        }
    }

    func testBackupPruningKeepsTen() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.createBranch("cw")

        for _ in 0..<13 { _ = try await Mutations.writeBackup(branch: "cw", runner: repo.runner) }
        let refs = try await Mutations.backupRefs(branch: "cw", runner: repo.runner)
        XCTAssertEqual(refs.count, Mutations.backupsKept)
    }
}
