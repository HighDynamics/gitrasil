import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// One macOS application that can open a file, from LaunchServices (the database behind Finder's
/// "Open With").
struct AppOption: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let url: URL
    var id: String { bundleID }
}

/// App-wide "open the working-tree file" preference, mirroring `DiffToolSettings`: a default app the
/// user can set in Settings, persisted in `UserDefaults`. The per-file "Open With" submenu is built
/// from LaunchServices for the specific file; this type holds the default and the Settings-wide app
/// list.
@MainActor
@Observable
final class OpenWithSettings {
    /// Apps that can open text/source files — the choices for the Settings default picker.
    private(set) var available: [AppOption] = []
    private(set) var loaded = false

    /// The configured default app's bundle id, or nil to ask each time. Mirrored to UserDefaults.
    private(set) var configuredBundleID: String?

    private let defaultsKey = "defaultOpenAppBundleID"

    init() {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)
        configuredBundleID = (stored?.isEmpty ?? true) ? nil : stored
    }

    func loadIfNeeded() async {
        guard !loaded else { return }
        await reload()
    }

    func reload() async {
        available = Self.apps(forType: .plainText)
        loaded = true
    }

    /// Persist the default app; nil/empty clears it (ask each time).
    func setDefault(_ bundleID: String?) {
        let value = (bundleID?.isEmpty ?? true) ? nil : bundleID
        configuredBundleID = value
        if let value { UserDefaults.standard.set(value, forKey: defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
    }

    /// The configured default resolved to an installed app, or nil (unset, or the app is gone).
    var defaultApp: AppOption? {
        guard let id = configuredBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return AppOption(bundleID: id, name: Self.name(for: url), url: url)
    }

    // MARK: LaunchServices lookups

    /// Apps that can open a specific file (the per-file "Open With" submenu).
    static func apps(forFile url: URL) -> [AppOption] {
        NSWorkspace.shared.urlsForApplications(toOpen: url).map(option(for:))
    }

    /// Apps that can open a content type (a file-independent list for Settings).
    static func apps(forType type: UTType) -> [AppOption] {
        NSWorkspace.shared.urlsForApplications(toOpen: type).map(option(for:))
    }

    /// Open a file in a specific app (LaunchServices), or the system default when `app` is nil.
    static func open(_ fileURL: URL, in app: AppOption?) {
        if let app {
            NSWorkspace.shared.open([fileURL], withApplicationAt: app.url,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(fileURL)
        }
    }

    private static func option(for appURL: URL) -> AppOption {
        AppOption(bundleID: Bundle(url: appURL)?.bundleIdentifier ?? appURL.path,
                  name: name(for: appURL), url: appURL)
    }

    private static func name(for appURL: URL) -> String {
        var name = FileManager.default.displayName(atPath: appURL.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        return name
    }
}
