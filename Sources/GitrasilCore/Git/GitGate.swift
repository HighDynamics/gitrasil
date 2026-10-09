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

    init(limit: Int) { free = max(limit, 1) }

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
