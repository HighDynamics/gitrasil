import AppKit
import SwiftUI
import GitrasilCore

// Gitrasil's history graph as a live desktop background (docs/live-background/DESIGN.md).
//
// Usage: GitrasilWallpaper [--quit-after <seconds>]
//
// Opens one desktop-level window on the primary display and draws the pinned repositories' branch
// graphs behind the desktop icons, redrawing when they change. A menu-bar item adds and removes the
// pinned repositories, which are saved in the `com.gitrasil.background` defaults (or the suite
// GITRASIL_BACKGROUND_DEFAULTS_SUITE names). Nothing is installed and the system wallpaper setting
// is never touched.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let quitAfter: TimeInterval?
    private var window: DesktopWindow?
    private var background: BackgroundModel?
    private var menu: StatusMenu?

    init(quitAfter: TimeInterval?) {
        self.quitAfter = quitAfter
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon and no app menu; the status item is the only UI.
        NSApp.setActivationPolicy(.accessory)

        // The primary display (menu bar, origin 0,0) — NSScreen.main follows the key window, which an
        // accessory app doesn't have.
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        else { return }

        let suite = PinnedRepositories.appSuiteName()
        let pins = PinnedRepositories(storage: UserDefaults(suiteName: suite) ?? .standard)
        let background = BackgroundModel(pins: pins)
        let window = DesktopWindow(screen: screen)
        // Follows the system's light/dark mode; GITRASIL_BACKGROUND_APPEARANCE=light|dark pins one,
        // to preview the other mode without changing the system setting.
        switch ProcessInfo.processInfo.environment["GITRASIL_BACKGROUND_APPEARANCE"] {
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        case "light": window.appearance = NSAppearance(named: .aqua)
        default: break
        }
        window.contentView = NSHostingView(rootView: WallpaperView(background: background))
        window.orderFront(nil)
        self.window = window
        self.background = background
        self.menu = StatusMenu(pins: pins)
        background.log("window up: level \(window.level.rawValue), frame \(window.frame), "
                       + "screen \(screen.localizedName), defaults \(suite), \(pins.urls.count) pinned")

        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, let background = self.background else { return }
                let visible = window.occlusionState.contains(.visible)
                if visible != background.isVisible {
                    background.isVisible = visible
                    background.log("occlusion: \(visible ? "visible" : "hidden")")
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let window = self?.window, let screen = window.screen else { return }
                window.setFrame(screen.frame, display: true)
            }
        }

        background.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                if let menu = self?.menu { background.log(menu.placement) }
            }
        }

        if let quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) { NSApp.terminate(nil) }
        }
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
var quitAfter: TimeInterval?
if let flag = arguments.firstIndex(of: "--quit-after"), flag + 1 < arguments.count {
    quitAfter = TimeInterval(arguments[flag + 1])
    arguments.removeSubrange(flag...(flag + 1))
}
guard arguments.isEmpty else {
    FileHandle.standardError.write(Data("""
        usage: GitrasilWallpaper [--quit-after <seconds>]
        Pin repositories from the menu-bar item; they're saved between launches.

        """.utf8))
    exit(64)
}

let application = NSApplication.shared
let delegate = AppDelegate(quitAfter: quitAfter)
application.delegate = delegate
application.run()
