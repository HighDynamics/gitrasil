import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class WorkingTreeStatusDerivationTests: XCTestCase {

    func testModifiedUntrackedDeleted() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("keep.txt", "k\n", message: "root")
        try await repo.commitFile("gone.txt", "g\n", message: "second")

        try repo.writeFile("keep.txt", "changed\n")                        // modified
        try repo.writeFile("new.txt", "n\n")                               // untracked
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("gone.txt")) // deleted

        let status = try await Derivations.workingTreeStatus(runner: repo.runner)
        XCTAssertEqual(status["keep.txt"], .modified)
        XCTAssertEqual(status["new.txt"], .untracked)
        XCTAssertEqual(status["gone.txt"], .deleted)
    }

    func testRenameStatus() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "content that is long enough to match\n", message: "root")
        try await repo.git(["mv", "a.txt", "b.txt"])

        let status = try await Derivations.workingTreeStatus(runner: repo.runner)
        XCTAssertEqual(status["b.txt"], .renamed)
    }

    func testCleanTreeIsEmpty() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")

        let status = try await Derivations.workingTreeStatus(runner: repo.runner)
        XCTAssertTrue(status.isEmpty)
    }

    func testIgnoredPaths() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile(".gitignore", "build/\n*.log\n", message: "root")
        try repo.writeFile("build/artifact.o", "x")
        try repo.writeFile("debug.log", "log")

        let ignored = try await Derivations.ignoredPaths(runner: repo.runner)
        XCTAssertTrue(ignored.contains("build/"), "fully-ignored dir collapses to build/")
        XCTAssertTrue(ignored.contains("debug.log"))
    }
}
