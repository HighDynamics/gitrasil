import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class LineageTests: XCTestCase {

    func testBackfillLineageAdoptsReflogSource() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.git(["branch", "parent-branch"])
        try await repo.git(["branch", "child", "parent-branch"])   // reflog: Created from parent-branch

        let before = try await Derivations.parentWorktreeBranch(of: "child", runner: repo.runner)
        XCTAssertNil(before)
        let adopted = try await Derivations.backfillLineage(for: "child", runner: repo.runner)
        XCTAssertEqual(adopted, "parent-branch")
        let after = try await Derivations.parentWorktreeBranch(of: "child", runner: repo.runner)
        XCTAssertEqual(after, "parent-branch")
    }

    func testBackfillLineageIgnoresShaSource() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        let root = try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.git(["branch", "child", root])   // reflog: Created from <sha> — ambiguous, skip

        let adopted = try await Derivations.backfillLineage(for: "child", runner: repo.runner)
        XCTAssertNil(adopted)
    }
}
