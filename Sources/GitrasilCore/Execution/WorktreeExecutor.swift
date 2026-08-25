import Foundation

/// Per-worktree serial command executor (architecture decision #1).
///
/// Owns all `git` execution for one worktree and runs commands strictly one at a time,
/// so mutations never overlap and reads never interleave with a mutation. Two command kinds:
///
/// - **Mutations** (`mutate`): exclusive, never cancelled once enqueued. Reads queue behind them.
/// - **Reads** (`read`): coalescable by `ReadKind` — requesting a kind cancels the prior
///   outstanding read of that same kind (newest wins), so a burst of FSEvents collapses to one
///   re-derive instead of a pile-up.
///
/// The mid-mutation race rule lives one layer up: a mutation's completion drives the
/// authoritative re-derive, and FSEvents refreshes arriving during a mutation coalesce into it.
/// This actor provides the serialization primitive that makes that rule enforceable.
public actor WorktreeExecutor {

    public enum ReadKind: Hashable, Sendable {
        case statuses
        case graph
        case inProgress
        case custom(String)
    }

    private let runner: GitRunning

    /// Tail of the serial chain: every new command awaits its predecessor before running,
    /// which is what serializes the whole executor.
    private var tail: Task<Void, Never> = Task {}

    /// Cancel handles for the currently-outstanding read of each kind (for coalescing).
    private var readCancels: [ReadKind: () -> Void] = [:]

    public init(runner: GitRunning) {
        self.runner = runner
    }

    /// Enqueue an exclusive mutation. Never cancelled; all later commands queue behind it.
    @discardableResult
    public func mutate<T: Sendable>(
        _ operation: @Sendable @escaping (GitRunning) async throws -> T
    ) -> Task<T, Error> {
        enqueue(cancellable: false, operation)
    }

    /// Enqueue a read, coalesced by `kind`: any prior outstanding read of the same kind is
    /// cancelled first, so only the newest survives.
    @discardableResult
    public func read<T: Sendable>(
        _ kind: ReadKind,
        _ operation: @Sendable @escaping (GitRunning) async throws -> T
    ) -> Task<T, Error> {
        readCancels[kind]?()
        let task = enqueue(cancellable: true, operation)
        readCancels[kind] = { task.cancel() }
        return task
    }

    private func enqueue<T: Sendable>(
        cancellable: Bool,
        _ operation: @Sendable @escaping (GitRunning) async throws -> T
    ) -> Task<T, Error> {
        let predecessor = tail
        let runner = self.runner
        let task = Task { () throws -> T in
            // Serialize: wait for everything enqueued before us.
            _ = await predecessor.value
            // A coalesced read that was superseded while queued bails out here.
            if cancellable { try Task.checkCancellation() }
            return try await operation(runner)
        }
        // The chain tracker never fails and never cancels, so the next command always proceeds
        // once this one settles (whether it succeeded, threw, or was cancelled).
        tail = Task { _ = try? await task.value }
        return task
    }
}
