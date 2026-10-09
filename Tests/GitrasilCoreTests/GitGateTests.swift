import XCTest
@testable import GitrasilCore

/// The gate and the runner's timeout and cancellation. Nothing here depends on how fast the machine is: a
/// test waits for a state (a place taken, a waiter queued) rather than for a time, the margins are tens of
/// seconds, and the hanging process is `/bin/sleep` itself, so stopping it leaves nothing behind.
final class GitGateTests: XCTestCase {

    private let sleep = ["/bin/sleep"], quick = ["/usr/bin/true"]
    private var folder: URL { FileManager.default.temporaryDirectory }

    /// Polls (up to 30 s) until `condition` holds.
    private func eventually(_ message: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    func testAtMostTheLimitRunAtOnceAndTheRestWaitInOrder() async throws {
        let gate = GitGate(limit: 2)
        try await gate.enter()
        try await gate.enter()

        let order = Order()
        let third = Task { try await gate.enter(); await order.add(3); gate.leave() }
        await eventually("the third waits") { gate.occupancy.waiting == 1 }
        let fourth = Task { try await gate.enter(); await order.add(4); gate.leave() }
        await eventually("the fourth waits") { gate.occupancy.waiting == 2 }
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
        await eventually("the waiter queues") { gate.occupancy.waiting == 1 }
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("a cancelled wait must throw")
        } catch is CancellationError {}
        XCTAssertEqual(gate.occupancy.waiting, 0)

        gate.leave()
        XCTAssertEqual(gate.occupancy.free, 1, "the place is free again, not handed to the cancelled waiter")
    }

    func testATaskCancelledBeforeItEntersNeverTakesAPlace() async throws {
        let gate = GitGate(limit: 1)
        let task = Task { () throws in
            while !Task.isCancelled { try await Task.sleep(for: .milliseconds(5)) }
            try await gate.enter()
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("a cancelled task must throw")
        } catch is CancellationError {}
        XCTAssertEqual(gate.occupancy.free, 1)
    }

    func testAProcessThatOutlivesItsTimeoutIsStoppedAndFreesItsPlace() async throws {
        let gate = GitGate(limit: 1, backoff: 0)
        let hung = GitRunner(workdir: folder, timeout: 0.3, gate: gate, command: sleep)
        do {
            _ = try await hung.run(["600"])
            XCTFail("it should have timed out")
        } catch GitError.timedOut(_, let seconds) {
            XCTAssertEqual(seconds, 0.3)
        }
        XCTAssertEqual(gate.occupancy.free, 1, "the place is back")

        let next = try await GitRunner(workdir: folder, timeout: 30, gate: gate, command: quick).run([])
        XCTAssertEqual(next.status, 0)
    }

    func testCancellingReadsStopsTheRunningOneAndDropsTheQueuedOne() async throws {
        let gate = GitGate(limit: 1)
        let hung = Task { try await GitRunner(workdir: folder, timeout: 600, gate: gate, command: sleep).run(["600"]) }
        await eventually("the first holds the place") { gate.occupancy.free == 0 }
        let queued = Task { try await GitRunner(workdir: folder, timeout: 600, gate: gate, command: quick).run([]) }
        await eventually("the second queues") { gate.occupancy.waiting == 1 }

        queued.cancel()
        hung.cancel()
        for task in [hung, queued] {
            do {
                _ = try await task.value
                XCTFail("a cancelled read must throw")
            } catch is CancellationError {}
        }
        XCTAssertEqual(gate.occupancy.free, 1, "both places went back")
        XCTAssertEqual(gate.occupancy.waiting, 0)
    }

    func testARepositoryThatTimedOutIsLeftAloneUntilItsBackOffEnds() async throws {
        let gate = GitGate(limit: 2, backoff: 3600)
        let hung = GitRunner(workdir: folder, timeout: 0.2, gate: gate, command: sleep)
        do { _ = try await hung.run(["600"]) } catch GitError.timedOut {}

        // Tried again at once, it isn't launched: it fails fast, whatever it would have run.
        let again = GitRunner(workdir: folder, timeout: 30, gate: gate, command: quick)
        do {
            _ = try await again.run([])
            XCTFail("it should be backing off")
        } catch GitError.backingOff(let retryAt) {
            XCTAssertGreaterThan(retryAt, Date())
        }
        // Another repository is unaffected.
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        let fine = try await GitRunner(workdir: other, timeout: 30, gate: gate, command: quick).run([])
        XCTAssertEqual(fine.status, 0)
    }

    func testASuccessAfterTheBackOffForgetsTheTimeouts() async throws {
        let gate = GitGate(limit: 1, backoff: 0.2)
        do { _ = try await GitRunner(workdir: folder, timeout: 0.1, gate: gate, command: sleep).run(["600"]) } catch GitError.timedOut {}
        let ready = Date().addingTimeInterval(0.2)
        while Date() < ready { try await Task.sleep(for: .milliseconds(20)) }

        let tried = try await GitRunner(workdir: folder, timeout: 30, gate: gate, command: quick).run([])
        XCTAssertEqual(tried.status, 0)
        try gate.checkBackoff(folder.path)
    }

    func testManyCallsCancelledAtRandomLeaveEveryPlaceFree() async throws {
        let gate = GitGate(limit: 3)
        let tasks = (0..<120).map { _ in
            Task { try await GitRunner(workdir: folder, timeout: 30, gate: gate, command: quick).run([]) }
        }
        for (index, task) in tasks.enumerated() where index % 2 == 0 {
            if index % 4 == 0 { try await Task.sleep(for: .milliseconds(Int.random(in: 0...3))) }
            task.cancel()
        }
        for task in tasks { _ = try? await task.value }
        XCTAssertEqual(gate.occupancy.free, 3)
        XCTAssertEqual(gate.occupancy.waiting, 0)
    }

    func testOutputIsReadWhileTheProcessRuns() async throws {
        // More than a pipe holds (64 KB), so a reader that waited for the exit would deadlock.
        let gate = GitGate(limit: 1)
        let script = "head -c 300000 /dev/zero; head -c 100000 /dev/zero >&2"
        let runner = GitRunner(workdir: folder, timeout: 60, gate: gate, command: ["/bin/sh", "-c", script])
        let output = try await runner.run([])
        XCTAssertEqual(output.stdout.count, 300_000)
        XCTAssertEqual(output.stderr.count, 100_000)
    }
}

private actor Order {
    private(set) var values: [Int] = []
    func add(_ value: Int) { values.append(value) }
}
