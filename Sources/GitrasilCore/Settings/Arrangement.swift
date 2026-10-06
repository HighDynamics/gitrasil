import Foundation
import Observation

/// How the background shows several pinned repositories.
public enum Arrangement: String, CaseIterable, Sendable {
    /// A tree per repository, spaced along one ground.
    case orchard
    /// One tree: a shared trunk with a bough per repository.
    case singleTree
}

/// Where the arrangement is saved.
public protocol ArrangementStorage: AnyObject {
    func loadArrangement() -> String?
    func saveArrangement(_ value: String)
}

extension UserDefaults: ArrangementStorage {
    static let arrangementKey = "arrangement"
    public func loadArrangement() -> String? { string(forKey: Self.arrangementKey) }
    public func saveArrangement(_ value: String) { set(value, forKey: Self.arrangementKey) }
}

/// The chosen arrangement, saved between launches next to the pins. An orchard until chosen
/// otherwise (or when the saved value isn't one it knows).
@MainActor
@Observable
public final class ArrangementSetting {

    public var value: Arrangement {
        didSet { if value != oldValue { storage.saveArrangement(value.rawValue) } }
    }

    private let storage: ArrangementStorage

    public init(storage: ArrangementStorage) {
        self.storage = storage
        self.value = storage.loadArrangement().flatMap(Arrangement.init(rawValue:)) ?? .orchard
    }
}
