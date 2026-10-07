import Foundation
import Observation

/// How the background shows several pinned repositories.
public enum Arrangement: String, CaseIterable, Sendable {
    /// A tree per repository, spaced along one ground.
    case orchard
    /// One tree: a shared trunk with a bough per repository.
    case singleTree
}

/// What the trees are drawn in.
public enum Medium: String, CaseIterable, Sendable {
    /// Brush ink on cream paper.
    case ink
    /// Charcoal and coloured pastel on paper with a tooth.
    case charcoal
    /// Coloured chalk on a slate board.
    case chalk
}

/// Where the settings are saved: `UserDefaults` for the app, a dictionary in tests.
public protocol SettingsStorage: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: SettingsStorage {}

/// Settings kept in memory only: a copy of saved values to change without writing them back (the
/// offscreen test aids), or a blank slate (tests).
public final class MemorySettings: SettingsStorage {
    public var saved: [String: Any]

    public init(_ saved: [String: Any] = [:]) {
        self.saved = saved
    }

    public func object(forKey key: String) -> Any? { saved[key] }
    public func set(_ value: Any?, forKey key: String) { saved[key] = value }
}

/// The background's settings from the menu, saved between launches next to the pins. Unset (or
/// unreadable) values take their defaults: an orchard in chalk, every name shown, the banners still.
@MainActor
@Observable
public final class BackgroundSettings {

    static let arrangementKey = "arrangement"
    static let branchNamesKey = "showsBranchNames"
    static let repoNamesKey = "showsRepoNames"
    static let gustsKey = "gusts"
    static let mediumKey = "medium"

    public var arrangement: Arrangement {
        didSet { if arrangement != oldValue { storage.set(arrangement.rawValue, forKey: Self.arrangementKey) } }
    }

    /// What the trees are drawn in.
    public var medium: Medium {
        didSet { if medium != oldValue { storage.set(medium.rawValue, forKey: Self.mediumKey) } }
    }

    /// Whether branch names hang on pennants from their tips.
    public var showsBranchNames: Bool {
        didSet { if showsBranchNames != oldValue { storage.set(showsBranchNames, forKey: Self.branchNamesKey) } }
    }

    /// Whether, in the single tree, each repository's name hangs on a ribbon from its bough. The
    /// orchard always writes a repository's name under its tree.
    public var showsRepoNames: Bool {
        didSet { if showsRepoNames != oldValue { storage.set(showsRepoNames, forKey: Self.repoNamesKey) } }
    }

    /// Whether a gust now and then sways the banners; off (the default), they hang still.
    public var gusts: Bool {
        didSet { if gusts != oldValue { storage.set(gusts, forKey: Self.gustsKey) } }
    }

    /// Whether anything hangs that a gust could sway: branch pennants, or ribbons in the single tree.
    public var hasBanners: Bool {
        showsBranchNames || showsRepoNames && arrangement == .singleTree
    }

    /// Whether gusts blow: wanted, and with banners to sway.
    public var gustsBlow: Bool { gusts && hasBanners }

    private let storage: SettingsStorage

    public init(storage: SettingsStorage) {
        self.storage = storage
        arrangement = (storage.object(forKey: Self.arrangementKey) as? String).flatMap(Arrangement.init(rawValue:)) ?? .orchard
        medium = (storage.object(forKey: Self.mediumKey) as? String).flatMap(Medium.init(rawValue:)) ?? .chalk
        showsBranchNames = storage.object(forKey: Self.branchNamesKey) as? Bool ?? true
        showsRepoNames = storage.object(forKey: Self.repoNamesKey) as? Bool ?? true
        gusts = storage.object(forKey: Self.gustsKey) as? Bool ?? false
    }
}
