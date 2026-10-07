import AppKit
import SwiftUI
import GitrasilCore

// Gitrasil: the pinned repositories grown as trees on a live desktop background (docs/yggdrasil).
//
// Usage: GitrasilWallpaper [--quit-after <seconds>]
//        GitrasilWallpaper --benchmark [runs] | --snapshot <folder>
//
// Opens a desktop-level window on every display and grows the pinned repositories as trees (an
// orchard, or one tree with a bough each) behind the desktop icons, redrawing when they change. A
// menu-bar item adds and removes the pins and holds the settings (the arrangement, banners, gusts),
// all saved in the `com.gitrasil.background` defaults (or the suite GITRASIL_BACKGROUND_DEFAULTS_SUITE
// names). Nothing is installed and the system wallpaper setting is never touched.
//
// --benchmark and --snapshot are test aids (`Offscreen`): they draw the pinned repositories offscreen,
// with no window or menu, print the redraw times or write images, and quit.

/// What a launch does: run the background, or one of the offscreen test aids.
enum Mode {
    case background(quitAfter: TimeInterval?)
    case benchmark(runs: Int)
    case snapshot(URL)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mode: Mode
    private var windows: DesktopWindows?
    private var background: BackgroundModel?
    private var menu: StatusMenu?

    init(mode: Mode) {
        self.mode = mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon and no app menu; the status item is the only UI.
        NSApp.setActivationPolicy(.accessory)

        let suite = PinnedRepositories.appSuiteName()
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let pins = PinnedRepositories(storage: defaults, limit: BackgroundModel.maxPanes)
        // The offscreen aids try each arrangement and medium in turn: on a copy of the saved settings,
        // so a run never changes them. The pins are only read.
        let settings: BackgroundSettings
        if case .background = mode {
            settings = BackgroundSettings(storage: defaults)
        } else {
            settings = BackgroundSettings(storage: MemorySettings(defaults.dictionaryRepresentation()))
        }
        let background = BackgroundModel(pins: pins, settings: settings)
        logEvent("defaults \(suite), \(pins.pins.count) pinned (\(pins.shown.count) shown), \(settings.arrangement.rawValue)")

        // Follows the system's light/dark mode; GITRASIL_BACKGROUND_APPEARANCE=light|dark pins one (the
        // background and the menu), to preview the other mode without changing the system setting.
        switch ProcessInfo.processInfo.environment["GITRASIL_BACKGROUND_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        let quitAfter: TimeInterval?
        switch mode {
        case .background(let after):
            quitAfter = after
        case .benchmark(let runs):
            return offscreen(background) { await Offscreen.benchmark($0, runs: runs) }
        case .snapshot(let folder):
            return offscreen(background) { await Offscreen.snapshot($0, to: folder) }
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

    /// Starts the background with no window or menu, runs `aid` on it, and quits.
    @MainActor private func offscreen(_ background: BackgroundModel, _ aid: @escaping @MainActor (BackgroundModel) async -> Void) {
        self.background = background
        background.start()
        Task { @MainActor in
            await aid(background)
            NSApp.terminate(nil)
        }
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
var quitAfter: TimeInterval?
if let flag = arguments.firstIndex(of: "--quit-after"), flag + 1 < arguments.count {
    quitAfter = TimeInterval(arguments[flag + 1])
    arguments.removeSubrange(flag...(flag + 1))
}
var mode = Mode.background(quitAfter: quitAfter)
if arguments.first == "--benchmark" {
    mode = .benchmark(runs: arguments.dropFirst().first.flatMap { Int($0) } ?? 15)
    arguments = arguments.count > 1 && Int(arguments[1]) != nil ? Array(arguments.dropFirst(2)) : Array(arguments.dropFirst())
} else if arguments.first == "--snapshot", arguments.count > 1 {
    mode = .snapshot(URL(fileURLWithPath: arguments[1]))
    arguments.removeFirst(2)
}
guard arguments.isEmpty else {
    FileHandle.standardError.write(Data("""
        usage: GitrasilWallpaper [--quit-after <seconds>]
               GitrasilWallpaper --benchmark [runs] | --snapshot <folder>
        Pin repositories from the menu-bar item; they're saved between launches.

        """.utf8))
    exit(64)
}

let application = NSApplication.shared
let delegate = AppDelegate(mode: mode)
application.delegate = delegate
application.run()
