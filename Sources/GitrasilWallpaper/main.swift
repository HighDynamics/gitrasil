import AppKit
import SwiftUI

// Spike: Gitrasil's history graph as a live desktop background (docs/live-background/DESIGN.md).
//
// Usage: GitrasilWallpaper /path/to/repo [--quit-after <seconds>]
//
// Opens one desktop-level window on the primary display, draws the repo's branch graph behind the
// desktop icons, and redraws when the repo changes. Quit with Ctrl-C (or --quit-after); nothing is
// installed and the system wallpaper setting is never touched.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let repoURL: URL
    private let quitAfter: TimeInterval?
    private var window: DesktopWindow?
    private var model: WallpaperModel?

    init(repoURL: URL, quitAfter: TimeInterval?) {
        self.repoURL = repoURL
        self.quitAfter = quitAfter
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no menu bar, never activates.
        NSApp.setActivationPolicy(.accessory)

        // The primary display (menu bar, origin 0,0) — NSScreen.main follows the key window, which an
        // accessory app doesn't have.
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        else { return }

        let model = WallpaperModel(repoURL: repoURL)
        let window = DesktopWindow(screen: screen)
        window.contentView = NSHostingView(rootView: WallpaperView(model: model))
        window.orderFront(nil)
        self.window = window
        self.model = model
        model.log("window up: level \(window.level.rawValue), frame \(window.frame), screen \(screen.localizedName)")

        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, let model = self.model else { return }
                let visible = window.occlusionState.contains(.visible)
                if visible != model.isVisible {
                    model.isVisible = visible
                    model.log("occlusion: \(visible ? "visible" : "hidden")")
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

        Task { await model.start() }

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
guard let path = arguments.first else {
    FileHandle.standardError.write(Data("usage: GitrasilWallpaper /path/to/repo [--quit-after <seconds>]\n".utf8))
    exit(64)
}

let application = NSApplication.shared
let delegate = AppDelegate(repoURL: URL(fileURLWithPath: path).standardizedFileURL, quitAfter: quitAfter)
application.delegate = delegate
application.run()
