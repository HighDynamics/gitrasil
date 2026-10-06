import Foundation
import Observation

/// How the background shows several pinned repositories.
public enum Arrangement: String, CaseIterable, Sendable {
    /// A tree per repository, spaced along one ground.
    case orchard
    /// One tree: a shared trunk with a bough per repository.
    case singleTree
}

/// Where the settings are saved: `UserDefaults` for the app, a dictionary in tests.
public protocol SettingsStorage: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: SettingsStorage {}

/// The background's settings from the menu, saved between launches next to the pins. Unset (or
/// unreadable) values take their defaults: an orchard, banners shown, gusts blowing.
@MainActor
@Observable
public final class BackgroundSettings {

    static let arrangementKey = "arrangement"
    static let bannersKey = "showsBanners"
    static let gustsKey = "gusts"

    public var arrangement: Arrangement {
        didSet { if arrangement != oldValue { storage.set(arrangement.rawValue, forKey: Self.arrangementKey) } }
    }

    /// Whether names hang on banners: branches at their tips, and in the single tree each repository
    /// on its bough.
    public var showsBanners: Bool {
        didSet { if showsBanners != oldValue { storage.set(showsBanners, forKey: Self.bannersKey) } }
    }

    /// Whether a gust now and then sways the banners; off, they hang still.
    public var gusts: Bool {
        didSet { if gusts != oldValue { storage.set(gusts, forKey: Self.gustsKey) } }
    }

    private let storage: SettingsStorage

    public init(storage: SettingsStorage) {
        self.storage = storage
        arrangement = (storage.object(forKey: Self.arrangementKey) as? String).flatMap(Arrangement.init(rawValue:)) ?? .orchard
        showsBanners = storage.object(forKey: Self.bannersKey) as? Bool ?? true
        gusts = storage.object(forKey: Self.gustsKey) as? Bool ?? true
    }
}
