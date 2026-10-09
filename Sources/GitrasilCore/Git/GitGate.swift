import Foundation

/// How many `git` processes run at once, across every repository. Sixty-four pinned repositories
/// would otherwise start hundreds of processes together at launch; queued ones start as others finish.
/// GITRASIL_GIT_READERS overrides the limit (default 5).
final class GitGate: @unchecked Sendable {
    static let shared = GitGate(limit: ProcessInfo.processInfo.environment["GITRASIL_GIT_READERS"].flatMap { Int($0) } ?? 5)

    private let lock = NSLock()
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { free = max(limit, 1) }

    func enter() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if free > 0 { free -= 1; return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func leave() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if waiting.isEmpty { free += 1; return nil }
            return waiting.removeFirst()
        }
        next?.resume()
    }
}
