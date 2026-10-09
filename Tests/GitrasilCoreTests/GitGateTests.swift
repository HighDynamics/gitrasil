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
        } catch GitError.timedOut(_, let seconds, let retryAt) {
            XCTAssertEqual(seconds, 0.3)
            XCTAssertLessThanOrEqual(retryAt, Date(), "no back-off: it may be tried again at once")
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

    // MARK: back-off with several callers

    private enum Outcome { case answered, timedOut, backingOff, other }

    private func outcome(of task: Task<GitOutput, Error>) async -> Outcome {
        do {
            _ = try await task.value
            return .answered
        } catch GitError.timedOut {
            return .timedOut
        } catch GitError.backingOff {
            return .backingOff
        } catch {
            return .other
        }
    }

    private func outcomes(_ tasks: [Task<GitOutput, Error>]) async -> [Outcome] {
        var all: [Outcome] = []
        for task in tasks { all.append(await outcome(of: task)) }
        return all
    }

    func testCallsQueuedBehindOneThatTimesOutDontEachWaitOutTheirOwnTimeout() async {
        let gate = GitGate(limit: 1, backoff: 3600)
        let hung = GitRunner(workdir: folder, timeout: 0.5, gate: gate, command: sleep)
        let tasks = (0..<4).map { _ in Task { try await hung.run(["600"]) } }
        let results = await outcomes(tasks)
        // Whichever got the place first timed out; the others, checked again once they held a place (or
        // before they queued), were not run at all.
        XCTAssertEqual(results.filter { $0 == .timedOut }.count, 1, "\(results)")
        XCTAssertEqual(results.filter { $0 == .backingOff }.count, 3, "\(results)")
        XCTAssertEqual(gate.failureCount(folder.path), 1)
        XCTAssertEqual(gate.occupancy.free, 1)
    }

    func testCallsRunningTogetherWhenOneRepositoryHangsCountOneTimeout() async {
        let gate = GitGate(limit: 4, backoff: 3600)
        let hung = GitRunner(workdir: folder, timeout: 0.3, gate: gate, command: sleep)
        let tasks = (0..<4).map { _ in Task { try await hung.run(["600"]) } }
        let results = await outcomes(tasks)
        XCTAssertGreaterThanOrEqual(results.filter { $0 == .timedOut }.count, 1, "\(results)")
        XCTAssertTrue(results.allSatisfy { $0 == .timedOut || $0 == .backingOff }, "\(results)")
        XCTAssertEqual(gate.failureCount(folder.path), 1, "one outage is one failure, not one per call")
    }

    func testWhenTheBackOffEndsOnlyOneProbeGoesThrough() async throws {
        let gate = GitGate(limit: 4, backoff: 0.3)
        let hung = GitRunner(workdir: folder, timeout: 0.5, gate: gate, command: sleep)
        do { _ = try await GitRunner(workdir: folder, timeout: 0.1, gate: gate, command: sleep).run(["600"]) } catch GitError.timedOut {}
        let key = folder.path
        await eventually("the back-off ends") { (try? gate.checkBackoff(key)) != nil }

        let tasks = (0..<4).map { _ in Task { try await hung.run(["600"]) } }
        let results = await outcomes(tasks)
        XCTAssertEqual(results.filter { $0 == .timedOut }.count, 1, "the probe: \(results)")
        XCTAssertEqual(results.filter { $0 == .backingOff }.count, 3, "\(results)")
        XCTAssertEqual(gate.failureCount(key), 2, "one more failure for the probe, none for the others")
    }

    func testAProbeThatAnswersEndsTheBackOffAndACancelledOneLetsTheNextTry() async throws {
        let gate = GitGate(limit: 2, backoff: 0.2)
        do { _ = try await GitRunner(workdir: folder, timeout: 0.1, gate: gate, command: sleep).run(["600"]) } catch GitError.timedOut {}
        let key = folder.path
        await eventually("the back-off ends") { (try? gate.checkBackoff(key)) != nil }

        let probe = Task { try await GitRunner(workdir: folder, timeout: 600, gate: gate, command: sleep).run(["600"]) }
        await eventually("the probe is out") { (try? gate.checkBackoff(key)) == nil }
        probe.cancel()
        _ = await outcome(of: probe)
        XCTAssertEqual(gate.failureCount(key), 1, "a cancelled probe counts nothing")

        let next = try await GitRunner(workdir: folder, timeout: 30, gate: gate, command: quick).run([])
        XCTAssertEqual(next.status, 0)
        XCTAssertEqual(gate.failureCount(key), 0, "an answer forgives the failures")
    }

    // MARK: pipes held by a child, descriptors, messages

    func testAChildHoldingThePipesAfterGitExitsDoesntMakeTheCallTimeOut() async throws {
        let gate = GitGate(limit: 1)
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            // The background child is ours to clean up: no orphaned `sleep`.
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: pidFile)
        }
        // Exits 0 at once, leaving a `sleep` that keeps the stdout and stderr pipes open for 12 s.
        let script = "sleep 12 & echo $! > \"$1\"; echo done"
        let runner = GitRunner(workdir: folder, timeout: 8, gate: gate, command: ["/bin/sh", "-c", script, "sh"], pipeGrace: 0.3)
        let output = try await runner.run([pidFile.path])
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.trimmedStdout, "done")
        XCTAssertEqual(gate.failureCount(folder.path), 0, "an answer, not a timeout")
    }

    private func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }

    func testCallsOfEveryKindLeaveNoDescriptorsOpen() async throws {
        let gate = GitGate(limit: 5, backoff: 0)
        _ = try await GitRunner(workdir: folder, timeout: 30, gate: gate, command: quick).run([])
        let before = openDescriptors()
        let folder = self.folder

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask {
                    let timeout: TimeInterval = index % 5 == 0 ? 0.1 : 30
                    let command = index % 5 == 0 ? ["/bin/sleep"] : ["/usr/bin/true"]
                    let task = Task { try await GitRunner(workdir: folder, timeout: timeout, gate: gate, command: command).run(["600"]) }
                    if index % 3 == 0 { task.cancel() }
                    _ = try? await task.value
                }
            }
        }
        await eventually("every pipe is closed again") { openDescriptors() <= before + 1 }
    }

    func testTheErrorsReadAsSentences() {
        let retryAt = Date().addingTimeInterval(30)
        let timedOut = GitError.timedOut(args: ["log"], seconds: 60, retryAt: retryAt)
        XCTAssertTrue(timedOut.localizedDescription.contains("didn’t answer in 60 seconds"), timedOut.localizedDescription)
        let backingOff = GitError.backingOff(retryAt: retryAt)
        XCTAssertTrue(backingOff.localizedDescription.contains("left alone until"), backingOff.localizedDescription)
        let failed = GitError.commandFailed(args: ["log", "-1"], status: 128, stderr: "fatal: bad\n")
        XCTAssertEqual(failed.localizedDescription, "git log -1 failed (128): fatal: bad")
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
