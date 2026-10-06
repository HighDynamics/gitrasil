import Foundation
import Observation
import GitrasilCore

/// The whole background: one pane per pinned repository (the first `maxPanes`), kept in step with
/// the pins as they're added and removed, and how to arrange them (an orchard or a single tree).
@MainActor
@Observable
final class BackgroundModel {

    /// The panes on screen, in pin order.
    private(set) var panes: [WallpaperModel] = []

    /// The clock commit ages are measured against. Ticks hourly so old commits keep fading on an
    /// idle desktop; a graph change redraws with the current time anyway.
    private(set) var now = Date()

    /// More than this side by side gets too narrow to read.
    static let maxPanes = 4

    let pins: PinnedRepositories
    let arrangement: ArrangementSetting

    var isVisible = true {
        didSet { for pane in panes { pane.isVisible = isVisible } }
    }

    private var clock: Timer?

    init(pins: PinnedRepositories, arrangement: ArrangementSetting) {
        self.pins = pins
        self.arrangement = arrangement
    }

    func start() {
        observePins()
        observeArrangement()
        reconcile()
        clock = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
    }

    /// Re-arm Observation tracking on the pin list (one-shot, so re-armed on every change).
    private func observePins() {
        withObservationTracking {
            _ = pins.urls
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reconcile()
                self.observePins()
            }
        }
    }

    /// Log each switch of arrangement (the view redraws on its own; it reads the setting).
    private func observeArrangement() {
        withObservationTracking {
            _ = arrangement.value
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.log("arrangement: \(self.arrangement.value.rawValue)")
                self.observeArrangement()
            }
        }
    }

    /// Match the panes to the pins: keep the stores of repos still pinned, start new ones, stop
    /// the rest.
    private func reconcile() {
        let wanted = Array(pins.urls.prefix(Self.maxPanes))
        var existing = Dictionary(panes.map { ($0.repoURL, $0) }, uniquingKeysWith: { a, _ in a })
        let next = wanted.map { url in
            existing.removeValue(forKey: url) ?? {
                let pane = WallpaperModel(repoURL: url)
                pane.isVisible = isVisible
                Task { await pane.start() }
                return pane
            }()
        }
        for gone in existing.values { gone.stop() }
        if next.map(\.repoURL) != panes.map(\.repoURL) {
            panes = next
            log("panes: \(panes.map(\.repoName))")
        }
    }

    func log(_ message: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        print("[\(stamp)] \(message)")
        fflush(stdout)
    }
}
