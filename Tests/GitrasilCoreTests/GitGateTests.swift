import XCTest
@testable import GitrasilCore

final class GitGateTests: XCTestCase {

    /// A git command that sleeps: an alias that runs the shell's `sleep`.
    private let hang = ["-c", "alias.hang=!sleep 6", "hang"]

    func testAtMostTheLimitRunAtOnceAndTheRestWaitInOrder() async throws {
        let gate = GitGate(limit: 2)
        try await gate.enter()
        try await gate.enter()

        let order = Order()
        let third = Task { try await gate.enter(); await order.add(3); gate.leave() }
        try await Task.sleep(for: .milliseconds(50))
        let fourth = Task { try await gate.enter(); await order.add(4); gate.leave() }
        try await Task.sleep(for: .milliseconds(50))
        let started = await order.values
        XCTAssertEqual(started, [], "both places are taken")

        gate.leave()
        try await third.value
        gate.leave()
        try await fourth.value
        let finished = await order.values
        XCTAssertEqual(finished, [3, 4])
    }

    func testACancelledWaiterLeavesTheQueueAndHoldsNoPlace() async throws {
        let gate = GitGate(limit: 1)
        try await gate.enter()
        let waiter = Task { try await gate.enter() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("a cancelled wait must throw")
        } catch is CancellationError {}

        gate.leave()
        // The place is free again, not handed to the cancelled waiter.
        let again = Task { try await gate.enter() }
        try await again.value
        gate.leave()
    }

    func testATaskCancelledBeforeItEntersNeverTakesAPlace() async throws {
        let gate = GitGate(limit: 1)
        let task = Task {
            try await Task.sleep(for: .milliseconds(100))
            try await gate.enter()
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("a cancelled task must throw")
        } catch is CancellationError {}
        try await gate.enter()
        gate.leave()
    }

    func testAGitThatOutlivesItsTimeoutIsStoppedAndFreesItsPlace() async throws {
        let gate = GitGate(limit: 1)
        let runner = GitRunner(workdir: FileManager.default.temporaryDirectory, timeout: 0.5, gate: gate)
        let start = Date()
        do {
            _ = try await runner.run(hang)
            XCTFail("it should have timed out")
        } catch GitError.timedOut(_, let seconds) {
            XCTAssertEqual(seconds, 0.5)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4, "stopped at the timeout, not when the command ended")

        // The one place is free, so the next read runs.
        let version = try await runner.run(["--version"])
        XCTAssertEqual(version.status, 0)
    }

    func testCancellingAReadStopsItsGitAndFreesItsPlace() async throws {
        let gate = GitGate(limit: 1)
        let runner = GitRunner(workdir: FileManager.default.temporaryDirectory, timeout: 30, gate: gate)
        let hung = Task { try await runner.run(hang) }
        try await Task.sleep(for: .milliseconds(300))
        let queued = Task { try await runner.run(["--version"]) }
        try await Task.sleep(for: .milliseconds(100))

        let start = Date()
        queued.cancel()
        hung.cancel()
        for task in [hung, queued] {
            do {
                _ = try await task.value
                XCTFail("a cancelled read must throw")
            } catch is CancellationError {}
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)

        let version = try await runner.run(["--version"])
        XCTAssertEqual(version.status, 0, "the place was given back")
    }
}

private actor Order {
    private(set) var values: [Int] = []
    func add(_ value: Int) { values.append(value) }
}
