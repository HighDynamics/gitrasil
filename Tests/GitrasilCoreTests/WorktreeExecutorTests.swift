import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class WorktreeExecutorTests: XCTestCase {

    /// A read enqueued after a slow mutation must not begin until the mutation has finished.
    func testMutationBlocksLaterRead() async throws {
        let runner = RecordingRunner(delay: .milliseconds(80))
        let executor = WorktreeExecutor(runner: runner)

        let mutation = await executor.mutate { try await $0.run(["MUTATION"]) }
        let read = await executor.read(.statuses) { try await $0.run(["READ"]) }

        _ = try await mutation.value
        _ = try await read.value

        let (_, finished) = await runner.snapshot()
        XCTAssertEqual(finished, ["MUTATION", "READ"],
                       "read must finish strictly after the mutation it queued behind")
    }

    /// Two reads of the same kind: the earlier one is superseded and the later one wins.
    func testReadCoalescingNewestWins() async throws {
        let runner = RecordingRunner(delay: .milliseconds(80))
        let executor = WorktreeExecutor(runner: runner)

        let stale = await executor.read(.graph) { try await $0.run(["STALE"]) }
        let fresh = await executor.read(.graph) { try await $0.run(["FRESH"]) }

        // The superseded read is cancelled.
        do {
            _ = try await stale.value
            XCTFail("stale read should have been cancelled")
        } catch is CancellationError {
            // expected
        }

        _ = try await fresh.value
        // The stale op may physically begin before the cancel lands (a benign race against an idle
        // executor), but it must never *finish* — cancellation is checked after the work.
        let (_, finished) = await runner.snapshot()
        XCTAssertTrue(finished.contains("FRESH"), "the newest read must complete")
        XCTAssertFalse(finished.contains("STALE"), "the superseded read must not complete")
    }

    /// Distinct read kinds do not coalesce each other.
    func testDifferentKindsBothRun() async throws {
        let runner = RecordingRunner(delay: .milliseconds(30))
        let executor = WorktreeExecutor(runner: runner)

        let a = await executor.read(.statuses) { try await $0.run(["A"]) }
        let b = await executor.read(.graph) { try await $0.run(["B"]) }

        _ = try await a.value
        _ = try await b.value
        let (_, finished) = await runner.snapshot()
        XCTAssertEqual(Set(finished), ["A", "B"])
    }
}
