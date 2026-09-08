import XCTest
@testable import GitrasilCore

/// The `git difftool` argument builder is pure (no I/O), so one case per `DiffSource` fully covers
/// it — no FixtureRepo needed.
final class DiffToolTests: XCTestCase {

    func testExplorerArguments() {
        XCTAssertEqual(
            DiffTool.diffToolArguments(source: .explorer(meetingBase: "abc123"), path: "src/a.txt"),
            ["difftool", "-g", "-y", "abc123", "--", "src/a.txt"])
    }

    func testCommitArguments() {
        XCTAssertEqual(
            DiffTool.diffToolArguments(source: .commit(sha: "deadbeef", shortSHA: "dead"), path: "a.txt"),
            ["difftool", "-g", "-y", "deadbeef^", "deadbeef", "--", "a.txt"])
    }

    func testRangeArguments() {
        XCTAssertEqual(
            DiffTool.diffToolArguments(
                source: .range(oldest: "old111", newest: "new222", newestShort: "new2"), path: "a.txt"),
            ["difftool", "-g", "-y", "old111^", "new222", "--", "a.txt"])
    }

    func testAgainstArguments() {
        XCTAssertEqual(
            DiffTool.diffToolArguments(source: .against(ref: "main"), path: "dir/b.bin"),
            ["difftool", "-g", "-y", "main", "--", "dir/b.bin"])
    }
}
