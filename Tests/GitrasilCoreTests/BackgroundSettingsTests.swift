import XCTest
@testable import GitrasilCore

@MainActor
final class BackgroundSettingsTests: XCTestCase {

    func testDefaultsUntilChosenOtherwise() {
        let settings = BackgroundSettings(storage: MemorySettings())
        XCTAssertEqual(settings.arrangement, .orchard)
        XCTAssertTrue(settings.showsBranchNames)
        XCTAssertTrue(settings.showsRepoNames)
        XCTAssertTrue(settings.gusts)
    }

    func testUnreadableValuesTakeTheirDefaults() {
        let storage = MemorySettings()
        storage.saved = ["arrangement": "hedge", "showsBranchNames": "no", "showsRepoNames": [1], "gusts": 3]
        let settings = BackgroundSettings(storage: storage)
        XCTAssertEqual(settings.arrangement, .orchard)
        XCTAssertTrue(settings.showsBranchNames)
        XCTAssertTrue(settings.showsRepoNames)
        XCTAssertTrue(settings.gusts)
    }

    func testACopyOfTheSavedSettingsChangesWithoutWritingThem() {
        // The offscreen aids try each arrangement on a copy, so a run leaves the saved settings alone.
        let suite = "gitrasil-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        BackgroundSettings(storage: defaults).arrangement = .singleTree
        let before = defaults.persistentDomain(forName: suite) as NSDictionary?

        let copy = BackgroundSettings(storage: MemorySettings(defaults.dictionaryRepresentation()))
        XCTAssertEqual(copy.arrangement, .singleTree, "the copy starts from what's saved")
        copy.arrangement = .orchard
        copy.showsBranchNames = false
        XCTAssertEqual(copy.arrangement, .orchard)

        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, before)
        XCTAssertEqual(BackgroundSettings(storage: defaults).arrangement, .singleTree)
    }

    func testChoicesAreSavedBetweenLaunches() {
        let storage = MemorySettings()
        let settings = BackgroundSettings(storage: storage)
        settings.arrangement = .singleTree
        settings.showsBranchNames = false
        settings.gusts = false
        XCTAssertEqual(storage.saved["arrangement"] as? String, "singleTree")
        XCTAssertNil(storage.saved["showsRepoNames"], "an untouched setting isn't written")

        let relaunched = BackgroundSettings(storage: storage)
        XCTAssertEqual(relaunched.arrangement, .singleTree)
        XCTAssertFalse(relaunched.showsBranchNames)
        XCTAssertTrue(relaunched.showsRepoNames)
        XCTAssertFalse(relaunched.gusts)
    }

    func testBranchAndRepositoryNamesAreSetApart() {
        let storage = MemorySettings()
        let settings = BackgroundSettings(storage: storage)
        settings.showsRepoNames = false
        XCTAssertTrue(settings.showsBranchNames)
        XCTAssertEqual(storage.saved["showsRepoNames"] as? Bool, false)

        let relaunched = BackgroundSettings(storage: storage)
        XCTAssertFalse(relaunched.showsRepoNames)
        XCTAssertTrue(relaunched.showsBranchNames)
    }

    func testGustsBlowOnlyWithBannersToSway() {
        let settings = BackgroundSettings(storage: MemorySettings())
        XCTAssertTrue(settings.gustsBlow)

        // Only the repositories' ribbons: they hang in the single tree, not in the orchard.
        settings.showsBranchNames = false
        XCTAssertFalse(settings.hasBanners)
        XCTAssertFalse(settings.gustsBlow)
        settings.arrangement = .singleTree
        XCTAssertTrue(settings.hasBanners)
        XCTAssertTrue(settings.gustsBlow)

        settings.showsRepoNames = false
        XCTAssertFalse(settings.gustsBlow)
        settings.showsBranchNames = true
        XCTAssertTrue(settings.gustsBlow)
        settings.gusts = false
        XCTAssertFalse(settings.gustsBlow)
    }

    func testTheArrangementKeyIsTheOneEarlierBuildsSaved() {
        let suite = "gitrasil-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("singleTree", forKey: "arrangement")
        XCTAssertEqual(BackgroundSettings(storage: defaults).arrangement, .singleTree)
    }
}
