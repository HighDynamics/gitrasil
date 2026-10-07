import Foundation

/// A whole-scene grow-in waiting for its trees: it waits until every repository has been read (it
/// has a tree, or a problem to show instead), or until a time limit, whichever comes first, so the
/// scene grows in once, together, rather than restarting as each tree arrives.
public struct GrowInWait: Sendable {

    /// What to do when a grow-in is wanted.
    public enum Start: Equatable, Sendable {
        /// Everything's read: grow now.
        case growNow
        /// Wait; when the limit passes, call `timedOut(round:)` with this round.
        case wait(round: Int)
    }

    public private(set) var isWaiting = false
    private var round = 0

    public init() {}

    /// A grow-in wanted now, with every repository read or not. It replaces any wait under way.
    public mutating func start(allSettled: Bool) -> Start {
        round += 1
        isWaiting = !allSettled
        return allSettled ? .growNow : .wait(round: round)
    }

    /// A repository finished its first read: true when that ends the wait (grow now).
    public mutating func settled(allSettled: Bool) -> Bool {
        guard isWaiting, allSettled else { return false }
        isWaiting = false
        return true
    }

    /// The limit passed for wait `round`: true when that wait is still on (grow now, with the trees
    /// there are); false when it ended already or a later one replaced it.
    public mutating func timedOut(round: Int) -> Bool {
        guard isWaiting, round == self.round else { return false }
        isWaiting = false
        return true
    }

    /// Stop waiting without growing (the background went out of sight).
    public mutating func cancel() {
        isWaiting = false
    }
}
