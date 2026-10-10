import Foundation

/// GITRASIL_BACKGROUND_FRAMELOG=1 logs, each second something is drawn, how many times each kind of
/// canvas was drawn and how long that took (total, mean and slowest): the live cost of a grow-in, as a
/// window pays it (the offscreen `--benchmark` draws on an image renderer instead).
@MainActor
final class FrameStats {
    static let shared = FrameStats()
    static let isOn = ProcessInfo.processInfo.environment["GITRASIL_BACKGROUND_FRAMELOG"] == "1"

    private struct Tally {
        var count = 0
        var total = 0.0
        var slowest = 0.0
    }

    private var windowStart = DispatchTime.now().uptimeNanoseconds
    private var tallies: [String: Tally] = [:]

    /// Times `draw` under `label` and reports the second it falls in.
    func measure(_ label: String, _ draw: () -> Void) {
        guard Self.isOn else { return draw() }
        let start = DispatchTime.now().uptimeNanoseconds
        draw()
        let end = DispatchTime.now().uptimeNanoseconds
        let ms = Double(end - start) / 1e6
        var tally = tallies[label, default: Tally()]
        tally.count += 1
        tally.total += ms
        tally.slowest = max(tally.slowest, ms)
        tallies[label] = tally
        if end - windowStart >= 1_000_000_000 {
            let seconds = Double(end - windowStart) / 1e9
            let all = tallies.values.reduce(0) { $0 + $1.total }
            let parts = tallies.sorted { $0.key < $1.key }.map { label, tally in
                String(format: "%@ %d× %.0f ms (mean %.1f, slowest %.1f)", label, tally.count, tally.total, tally.total / Double(tally.count),
                       tally.slowest)
            }
            logEvent(String(format: "draw in %.2f s: %.0f ms busy · ", seconds, all) + parts.joined(separator: " · "))
            windowStart = end
            tallies = [:]
        }
    }
}
