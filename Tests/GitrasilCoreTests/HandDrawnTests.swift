import XCTest
@testable import GitrasilCore

final class HandDrawnTests: XCTestCase {

    func testTheWobbleIsTheSameEveryTime() {
        let seed = HandDrawn.seed("feature/sprout", 3)
        XCTAssertEqual(seed, HandDrawn.seed("feature/sprout", 3), "a seed is a pure function of its key")
        let first = stride(from: 0.0, to: 20, by: 0.37).map { HandDrawn.wobble(seed, at: $0) }
        let again = stride(from: 0.0, to: 20, by: 0.37).map { HandDrawn.wobble(seed, at: $0) }
        XCTAssertEqual(first, again)
        // Pinned, so a stroke looks the same on every launch and build: a change here would reshape
        // every line on screen.
        XCTAssertEqual(HandDrawn.wobble(HandDrawn.seed("main"), at: 2.5), 0.4064188368942969, accuracy: 1e-12)
    }

    func testTheWobbleStaysInRangeAndMovesSmoothly() {
        let seed = HandDrawn.seed("trunk")
        var previous = HandDrawn.wobble(seed, at: 0)
        var lowest = 1.0, highest = -1.0
        for step in 1...4000 {
            let value = HandDrawn.wobble(seed, at: Double(step) * 0.01)
            XCTAssert((-1...1).contains(value))
            XCTAssertLessThan(abs(value - previous), 0.1, "no jumps at \(Double(step) * 0.01)")
            lowest = min(lowest, value)
            highest = max(highest, value)
            previous = value
        }
        XCTAssertGreaterThan(highest - lowest, 0.8, "it does wander")
    }

    func testDifferentLinesWobbleDifferently() {
        let a = (0..<50).map { HandDrawn.wobble(HandDrawn.seed("fix/moderation"), at: Double($0) * 0.5) }
        let b = (0..<50).map { HandDrawn.wobble(HandDrawn.seed("fix/connections"), at: Double($0) * 0.5) }
        let c = (0..<50).map { HandDrawn.wobble(HandDrawn.seed("fix/moderation", 1), at: Double($0) * 0.5) }
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testALineDrawnFurtherKeepsItsEarlierWobble() {
        let line = (0...40).map { CGPoint(x: Double($0) * 6, y: sin(Double($0) / 7) * 30) }
        let seed = HandDrawn.seed("worktree-review")
        let whole = HandDrawn.displace(line, seed: seed, amplitude: 1.5, wavelength: 40)
        let start = HandDrawn.displace(Array(line.prefix(25)), seed: seed, amplitude: 1.5, wavelength: 40)
        // All but the last point of the shorter line, whose normal turns with the new stretch.
        for i in 0..<24 {
            XCTAssertEqual(whole[i].x, start[i].x, accuracy: 1e-9)
            XCTAssertEqual(whole[i].y, start[i].y, accuracy: 1e-9)
        }
    }

    func testDisplacingStaysNearTheLineAndOffIsOff() {
        let line = (0...30).map { CGPoint(x: Double($0) * 5, y: 0) }
        let rough = HandDrawn.displace(line, seed: HandDrawn.seed("ground"), amplitude: 2, wavelength: 30)
        XCTAssertEqual(rough.count, line.count)
        XCTAssert(zip(rough, line).allSatisfy { abs($0.y - $1.y) <= 2 && $0.x == $1.x })
        XCTAssert(rough.contains { abs($0.y) > 0.3 }, "it wobbles")
        XCTAssertEqual(HandDrawn.displace(line, seed: 1, amplitude: 0, wavelength: 30), line)
    }

    func testANoiseTileIsStableInRangeAndRepeats() {
        let octaves = [(wavelength: 4, weight: 0.5), (wavelength: 16, weight: 0.5)]
        let tile = HandDrawn.noiseTile(size: 64, seed: 42, octaves: octaves, speckle: 0.2)
        XCTAssertEqual(tile.count, 64 * 64)
        XCTAssertEqual(tile, HandDrawn.noiseTile(size: 64, seed: 42, octaves: octaves, speckle: 0.2))
        XCTAssertNotEqual(tile, HandDrawn.noiseTile(size: 64, seed: 43, octaves: octaves, speckle: 0.2))
        XCTAssert(tile.allSatisfy { (0...1).contains($0) })

        // Seamless: across the wrap the smooth part steps no more than within the tile.
        let smooth = HandDrawn.noiseTile(size: 64, seed: 7, octaves: octaves)
        func at(_ x: Int, _ y: Int) -> Double { smooth[y * 64 + x] }
        let inside = (0..<64).map { abs(at(30, $0) - at(31, $0)) }.max()!
        let wrap = (0..<64).map { abs(at(63, $0) - at(0, $0)) }.max()!
        let wrapRows = (0..<64).map { abs(at($0, 63) - at($0, 0)) }.max()!
        XCTAssertLessThan(wrap, max(inside, 0.05) * 2)
        XCTAssertLessThan(wrapRows, max(inside, 0.05) * 2)
    }

    func testAStemsOwnPressureIsAtFixedDistances() {
        let seed = HandDrawn.seed("trunk")
        let pressure = HandDrawn.pressure(seed: seed, amount: 0.4, length: 250)
        XCTAssertEqual(pressure.map(\.distance), [0, 90, 180, 250])
        for point in pressure {
            XCTAssertEqual(point.strength, 1 - 0.4 * (1 + HandDrawn.wobble(seed, at: point.distance / 90)) / 2, accuracy: 1e-12)
        }
        XCTAssertEqual(HandDrawn.pressure(seed: seed, amount: 0, length: 250).map(\.strength), [1, 1, 1, 1], "even with none")

        // Growing longer keeps the pressure along the old stretch, up to its last fixed point.
        let longer = HandDrawn.pressure(seed: seed, amount: 0.4, length: 400)
        for distance in stride(from: 0.0, through: 180, by: 7) {
            XCTAssertEqual(HandDrawn.strength(pressure, at: distance), HandDrawn.strength(longer, at: distance), accuracy: 1e-12)
        }
    }

    func testALimbStartsAtItsParentsPressureAndEasesIntoItsOwn() {
        let seed = HandDrawn.seed("feature/sprout", 2)
        let own = HandDrawn.pressure(seed: seed, amount: 0.4, length: 300)
        let limb = HandDrawn.pressure(seed: seed, amount: 0.4, length: 300, fork: (strength: 0.95, collar: 60))
        XCTAssertEqual(HandDrawn.strength(limb, at: 0), 0.95, accuracy: 1e-12, "no step where it leaves its parent")
        for distance in stride(from: 60.0, through: 300, by: 5) {
            XCTAssertEqual(HandDrawn.strength(limb, at: distance), HandDrawn.strength(own, at: distance), accuracy: 1e-12,
                           "past its collar it's its own, at \(distance)")
        }
        // Along the collar it moves steadily from its parent's to its own.
        var previous = 1.0
        for distance in [15.0, 30, 45] {
            let ownStrength = HandDrawn.strength(own, at: distance)
            let share = (HandDrawn.strength(limb, at: distance) - ownStrength) / (0.95 - ownStrength)
            XCTAssert((0...1).contains(share))
            XCTAssertLessThan(share, previous)
            previous = share
        }
        // A limb shorter than its collar still ends where it ends.
        let stub = HandDrawn.pressure(seed: seed, amount: 0.4, length: 40, fork: (strength: 0.9, collar: 60))
        XCTAssertEqual(stub.first?.distance, 0)
        XCTAssertEqual(stub.last?.distance, 40)
        XCTAssertEqual(stub.map(\.distance), stub.map(\.distance).sorted())
    }
}
