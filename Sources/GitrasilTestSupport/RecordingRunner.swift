import Foundation
import GitrasilCore

/// A fake `GitRunning` that records the order commands actually execute in and can run slowly,
/// so the executor's serialization/coalescing behavior is assertable without disk.
public actor RecordingRunner: GitRunning {
    public private(set) var started: [String] = []
    public private(set) var finished: [String] = []
    private let delay: Duration

    public init(delay: Duration = .milliseconds(50)) { self.delay = delay }

    public nonisolated func run(_ args: [String]) async throws -> GitOutput {
        let label = args.joined(separator: " ")
        await record(started: label)
        try? await Task.sleep(for: delay)
        try Task.checkCancellation()
        await record(finished: label)
        return GitOutput(status: 0, stdout: Data(label.utf8), stderr: Data())
    }

    private func record(started label: String) { started.append(label) }
    private func record(finished label: String) { finished.append(label) }

    public func snapshot() -> (started: [String], finished: [String]) { (started, finished) }
}
