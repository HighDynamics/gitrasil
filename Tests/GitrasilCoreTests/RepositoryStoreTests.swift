import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

@MainActor
final class RepositoryStoreTests: XCTestCase {

    func testCreateThenRemoveWorktreeUpdatesTheList() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")

        let store = RepositoryStore(anchorURL: repo.url)
        await store.start()
        defer { store.stop() }
        XCTAssertEqual(store.worktrees.count, 1)

        let wt = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitrasil-wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: wt) }

        await store.createWorktree(newBranch: "feature", base: "main", at: wt)
        XCTAssertNil(store.actionError)
        XCTAssertEqual(store.worktrees.count, 2)
        XCTAssertTrue(store.worktrees.contains { $0.branch == "feature" })
        XCTAssertEqual(store.selectedPath?.resolvingSymlinksInPath(), wt.resolvingSymlinksInPath(),
                       "the new worktree is selected")

        let created = try XCTUnwrap(store.worktrees.first { $0.branch == "feature" })
        await store.removeWorktree(created)
        XCTAssertNil(store.actionError)
        XCTAssertEqual(store.worktrees.count, 1)
        XCTAssertFalse(store.worktrees.contains { $0.branch == "feature" })
        XCTAssertEqual(store.selectedPath, store.worktrees.first?.path, "selection fell back after removal")
    }

    func testCreateWorktreeSurfacesGitError() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")

        let store = RepositoryStore(anchorURL: repo.url)
        await store.start()
        defer { store.stop() }

        let wt = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitrasil-wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: wt) }
        // `main` is already checked out in the fixture — a second checkout must fail and surface.
        await store.createWorktree(newBranch: nil, base: "main", at: wt)
        XCTAssertNotNil(store.actionError)
        XCTAssertEqual(store.worktrees.count, 1)
    }
}
