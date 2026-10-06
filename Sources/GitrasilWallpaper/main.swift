import AppKit
import SwiftUI
import GitrasilCore

// Gitrasil: the pinned repositories grown as trees on a live desktop background (docs/yggdrasil).
//
// Usage: GitrasilWallpaper [--quit-after <seconds>]
//
// Opens a desktop-level window on every display and grows the pinned repositories as trees (an
// orchard, or one tree with a bough each) behind the desktop icons, redrawing when they change. A
// menu-bar item adds and removes the pins and holds the settings (the arrangement, banners, gusts),
// all saved in the `com.gitrasil.background` defaults (or the suite GITRASIL_BACKGROUND_DEFAULTS_SUITE
// names). Nothing is installed and the system wallpaper setting is never touched.

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
        let settings = BackgroundSettings(storage: defaults)
        let background = BackgroundModel(pins: pins, settings: settings)
        logEvent("defaults \(suite), \(pins.pins.count) pinned (\(pins.shown.count) shown), \(settings.arrangement.rawValue)")

        // Follows the system's light/dark mode; GITRASIL_BACKGROUND_APPEARANCE=light|dark pins one (the
        // background and the menu), to preview the other mode without changing the system setting.
        switch ProcessInfo.processInfo.environment["GITRASIL_BACKGROUND_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        let windows = DesktopWindows(background: background)
        windows.start()
        self.windows = windows
        self.background = background
        self.menu = StatusMenu(pins: pins, settings: settings, gustsOverridden: background.breeze.isTurnedOff)

        background.start()

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
