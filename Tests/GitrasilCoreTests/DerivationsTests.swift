import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class DerivationsTests: XCTestCase {

    func testResolveTrunkFindsMain() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("README.md", "hello", message: "init")

        let trunk = try await Derivations.resolveTrunk(runner: repo.runner)
        XCTAssertEqual(trunk, "main")
    }
}
