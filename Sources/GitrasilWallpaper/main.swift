import AppKit
import SwiftUI
import GitrasilCore

// Gitrasil's history graph as a live desktop background (docs/live-background/DESIGN.md).
//
// Usage: GitrasilWallpaper [--quit-after <seconds>]
//
// Opens a desktop-level window on every display and grows the pinned repositories as trees (an
// orchard, or one tree with a bough each) behind the desktop icons, redrawing when they change. A
// menu-bar item adds and removes the pinned repositories and picks the arrangement, which are saved in the `com.gitrasil.background` defaults (or the suite
// GITRASIL_BACKGROUND_DEFAULTS_SUITE names). Nothing is installed and the system wallpaper setting
// is never touched.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let quitAfter: TimeInterval?
    private var windows: DesktopWindows?
    private var background: BackgroundModel?
    private var menu: StatusMenu?

    init(quitAfter: TimeInterval?) {
        self.quitAfter = quitAfter
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon and no app menu; the status item is the only UI.
        NSApp.setActivationPolicy(.accessory)

        let suite = PinnedRepositories.appSuiteName()
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let pins = PinnedRepositories(storage: defaults, limit: BackgroundModel.maxPanes)
        let arrangement = ArrangementSetting(storage: defaults)
        let background = BackgroundModel(pins: pins, arrangement: arrangement)
        background.log("defaults \(suite), \(pins.pins.count) pinned (\(pins.shown.count) shown), \(arrangement.value.rawValue)")

        // Follows the system's light/dark mode; GITRASIL_BACKGROUND_APPEARANCE=light|dark pins one,
        // to preview the other mode without changing the system setting.
        let appearance: NSAppearance? = switch ProcessInfo.processInfo.environment["GITRASIL_BACKGROUND_APPEARANCE"] {
        case "dark": NSAppearance(named: .darkAqua)
        case "light": NSAppearance(named: .aqua)
        default: nil
        }
        let windows = DesktopWindows(background: background, appearance: appearance)
        windows.start()
        self.windows = windows
        self.background = background
        self.menu = StatusMenu(pins: pins, arrangement: arrangement)

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
