import AppKit

/// A borderless window pinned to the desktop layer: above the wallpaper, below Finder's desktop
/// icons, on every Space, and untouched by Mission Control, Exposé, and Cmd-Tab. It never takes
/// focus or clicks, so the desktop (icons, right-click, drag-select) keeps working through it.
final class DesktopWindow: NSWindow {

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // kCGDesktopWindowLevel. Finder's icons sit at kCGDesktopIconWindowLevel (desktop + 20), so
        // we're drawn behind them; the system wallpaper is at the same level, ordered behind us.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        // canJoinAllSpaces: one window shows on every Space of its display. stationary: Mission
        // Control and Show Desktop leave it in place (like the wallpaper). ignoresCycle: never in
        // Cmd-` window cycling. fullScreenNone: never becomes a full-screen Space of its own.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
