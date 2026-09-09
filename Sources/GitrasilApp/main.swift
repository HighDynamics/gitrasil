import AppKit
import SwiftUI
import GitrasilCore

// Manual AppKit bootstrap. A SwiftUI `App`/`WindowGroup` built as a plain SwiftPM executable does
// not reliably create a window under LaunchServices; hosting the SwiftUI root in an NSWindow via
// NSHostingView does. (The app is still launched as a .app bundle via scripts/run.sh.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()

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

    // MARK: App menu

    /// A minimal main menu — the manual AppKit bootstrap has none by default. The app menu carries
    /// Settings… (⌘,) and Quit; a starting point for a fuller menu bar later.
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu()
        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit gitrasil", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let settings = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.title = "Settings"
            settings.contentView = NSHostingView(rootView: SettingsView())
            settings.isReleasedWhenClosed = false
            settings.center()
            settingsWindow = settings
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
