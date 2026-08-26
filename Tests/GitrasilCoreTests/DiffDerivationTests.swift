import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class DiffDerivationTests: XCTestCase {

    func testExplorerDiffAgainstMeetingBase() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        let base = try await repo.commitFile("a.txt", "base\n", message: "root")
        try await repo.commitFile("a.txt", "changed\n", message: "edit")

        let diff = try await Derivations.fileDiff(
            source: .explorer(meetingBase: base), path: "a.txt", runner: repo.runner)
        XCTAssertEqual(diff.label, "base → working tree")
        XCTAssertTrue(diff.unifiedText.contains("-base"))
        XCTAssertTrue(diff.unifiedText.contains("+changed"))
        XCTAssertFalse(diff.isBinary)
    }

    func testCommitDiffUsesParent() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "base\n", message: "root")
        let sha = try await repo.commitFile("a.txt", "changed\n", message: "edit")
        let short = try await repo.git(["rev-parse", "--short", sha])

        let diff = try await Derivations.fileDiff(
            source: .commit(sha: sha, shortSHA: short), path: "a.txt", runner: repo.runner)
        XCTAssertEqual(diff.label, "parent → \(short)")
        XCTAssertTrue(diff.unifiedText.contains("+changed"))
    }

    func testRootCommitDiffFallsBackToEmptyTree() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        let sha = try await repo.commitFile("a.txt", "hello\n", message: "root")
        let short = try await repo.git(["rev-parse", "--short", sha])

        let diff = try await Derivations.fileDiff(
            source: .commit(sha: sha, shortSHA: short), path: "a.txt", runner: repo.runner)
        XCTAssertTrue(diff.unifiedText.contains("+hello"), "root commit shows its addition")
    }

    func testUnchangedFileHasEmptyDiff() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        let base = try await repo.commitFile("a.txt", "base\n", message: "root")
        try await repo.commitFile("b.txt", "other\n", message: "unrelated")

        let diff = try await Derivations.fileDiff(
            source: .explorer(meetingBase: base), path: "a.txt", runner: repo.runner)
        XCTAssertTrue(diff.isEmpty, "a.txt is unchanged since base")
    }

    func testBinaryDiffFlagged() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        let bytes = Data([0x00, 0x01, 0x02, 0xff, 0x00, 0x10])
        try bytes.write(to: repo.url.appendingPathComponent("blob.bin"))
        try await repo.commit("add binary")
        try Data([0x00, 0xff, 0xfe, 0x00]).write(to: repo.url.appendingPathComponent("blob.bin"))
        let sha = try await repo.commit("change binary")
        let short = try await repo.git(["rev-parse", "--short", sha])

        let diff = try await Derivations.fileDiff(
            source: .commit(sha: sha, shortSHA: short), path: "blob.bin", runner: repo.runner)
        XCTAssertTrue(diff.isBinary)
    }

    func testIsBinaryDiffParser() {
        XCTAssertTrue(Derivations.isBinaryDiff("diff --git a/x b/x\nBinary files a/x and b/x differ\n"))
        XCTAssertFalse(Derivations.isBinaryDiff("@@ -1 +1 @@\n-a\n+b\n"))
    }
}
