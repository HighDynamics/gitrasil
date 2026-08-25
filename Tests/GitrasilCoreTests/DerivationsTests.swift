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

    func testResolveTrunkHonorsOverride() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("README.md", "hello", message: "init")

        let trunk = try await Derivations.resolveTrunk(runner: repo.runner, override: "develop")
        XCTAssertEqual(trunk, "develop")
    }

    func testMergeBaseIsSharedRoot() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        let root = try await repo.commitFile("a.txt", "1", message: "root")

        // Branch off and add commits on both sides.
        try await repo.git(["checkout", "-q", "-b", "feature"])
        try await repo.commitFile("b.txt", "2", message: "feature work")
        try await repo.git(["checkout", "-q", "main"])
        try await repo.commitFile("c.txt", "3", message: "main work")

        let base = try await Derivations.mergeBase("main", "feature", runner: repo.runner)
        XCTAssertEqual(base, root)
    }

    func testIsDirtyReflectsWorkingTree() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "1", message: "root")

        var dirty = try await Derivations.isDirty(runner: repo.runner)
        XCTAssertFalse(dirty, "clean tree should not be dirty")

        try repo.writeFile("a.txt", "changed")
        dirty = try await Derivations.isDirty(runner: repo.runner)
        XCTAssertTrue(dirty, "uncommitted change should be dirty")
    }

    func testIsBehindWhenTrunkAdvances() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "1", message: "root")
        try await repo.git(["checkout", "-q", "-b", "feature"])
        // main advances past the fork point.
        try await repo.git(["checkout", "-q", "main"])
        try await repo.commitFile("c.txt", "3", message: "main ahead")

        let base = try await Derivations.mergeBase("main", "feature", runner: repo.runner)
        let behind = try await Derivations.isBehind(meeting: base, trunk: "main", runner: repo.runner)
        XCTAssertTrue(behind)
    }
}
