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
    var isLowPowerMode = false
}

/// Turning gusts on blows one at once, whatever the arrangement and Low Power Mode: or the moment it can be
/// seen. Nothing runs while gusts are off or can't blow.
@MainActor
final class GustOnToggleTests: XCTestCase {

    private let surroundings = Surroundings()

    private func model(arrangement: Arrangement = .singleTree, forest: Bool = false, gusts: Bool = false,
                       environment: [String: String] = [:]) -> BackgroundModel {
        let settings = BackgroundSettings(storage: MemorySettings())
        settings.arrangement = arrangement
        settings.showsForest = forest
        settings.gusts = gusts
        // This repository is the one pin: the settings are what's under test, not what the trees look like.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let breeze = Breeze(environment: environment,
                            isDisplayAwake: { [surroundings] in surroundings.isDisplayAwake },
                            isLowPowerMode: { [surroundings] in surroundings.isLowPowerMode })
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

    func testAGustBlowsLongerForHangingPennantsAndHoldsAtItsStrongest() async {
        // Streaming, as it always has: sin² over seven seconds.
        for seconds in stride(from: 0.0, through: 7, by: 0.25) {
            XCTAssertEqual(Breeze.Gust.streaming.strength(at: seconds), pow(sin(.pi * seconds / 7), 2), accuracy: 1e-12)
        }
        let hanging = Breeze.Gust.hanging
        XCTAssertGreaterThan(hanging.length, Breeze.Gust.streaming.length)
        XCTAssertEqual(hanging.strength(at: 0), 0)
        XCTAssertEqual(hanging.strength(at: hanging.length), 0)
        var strong = 0.0, last = 0.0
        for seconds in stride(from: 0.0, through: hanging.length, by: 0.01) {
            let strength = hanging.strength(at: seconds)
            XCTAssertLessThan(abs(strength - last), 0.01, "it rises and falls smoothly")
            XCTAssertEqual(strength, hanging.strength(at: hanging.length - seconds), accuracy: 1e-9)
            if strength >= 0.9 { strong += 0.01 }
            last = strength
        }
        XCTAssertGreaterThan(strong, 3.5, "nearly level for a few seconds, not a moment")
        // The model tells the breeze which.
        let model = model()
        await settle()
        model.settings.hangsBanners = true
        model.settings.gusts = true
        await settle()
        XCTAssertEqual(model.breeze.gust, .hanging)
        XCTAssertTrue(model.breeze.hangs)
    }

    /// The case in the field was the power gate: the first gust was held back as the timer's are.
    func testTheFirstGustBlowsInLowPowerModeButTheTimerStaysDisarmed() async {
        surroundings.isLowPowerMode = true
        let model = model()
        await settle()
        model.settings.gusts = true
        await settle()
        XCTAssertNotNil(model.breeze.gustStart)
        XCTAssertFalse(model.breeze.isArmed, "no timer in Low Power Mode")
        // Leaving Low Power Mode carries on with the timer's gusts, and the gust blowing isn't cut short.
        surroundings.isLowPowerMode = false
        model.breeze.update()
        XCTAssertNotNil(model.breeze.gustStart)
        XCTAssertTrue(model.breeze.isArmed)
        // Back in it, the gust asked for still blows out its seven seconds, and the timer is disarmed.
        surroundings.isLowPowerMode = true
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
        surroundings.isLowPowerMode = true
        let model = model()
        await settle()
        surroundings.isDisplayAwake = false
        model.settings.gusts = true
        await settle()
        XCTAssertNil(model.breeze.gustStart)
        XCTAssertFalse(model.breeze.isArmed)
        surroundings.isDisplayAwake = true
        model.breeze.update()
        XCTAssertNotNil(model.breeze.gustStart, "the moment a display is awake, even in Low Power Mode")
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

    func testTurningTheBannersOffWhileAGustIsOwedDropsIt() async {
        let model = model()
        await settle()
        model.isVisible = false
        model.settings.gusts = true
        await settle()
        model.settings.showsBranchNames = false
        model.settings.showsRepoNames = false
        await settle()
        model.isVisible = true
        XCTAssertNil(model.breeze.gustStart, "with nothing hanging there is nothing to sway")
        XCTAssertFalse(model.breeze.isArmed)
    }

    func testTheBreezeTurnedOffFromOutsideBlowsNoFirstGust() async {
        let model = model(environment: ["GITRASIL_BACKGROUND_BREEZE": "off"])
        await settle()
        model.settings.gusts = true
        await settle()
        XCTAssertNil(model.breeze.gustStart)
        XCTAssertFalse(model.breeze.isArmed)
        model.isVisible = false
        model.isVisible = true
        XCTAssertNil(model.breeze.gustStart, "and none is owed")
    }

    func testADisplaySleepingMidGustStillsIt() async {
        surroundings.isLowPowerMode = true
        let model = model()
        await settle()
        model.settings.gusts = true
        await settle()
        XCTAssertNotNil(model.breeze.gustStart)
        surroundings.isDisplayAwake = false
        model.breeze.update()
        XCTAssertNil(model.breeze.gustStart, "the gust asked for goes too, though Low Power Mode didn't stop it")
        XCTAssertFalse(model.breeze.isArmed)
    }

    func testATimersGustStaysStillInLowPowerMode() async {
        surroundings.isLowPowerMode = true
        let model = model(gusts: true)
        await settle()
        XCTAssertFalse(model.breeze.isArmed, "no timer in Low Power Mode")
        // The timer firing on a missed notification looks at the state again.
        model.breeze.gust()
        XCTAssertNil(model.breeze.gustStart)
        XCTAssertFalse(model.breeze.isArmed)
        surroundings.isLowPowerMode = false
        model.breeze.gust()
        XCTAssertNotNil(model.breeze.gustStart, "the same gust out of Low Power Mode blows")
    }
}
