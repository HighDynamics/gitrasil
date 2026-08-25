import Foundation
@testable import GitrasilCore

/// A fake `GitRunning` that records the order commands actually execute in and can be told to
/// run slowly, so the executor's serialization/coalescing behavior can be asserted without disk.
actor RecordingRunner: GitRunning {
    private(set) var started: [String] = []
    private(set) var finished: [String] = []
    private let delay: Duration

    init(delay: Duration = .milliseconds(50)) {
        self.delay = delay
    }

    nonisolated func run(_ args: [String]) async throws -> GitOutput {
        let label = args.joined(separator: " ")
        await record(started: label)
        try? await Task.sleep(for: delay)
        try Task.checkCancellation()
        await record(finished: label)
        return GitOutput(status: 0, stdout: Data(label.utf8), stderr: Data())
    }

    private func record(started label: String) { started.append(label) }
    private func record(finished label: String) { finished.append(label) }

    func snapshot() -> (started: [String], finished: [String]) { (started, finished) }
}
