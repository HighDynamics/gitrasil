import Foundation

/// How many `git` processes run at once, across every repository. Sixty-four pinned repositories
/// would otherwise start hundreds of processes together at launch; queued ones start as others finish.
/// GITRASIL_GIT_READERS overrides the limit (default 5). A wait for a place can be cancelled, so reads
/// of a repository that's been dropped leave the queue instead of running; `GitRunner` also stops a
/// process that outlives its timeout, so a few hung ones never hold every place.
final class GitGate: @unchecked Sendable {
    static let shared = GitGate(limit: ProcessInfo.processInfo.environment["GITRASIL_GIT_READERS"].flatMap { Int($0) } ?? 5)

    private let lock = NSLock()
    private var free: Int
    private var waiting: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextID: UInt64 = 0

    /// A repository (by folder) that timed out isn't tried again at once: its calls fail fast until `base`
    /// seconds have passed, twice as long for each timeout in a row, at most `ceiling`. After that one call
    /// at a time, the probe, is let through while the rest keep failing fast: a success forgets the
    /// failures, a timeout counts one more. So a volume that stays hung costs one stopped process now and
    /// then, however many reads of it are waiting.
    private var failures: [String: Failure] = [:]
    private let base: TimeInterval
    private let ceiling: TimeInterval

    private struct Failure {
        var count: Int
        var until: Date
        var probing = false
    }

    init(limit: Int, backoff base: TimeInterval = 30, ceiling: TimeInterval = 600) {
        free = max(limit, 1)
        self.base = base
        self.ceiling = ceiling
    }

    /// Throws `GitError.backingOff` while `key` is waiting out a timeout, or while its probe is out. Takes
    /// nothing: the check before waiting for a place, so a call that can't go ahead doesn't queue.
    func checkBackoff(_ key: String) throws {
        try lock.withLock {
            guard let failure = failures[key] else { return }
            if failure.until > Date() { throw GitError.backingOff(retryAt: failure.until) }
            if failure.probing { throw GitError.backingOff(retryAt: Date().addingTimeInterval(base)) }
        }
    }

    /// The check once a place is held (the back-off may have begun while the call waited): throws as
    /// `checkBackoff` does. Returns whether this call is the probe, which must end in `succeeded`,
    /// `timedOut` or `abandoned`.
    func admit(_ key: String) throws -> Bool {
        try lock.withLock {
            guard var failure = failures[key] else { return false }
            if failure.until > Date() { throw GitError.backingOff(retryAt: failure.until) }
            if failure.probing { throw GitError.backingOff(retryAt: Date().addingTimeInterval(base)) }
            failure.probing = true
            failures[key] = failure
            return true
        }
    }

    /// A call timed out: the probe, or the first call to, counts one failure; a call that was already
    /// running when another timed out doesn't count again. Returns when `key` may be tried again.
    @discardableResult
    func timedOut(_ key: String, probe: Bool) -> Date {
        lock.withLock {
            if !probe, let failure = failures[key] { return failure.until }
            let count = (failures[key]?.count ?? 0) + 1
            let until = Date().addingTimeInterval(min(base * pow(2, Double(count - 1)), ceiling))
            failures[key] = Failure(count: count, until: until)
            return until
        }
    }

    /// The probe got an answer: the repository is forgiven. (A call that began before the timeout and
    /// finished fine says nothing about it now.)
    func succeeded(_ key: String, probe: Bool) {
        guard probe else { return }
        lock.withLock { _ = failures.removeValue(forKey: key) }
    }

    /// The probe ended some other way (cancelled, couldn't launch): the next call may probe.
    func abandoned(_ key: String) {
        lock.withLock { failures[key]?.probing = false }
    }

    /// The timeouts counted against `key`, for tests.
    func failureCount(_ key: String) -> Int { lock.withLock { failures[key]?.count ?? 0 } }

    /// The places taken and the waiters queued, for tests to wait on.
    var occupancy: (free: Int, waiting: Int) { lock.withLock { (free, waiting.count) } }

    /// Waits for a place; throws `CancellationError` if the task is cancelled first, holding none.
    func enter() async throws {
        try Task.checkCancellation()
        let id = lock.withLock { () -> UInt64 in nextID += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Outcome { case go, cancelled, wait }
                // Checked under the lock `onCancel` also takes: cancelled before this ran, it's seen here;
                // after, the entry is there to remove.
                let outcome = lock.withLock { () -> Outcome in
                    if Task.isCancelled { return .cancelled }
                    if free > 0 { free -= 1; return .go }
                    waiting.append((id, continuation))
                    return .wait
                }
                switch outcome {
                case .go: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let removed = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return waiting.remove(at: index).continuation
            }
            removed?.resume(throwing: CancellationError())
        }
    }

    func leave() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            if waiting.isEmpty { free += 1; return nil }
            return waiting.removeFirst().continuation
        }
        next?.resume()
    }
}
