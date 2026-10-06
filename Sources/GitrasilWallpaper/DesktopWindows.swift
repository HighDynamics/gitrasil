import AppKit
import SwiftUI

/// One desktop window per display, each drawing the same background, kept in step with the
/// displays: a display that's connected gets a window, one that's removed loses its window, and one
/// that moves or changes resolution has its window refit.
///
/// The background pauses only when every window is fully covered; while any display shows the
/// desktop, the stores stay live.
@MainActor
final class DesktopWindows {

    private let background: BackgroundModel
    private var windows: [CGDirectDisplayID: DesktopWindow] = [:]
    private var occlusionObservers: [CGDirectDisplayID: NSObjectProtocol] = [:]
    private var screenObserver: NSObjectProtocol?

    init(background: BackgroundModel) {
        self.background = background
    }

    func start() {
        reconcile()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    /// Match the windows to `NSScreen.screens`.
    private func reconcile() {
        var current: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = screen.displayID { current[id] = screen }
        }
        let removed = windows.keys.filter { current[$0] == nil }
        for id in removed {
            windows.removeValue(forKey: id)?.orderOut(nil)
            occlusionObservers.removeValue(forKey: id).map(NotificationCenter.default.removeObserver)
            logEvent("display \(id) removed")
        }
        for (id, screen) in current {
            if let window = windows[id] {
                if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
                continue
            }
            let window = DesktopWindow(screen: screen)
            window.contentView = NSHostingView(rootView: WallpaperView(background: background))
            window.orderFront(nil)
            windows[id] = window
            occlusionObservers[id] = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.occlusionChanged() }
            }
            logEvent("display \(id) (\(screen.localizedName)): window level \(window.level.rawValue), "
                           + "frame \(window.frame)")
        }
        // A new window reports its occlusion once it's on screen; losing one can change it now.
        if !removed.isEmpty { occlusionChanged() }
    }

    private func occlusionChanged() {
        let visible = windows.values.contains { $0.occlusionState.contains(.visible) }
        if visible != background.isVisible {
            background.isVisible = visible
            logEvent("occlusion: \(visible ? "visible on at least one display" : "hidden everywhere")")
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
