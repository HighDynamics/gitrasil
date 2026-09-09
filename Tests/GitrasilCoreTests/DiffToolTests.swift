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

    func testExplicitToolReplacesGuiFlag() {
        XCTAssertEqual(
            DiffTool.diffToolArguments(source: .commit(sha: "abc", shortSHA: "abc"), path: "a.txt", tool: "opendiff"),
            ["difftool", "--tool=opendiff", "-y", "abc^", "abc", "--", "a.txt"])
    }

    func testToolHelpParsesInstalledGUIToolsOnly() {
        let help = """
        'git difftool --tool=<tool>' may be set to one of the following:
        \t\taraxis           Use Araxis Merge (requires a graphical session)
        \t\topendiff         Use FileMerge (requires a graphical session)
        \t\tvimdiff          Use Vim
        \t\tvscode           Use Visual Studio Code (requires a graphical session)

        The following tools are valid, but not currently available:
        \t\tmeld             Use Meld (requires a graphical session)
        \t\tkdiff3           Use KDiff3 (requires a graphical session)
        """
        let tools = DiffTool.availableGUITools(fromToolHelp: help)
        // Installed GUI tools only: vimdiff (terminal) dropped; meld/kdiff3 (not available) dropped.
        XCTAssertEqual(tools, [
            DiffToolOption(id: "araxis", name: "Araxis Merge"),
            DiffToolOption(id: "opendiff", name: "FileMerge"),
            DiffToolOption(id: "vscode", name: "Visual Studio Code"),
        ])
    }

    func testToolHelpParsesEmptyWhenNoneInstalled() {
        let help = """
        'git difftool --tool=<tool>' may be set to one of the following:
        \t\tvimdiff          Use Vim

        The following tools are valid, but not currently available:
        \t\topendiff         Use FileMerge (requires a graphical session)
        """
        XCTAssertEqual(DiffTool.availableGUITools(fromToolHelp: help), [])
    }
}
