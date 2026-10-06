import XCTest
@testable import GitrasilCore

/// In memory, so tests never write to the user's preferences.
private final class MemoryArrangement: ArrangementStorage {
    var saved: String?
    func loadArrangement() -> String? { saved }
    func saveArrangement(_ value: String) { saved = value }
}

@MainActor
final class ArrangementSettingTests: XCTestCase {

    func testAnOrchardUntilChosenOtherwise() {
        XCTAssertEqual(ArrangementSetting(storage: MemoryArrangement()).value, .orchard)
        let unknown = MemoryArrangement()
        unknown.saved = "hedge"
        XCTAssertEqual(ArrangementSetting(storage: unknown).value, .orchard)
    }

    func testTheChoiceIsSavedBetweenLaunches() {
        let storage = MemoryArrangement()
        ArrangementSetting(storage: storage).value = .singleTree
        XCTAssertEqual(storage.saved, "singleTree")
        XCTAssertEqual(ArrangementSetting(storage: storage).value, .singleTree)
    }
}
