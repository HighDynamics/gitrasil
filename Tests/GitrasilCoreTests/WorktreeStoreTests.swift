import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

@MainActor
final class WorktreeStoreTests: XCTestCase {

    func testRefreshPublishesSnapshot() async throws {
        let repo = try await Topology.caseA()
        let store = WorktreeStore(worktreeURL: repo.url)

        XCTAssertNil(store.snapshot, "no snapshot before first refresh")
        await store.refresh()

        XCTAssertNotNil(store.snapshot)
        XCTAssertEqual(store.snapshot?.branch, .branch("cw"))
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.isRefreshing)
    }

    func testRefreshReflectsAChangeOnDisk() async throws {
        let repo = try await Topology.caseA()
        let store = WorktreeStore(worktreeURL: repo.url)

        await store.refresh()
        XCTAssertNil(store.snapshot?.badge, "clean initially")

        try repo.writeFile("cw1.txt", "dirty")
        await store.refresh()
        XCTAssertEqual(store.snapshot?.badge, .modified, "re-derive picks up the working-tree change")
    }

    func testRefreshOnNonRepoSetsError() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitrasil-nonrepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = WorktreeStore(worktreeURL: dir)
        await store.refresh()

        XCTAssertNil(store.snapshot)
        XCTAssertNotNil(store.lastError)
    }
}
