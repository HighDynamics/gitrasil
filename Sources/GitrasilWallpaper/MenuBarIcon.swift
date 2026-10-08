import AppKit

/// The menu-bar item's image: `Resources/MenuBarIcon.pdf`, drawn as a template so it takes the menu
/// bar's own tint in light, dark and highlighted states.
///
/// The file is the Gitrasil tree, drawn by `scripts/draw-icon.swift`: a one-page vector PDF on an
/// 18×18 pt page, the glyph in black on transparent (only its alpha is used), about 16 pt tall.
/// Swapping the icon is replacing that one file with another like it.
enum MenuBarIcon {

    static func image() -> NSImage {
        let image = url().flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "tree", accessibilityDescription: nil)
            ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Gitrasil Background"
        return image
    }

    /// In Gitrasil.app the file is in the app's own resources (`scripts/build-app.sh` copies it
    /// there); run bare, it's in SwiftPM's resource bundle beside the executable. The app is asked
    /// first: some toolchains' `Bundle.module` doesn't look inside an app, and stops the app when it
    /// can't find its bundle.
    private static func url() -> URL? {
        Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf")
            ?? Bundle.module.url(forResource: "MenuBarIcon", withExtension: "pdf")
    }
}
