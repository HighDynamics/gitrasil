import AppKit
import ServiceManagement
import GitrasilCore

/// What Gitrasil does only as an app (Gitrasil.app, from `scripts/build-app.sh`): open at login, and
/// check whether a newer version has been released. Run as a bare executable it has neither: there's
/// no version to compare, and nothing for a login item to open.
@MainActor
final class AppServices {

    /// The running app's version, from its Info.plist.
    let version: ReleaseVersion
    /// Whether a newer release is out (opt-in, at most daily).
    let updates: UpdateCheck
    private let scheduler = NSBackgroundActivityScheduler(identifier: "com.gitrasil.Gitrasil.update-check")

    /// The app's services, or nil when it isn't running as an app. The update check looks at the
    /// repository the Info.plist names; GITRASIL_RELEASES_REPOSITORY points it at another, to try it.
    static func make(storage: SettingsStorage,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> AppServices? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard Bundle.main.bundleURL.pathExtension == "app",
              let version = (info["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init),
              let repository = environment["GITRASIL_RELEASES_REPOSITORY"].flatMap({ $0.isEmpty ? nil : $0 })
                ?? info["GitrasilReleasesRepository"] as? String
        else { return nil }
        return AppServices(version: version, updates: UpdateCheck(current: version, repository: repository, storage: storage))
    }

    private init(version: ReleaseVersion, updates: UpdateCheck) {
        self.version = version
        self.updates = updates
    }

    /// Checks for updates if that's on and due, and then asks again every few hours, at a moment
    /// macOS picks: the check itself only goes out once a day has passed since the last.
    func start() {
        logEvent("Gitrasil \(version), updates from \(updates.repository) \(updates.isEnabled ? "checked daily" : "not checked"), "
                 + "open at login \(loginStatus)")
        checkForUpdatesIfDue()
        scheduler.repeats = true
        scheduler.interval = 4 * 60 * 60
        scheduler.tolerance = 60 * 60
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.updates.checkIfDue()
                completion(.finished)
            }
        }
    }

    func checkForUpdatesIfDue() {
        Task { await updates.checkIfDue() }
    }

    // MARK: Open at login

    /// Where Open at Login stands.
    enum LoginItem {
        case off
        /// Registered, and allowed in System Settings.
        case on
        /// Registered, but waiting for the user to allow it in System Settings → Login Items.
        case awaitingApproval
    }

    var loginItem: LoginItem {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .awaitingApproval
        default: .off
        }
    }

    /// Whether the app runs from somewhere a login item can't keep pointing at: the random read-only
    /// copy macOS runs a quarantined download from where it landed (App Translocation), or the disk
    /// image it came in, gone on eject. Moving it to Applications ends both.
    var runsFromATemporaryPlace: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }

    /// Registers or unregisters the app as a login item. When macOS wants the user's approval first,
    /// opens the Login Items settings, where it's listed.
    func setOpensAtLogin(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        logEvent("open at login \(loginStatus)")
        if on, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private var loginStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: "on"
        case .notRegistered: "off"
        case .requiresApproval: "awaiting approval"
        case .notFound: "not found"
        @unknown default: "unknown"
        }
    }
}
