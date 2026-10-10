import XCTest
import GitrasilCore
@testable import GitrasilWallpaper

private final class MemoryPins: PinStorage {
    var pins: [Pin]
    init(_ pins: [Pin]) { self.pins = pins }
    func loadPins() -> [Pin] { pins }
    func savePins(_ pins: [Pin]) { self.pins = pins }
}

/// What the Mac is doing, as the breeze sees it, for a test to change.
@MainActor
private final class Surroundings {
    var isDisplayAwake = true
    var isPowerCheap = true
}

/// Turning gusts on blows one at once, whatever the arrangement and the power: or the moment it can be
/// seen. Nothing runs while gusts are off or can't blow.
@MainActor
final class GustOnToggleTests: XCTestCase {

    private let surroundings = Surroundings()

    private func model(arrangement: Arrangement = .singleTree, forest: Bool = false) -> BackgroundModel {
        let settings = BackgroundSettings(storage: MemorySettings())
        settings.arrangement = arrangement
        settings.showsForest = forest
        // This repository is the one pin: the settings are what's under test, not what the trees look like.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let breeze = Breeze(isDisplayAwake: { [surroundings] in surroundings.isDisplayAwake },
                            isPowerCheap: { [surroundings] in surroundings.isPowerCheap })
        let model = BackgroundModel(pins: PinnedRepositories(storage: MemoryPins([Pin(.repository, repository)])),
                                    settings: settings, breeze: breeze)
        model.start()
        return model
    }

    /// Lets the settings' observation (which hops to the main actor) run.
    private func settle() async {
        try? await Task.sleep(for: .seconds(0.2))
    }

    func testTurningGustsOnBlowsAtOnceInEveryArrangement() async {
        for arrangement in Arrangement.allCases {
            for forest in [false, true] {
                let model = model(arrangement: arrangement, forest: forest)
                await settle()
                XCTAssertNil(model.breeze.gustStart, "\(arrangement), forest \(forest): still while gusts are off")
                XCTAssertFalse(model.breeze.isArmed, "\(arrangement), forest \(forest): nothing waits while gusts are off")
                model.settings.gusts = true
                await settle()
                XCTAssertNotNil(model.breeze.gustStart, "\(arrangement), forest \(forest)")
                XCTAssertTrue(model.breeze.isArmed, "\(arrangement), forest \(forest): the next gust is awaited")
            }
        }
    }

    /// The case in the field: on battery the timer's gusts don't blow, and neither did the first.
    func testTheFirstGustBlowsOnBatteryButTheTimerStaysDisarmed() async {
        surroundings.isPowerCheap = false
        let model = model()
        await settle()
        model.settings.gusts = true
        await settle()
        XCTAssertNotNil(model.breeze.gustStart)
        XCTAssertFalse(model.breeze.isArmed, "no timer on battery")
        // Plugging in carries on with the timer's gusts, and the gust blowing isn't cut short.
        surroundings.isPowerCheap = true
        model.breeze.update()
        XCTAssertNotNil(model.breeze.gustStart)
        XCTAssertTrue(model.breeze.isArmed)
        // Unplugged again, the gust asked for still blows out its seven seconds, and the timer is disarmed.
        surroundings.isPowerCheap = false
        model.breeze.update()
        XCTAssertNotNil(model.breeze.gustStart)
        XCTAssertFalse(model.breeze.isArmed)
    }

    func testTheFirstGustWaitsForTheBackgroundToShow() async {
        let model = model()
        await settle()
        model.isVisible = false
        model.settings.gusts = true
        await settle()
        XCTAssertNil(model.breeze.gustStart)
        XCTAssertFalse(model.breeze.isArmed, "nothing runs while the background is covered")
        model.isVisible = true
        XCTAssertNotNil(model.breeze.gustStart, "the moment it shows")
        XCTAssertTrue(model.breeze.isArmed)
    }

    func testTheFirstGustWaitsForADisplayToWake() async {
        surroundings.isPowerCheap = false
        let model = model()
        await settle()
        surroundings.isDisplayAwake = false
        model.settings.gusts = true
        await settle()
        XCTAssertNil(model.breeze.gustStart)
        XCTAssertFalse(model.breeze.isArmed)
        surroundings.isDisplayAwake = true
        model.breeze.update()
        XCTAssertNotNil(model.breeze.gustStart, "the moment a display is awake, even on battery")
    }

    func testABlowingGustIsStilledByACoveredBackground() async {
        let model = model()
        await settle()
        model.settings.gusts = true
        await settle()
        XCTAssertNotNil(model.breeze.gustStart)
        model.isVisible = false
        XCTAssertNil(model.breeze.gustStart)
        XCTAssertFalse(model.breeze.isArmed)
    }

    func testTurningGustsOffBeforeTheFirstBlowsCancelsIt() async {
        let model = model()
        await settle()
        model.isVisible = false
        model.settings.gusts = true
        await settle()
        model.settings.gusts = false
        await settle()
        model.isVisible = true
        XCTAssertNil(model.breeze.gustStart, "the gust that was owed went with the setting")
        XCTAssertFalse(model.breeze.isArmed)
    }

    func testTheFirstGustIsOwedOnlyOnce() async {
        let model = model()
        await settle()
        model.isVisible = false
        model.settings.gusts = true
        await settle()
        model.isVisible = true
        XCTAssertNotNil(model.breeze.gustStart)
        model.isVisible = false
        XCTAssertNil(model.breeze.gustStart)
        model.isVisible = true
        XCTAssertNil(model.breeze.gustStart, "covering and showing again doesn't ask for another")
    }
}
