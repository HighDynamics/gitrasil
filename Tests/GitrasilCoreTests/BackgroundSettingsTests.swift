import XCTest
@testable import GitrasilCore

/// In memory, so tests never write to the user's preferences.
private final class MemorySettings: SettingsStorage {
    var saved: [String: Any] = [:]
    func object(forKey key: String) -> Any? { saved[key] }
    func set(_ value: Any?, forKey key: String) { saved[key] = value }
}

@MainActor
final class BackgroundSettingsTests: XCTestCase {

    func testDefaultsUntilChosenOtherwise() {
        let settings = BackgroundSettings(storage: MemorySettings())
        XCTAssertEqual(settings.arrangement, .orchard)
        XCTAssertTrue(settings.showsBanners)
        XCTAssertTrue(settings.gusts)
    }

    func testUnreadableValuesTakeTheirDefaults() {
        let storage = MemorySettings()
        storage.saved = ["arrangement": "hedge", "showsBanners": "no", "gusts": 3]
        let settings = BackgroundSettings(storage: storage)
        XCTAssertEqual(settings.arrangement, .orchard)
        XCTAssertTrue(settings.showsBanners)
        XCTAssertTrue(settings.gusts)
    }

    func testChoicesAreSavedBetweenLaunches() {
        let storage = MemorySettings()
        let settings = BackgroundSettings(storage: storage)
        settings.arrangement = .singleTree
        settings.showsBanners = false
        settings.gusts = false
        XCTAssertEqual(storage.saved["arrangement"] as? String, "singleTree")

        let relaunched = BackgroundSettings(storage: storage)
        XCTAssertEqual(relaunched.arrangement, .singleTree)
        XCTAssertFalse(relaunched.showsBanners)
        XCTAssertFalse(relaunched.gusts)
    }

    func testTheArrangementKeyIsTheOneEarlierBuildsSaved() {
        let suite = "gitrasil-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("singleTree", forKey: "arrangement")
        XCTAssertEqual(BackgroundSettings(storage: defaults).arrangement, .singleTree)
    }
}
