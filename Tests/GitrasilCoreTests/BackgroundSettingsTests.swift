import XCTest
@testable import GitrasilCore

@MainActor
final class BackgroundSettingsTests: XCTestCase {

    func testDefaultsUntilChosenOtherwise() {
        let settings = BackgroundSettings(storage: MemorySettings())
        XCTAssertEqual(settings.arrangement, .orchard)
        XCTAssertEqual(settings.medium, .chalk)
        XCTAssertTrue(settings.showsBranchNames)
        XCTAssertTrue(settings.showsRepoNames)
        XCTAssertFalse(settings.gusts, "the banners hang still until gusts are turned on")
    }

    func testUnreadableValuesTakeTheirDefaults() {
        let storage = MemorySettings()
        storage.saved = ["arrangement": "hedge", "medium": "crayon", "showsBranchNames": "no", "showsRepoNames": [1], "gusts": 3]
        let settings = BackgroundSettings(storage: storage)
        XCTAssertEqual(settings.arrangement, .orchard)
        XCTAssertEqual(settings.medium, .chalk)
        XCTAssertTrue(settings.showsBranchNames)
        XCTAssertTrue(settings.showsRepoNames)
        XCTAssertFalse(settings.gusts)
    }

    func testASavedGustsChoiceIsKept() {
        // Saved before gusts were off by default, or chosen since: either way it stands.
        for saved in [true, false] {
            let storage = MemorySettings()
            storage.saved = ["gusts": saved]
            XCTAssertEqual(BackgroundSettings(storage: storage).gusts, saved)
        }
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
        settings.gusts = true
        XCTAssertEqual(storage.saved["arrangement"] as? String, "singleTree")
        XCTAssertEqual(storage.saved["gusts"] as? Bool, true)
        XCTAssertNil(storage.saved["showsRepoNames"], "an untouched setting isn't written")

        let relaunched = BackgroundSettings(storage: storage)
        XCTAssertEqual(relaunched.arrangement, .singleTree)
        XCTAssertFalse(relaunched.showsBranchNames)
        XCTAssertTrue(relaunched.showsRepoNames)
        XCTAssertTrue(relaunched.gusts)
    }

    func testTheMediumIsSavedBetweenLaunches() {
        let storage = MemorySettings()
        let settings = BackgroundSettings(storage: storage)
        settings.medium = .charcoal
        XCTAssertEqual(storage.saved["medium"] as? String, "charcoal")
        XCTAssertNil(storage.saved["arrangement"], "only what changed is written")
        XCTAssertEqual(BackgroundSettings(storage: storage).medium, .charcoal)

        settings.medium = .ink
        XCTAssertEqual(BackgroundSettings(storage: storage).medium, .ink)
        settings.medium = .chalk
        XCTAssertEqual(BackgroundSettings(storage: storage).medium, .chalk)
    }

    func testASavedMediumIsKeptOverTheDefault() {
        // Whoever chose ink (or charcoal) before chalk became the default keeps it.
        for medium in [Medium.ink, .charcoal] {
            let storage = MemorySettings()
            storage.saved = ["medium": medium.rawValue]
            XCTAssertEqual(BackgroundSettings(storage: storage).medium, medium)
            XCTAssertEqual(storage.saved["medium"] as? String, medium.rawValue, "reading doesn't rewrite it")
        }
    }

    func testTheMediumIsSavedUnderAStableName() {
        // What's in a user's defaults must keep reading back after a rename in code.
        XCTAssertEqual(Medium.allCases.map(\.rawValue), ["ink", "charcoal", "chalk"])
        let suite = "gitrasil-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        BackgroundSettings(storage: defaults).medium = .charcoal
        XCTAssertEqual(defaults.string(forKey: "medium"), "charcoal")
        XCTAssertEqual(BackgroundSettings(storage: defaults).medium, .charcoal)
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
        XCTAssertFalse(settings.gustsBlow, "off until turned on")
        settings.gusts = true
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
