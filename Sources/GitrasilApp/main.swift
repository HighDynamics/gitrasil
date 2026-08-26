import AppKit
import SwiftUI
import GitrasilCore

// Manual AppKit bootstrap. A SwiftUI `App`/`WindowGroup` built as a plain SwiftPM executable does
// not reliably create a window under LaunchServices; hosting the SwiftUI root in an NSWindow via
// NSHostingView does. (The app is still launched as a .app bundle via scripts/run.sh.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "gitrasil"
        window.contentView = NSHostingView(rootView: RootView())
        // Center on the primary display (the one with the menu bar, at origin 0,0) so it's
        // predictably visible regardless of multi-monitor layout.
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        if let frame = primary?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
