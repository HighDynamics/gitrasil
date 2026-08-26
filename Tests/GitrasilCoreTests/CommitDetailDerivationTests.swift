import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class CommitDetailDerivationTests: XCTestCase {

    func testCommitDetailListsModifiedAndAdded() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "1\n", message: "root")
        try repo.writeFile("a.txt", "2\n")
        try repo.writeFile("b.txt", "new\n")
        let sha = try await repo.commit("second")

        let detail = try await Derivations.commitDetail(sha: sha, runner: repo.runner)
        XCTAssertEqual(detail.fullMessage, "second")
        XCTAssertEqual(Set(detail.files.map(\.path)), ["a.txt", "b.txt"])
        XCTAssertEqual(detail.files.first { $0.path == "a.txt" }?.kind, .modified)
        XCTAssertEqual(detail.files.first { $0.path == "b.txt" }?.kind, .added)
    }

    func testRootCommitShowsAdditions() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        let sha = try await repo.commitFile("a.txt", "1\n", message: "root")

        let detail = try await Derivations.commitDetail(sha: sha, runner: repo.runner)
        XCTAssertEqual(detail.files.map(\.path), ["a.txt"])
        XCTAssertEqual(detail.files.first?.kind, .added)
    }

    func testRenameDetected() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "same content here\nline two\n", message: "root")
        try await repo.git(["mv", "a.txt", "c.txt"])
        let sha = try await repo.commit("rename")

        let detail = try await Derivations.commitDetail(sha: sha, runner: repo.runner)
        XCTAssertEqual(detail.files.count, 1)
        XCTAssertEqual(detail.files.first?.path, "c.txt")
        XCTAssertEqual(detail.files.first?.kind, .renamed(from: "a.txt"))
        XCTAssertEqual(detail.files.first?.previousPath, "a.txt")
    }

    func testRangeDetailIncludingRootCommit() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        let root = try await repo.commitFile("a.txt", "a\n", message: "root")
        let c2 = try await repo.commitFile("b.txt", "b\n", message: "c2")

        // Range whose oldest is the parentless root — must fall back to the empty tree, not throw.
        let detail = try await Derivations.rangeDetail(oldest: root, newest: c2, runner: repo.runner)
        XCTAssertEqual(detail.commitCount, 2)
        XCTAssertEqual(Set(detail.files.map(\.path)), ["a.txt", "b.txt"])
    }

    func testRangeDetailUnionsFiles() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "0\n", message: "root")
        let first = try await repo.commitFile("a.txt", "1\n", message: "c1")
        try await repo.commitFile("b.txt", "x\n", message: "c2")
        let last = try await repo.commitFile("a.txt", "2\n", message: "c3")

        let detail = try await Derivations.rangeDetail(oldest: first, newest: last, runner: repo.runner)
        XCTAssertEqual(detail.commitCount, 3)
        XCTAssertEqual(Set(detail.files.map(\.path)), ["a.txt", "b.txt"])
    }
}
