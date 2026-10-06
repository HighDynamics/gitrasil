import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

/// These run against real repositories and real FSEvents, so the waits are generous; each test
/// waits for the outcome it expects rather than for a fixed time where it can.
@MainActor
final class RepoGraphStoreTests: XCTestCase {

    /// Fixture commits are dated 2026-01-01, so keep every branch "recent" whatever today is.
    private let options = RepoGraphOptions(maxAge: 100 * 365 * 24 * 3600)

    private func repo() async throws -> FixtureRepo {
        let r = try FixtureRepo()
        try await r.initRepo()
        try await r.commitFile("root.txt", "0", message: "root")
        try await r.commitFile("m1.txt", "1", message: "m1")
        return r
    }

    /// Polls until `condition` holds or `timeout` passes; returns whether it held.
    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func testStartDerivesTheRepoGraph() async throws {
        let repo = try await repo()
        let store = RepoGraphStore(repositoryURL: repo.url, options: options)
        defer { store.stop() }

        await store.start()

        XCTAssertEqual(store.deriveCount, 1)
        XCTAssertEqual(store.graph?.trunkName, "main")
        XCTAssertNil(store.lastError)
    }

    func testRefreshSkipsTheDeriveWhenNoRefMoved() async throws {
        let repo = try await repo()
        let store = RepoGraphStore(repositoryURL: repo.url, options: options)

        await store.refresh()
        await store.refresh()
        XCTAssertEqual(store.deriveCount, 1, "the ref fingerprint is unchanged")

        try await repo.commitFile("m2.txt", "2", message: "m2")
        await store.refresh()
        XCTAssertEqual(store.deriveCount, 2)
        XCTAssertEqual(store.graph?.trunk.first?.subject, "m2")
    }

    func testABurstOfRefChangesIsOneDerive() async throws {
        let repo = try await repo()
        let store = RepoGraphStore(repositoryURL: repo.url, options: options, settle: .milliseconds(600))
        defer { store.stop() }
        await store.start()

        // A checkout, commit, checkout burst: several ref writes, one settled derive.
        try await repo.createBranch("feature")
        try await repo.commitFile("f1.txt", "1", message: "f1")
        try await repo.checkout("main")

        let derived = await waitFor(5) { store.deriveCount >= 2 }
        XCTAssertTrue(derived, "the burst is picked up")
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(store.deriveCount, 2, "the whole burst is one derive")
        XCTAssertEqual(store.graph?.branches.first?.commits.map(\.subject), ["f1"])
    }

    func testAWorkingTreeChangeDerivesNothing() async throws {
        let repo = try await repo()
        let store = RepoGraphStore(repositoryURL: repo.url, options: options, settle: .milliseconds(200))
        defer { store.stop() }
        await store.start()

        try repo.writeFile("scratch.txt", "edit")
        _ = try await repo.git(["add", "scratch.txt"])   // writes the index, not a ref

        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(store.deriveCount, 1)
    }

    func testAPausedStoreCatchesUpOnResume() async throws {
        let repo = try await repo()
        let store = RepoGraphStore(repositoryURL: repo.url, options: options, settle: .milliseconds(200))
        defer { store.stop() }
        await store.start()

        store.isPaused = true
        try await repo.commitFile("m2.txt", "2", message: "m2")
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(store.deriveCount, 1, "nothing derives while paused")

        store.isPaused = false
        let derived = await waitFor(5) { store.deriveCount == 2 }
        XCTAssertTrue(derived, "resuming runs one catch-up derive")
        XCTAssertEqual(store.graph?.trunk.first?.subject, "m2")
    }

    func testRefPathFilter() {
        for path in ["/r/.git/HEAD", "/r/.git/HEAD.lock", "/r/.git/packed-refs", "/r/.git/refs/heads/main",
                     "/r/.git/refs/heads/feature/a.lock", "/r/.git/worktrees/wt/HEAD",
                     "/r/.git/reftable/tables.list", "/r/.git/reftable/tables.list.lock",
                     "/r/.git/reftable/0x000000000001-0x000000000002-1a2b3c4d.ref",
                     "/r/.git/worktrees/wt/reftable/tables.list"] {
            XCTAssertTrue(RepoGraphStore.isRefPath(path), path)
        }
        for path in ["/r/.git/index", "/r/.git/index.lock", "/r/.git/objects/ab/cdef", "/r/.git/FETCH_HEAD",
                     "/r/.git/ORIG_HEAD", "/r/.git/logs/HEAD", "/r/.git/worktrees/wt/index"] {
            XCTAssertFalse(RepoGraphStore.isRefPath(path), path)
        }
    }

    func testAPauseWhileSettlingDerivesNothingUntilResume() async throws {
        let repo = try await repo()
        let store = RepoGraphStore(repositoryURL: repo.url, options: options, settle: .milliseconds(300))
        await store.refresh()

        try await repo.commitFile("m2.txt", "2", message: "m2")
        store.refsChanged()
        store.isPaused = true
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(store.deriveCount, 1, "the settle timer that was pending derives nothing while paused")

        store.isPaused = false
        let derived = await waitFor(5) { store.deriveCount == 2 }
        XCTAssertTrue(derived, "resuming catches up")
        XCTAssertEqual(store.graph?.trunk.first?.subject, "m2")
    }

    func testAMissingRepositoryIsPickedUpOnTheHourlyTick() async throws {
        let parent = try FixtureRepo()
        let store = RepoGraphStore(repositoryURL: parent.url.appendingPathComponent("later"), options: options,
                                   settle: .milliseconds(200))
        defer { store.stop() }
        await store.start()
        XCTAssertNil(store.graph)
        XCTAssertNotNil(store.lastError)

        try await parent.git(["init", "-q", "-b", "main", "later"])
        try await parent.git(["-C", "later", "commit", "-q", "--allow-empty", "-m", "root"])
        await store.tick()
        XCTAssertEqual(store.graph?.trunk.first?.subject, "root")
        XCTAssertNil(store.lastError)

        // Watched from then on.
        try await parent.git(["-C", "later", "commit", "-q", "--allow-empty", "-m", "m1"])
        let derived = await waitFor(5) { store.graph?.trunk.first?.subject == "m1" }
        XCTAssertTrue(derived, "a commit after the tick is picked up")
    }

    func testABranchAgeingPastTheCutoffGoesOnTheNextDay() async throws {
        let repo = try await repo()
        try await repo.createBranch("feature")
        try await repo.commitFile("f1.txt", "1", message: "f1")
        try await repo.checkout("main")
        let committed = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        let clock = TestClock(committed.addingTimeInterval(5 * 86_400))
        let store = RepoGraphStore(repositoryURL: repo.url, options: RepoGraphOptions(maxAge: 10 * 86_400),
                                   now: { clock.date })

        await store.tick()
        XCTAssertEqual(store.graph?.branches.map(\.name), ["feature"])
        await store.tick()
        XCTAssertEqual(store.deriveCount, 1, "the same day with no ref moved is one derive")

        clock.date = committed.addingTimeInterval(20 * 86_400)
        await store.tick()
        XCTAssertEqual(store.deriveCount, 2)
        XCTAssertEqual(store.graph?.branches.map(\.name), [], "the branch aged out without a ref moving")
    }

    func testAReftableRepositoryIsWatched() async throws {
        let repo = try FixtureRepo()
        do {
            try await repo.git(["init", "-q", "-b", "main", "--ref-format=reftable"])
        } catch {
            throw XCTSkip("this git has no reftable backend")
        }
        try await repo.commitFile("root.txt", "0", message: "root")
        let store = RepoGraphStore(repositoryURL: repo.url, options: options, settle: .milliseconds(200))
        defer { store.stop() }
        await store.start()
        XCTAssertEqual(store.graph?.trunk.first?.subject, "root")

        try await repo.commitFile("m1.txt", "1", message: "m1")
        let derived = await waitFor(5) { store.graph?.trunk.first?.subject == "m1" }
        XCTAssertTrue(derived, "a commit in a reftable repository is picked up")
    }
}

/// A clock a test can move.
private final class TestClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}
