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

    func testToolHelpParsesRecognizedInstalledGUIToolsOnly() {
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
        // vimdiff (terminal) dropped; meld/kdiff3 (not available) dropped; araxis dropped as an
        // unreliable-detection false positive (its `compare` command collides with ImageMagick).
        XCTAssertEqual(tools, [
            DiffToolOption(id: "opendiff", name: "FileMerge"),
            DiffToolOption(id: "vscode", name: "Visual Studio Code"),
        ])
    }

    func testToolHelpExcludesUnrecognizedTools() {
        // Even if git reports araxis available, it's not offered (undetectable silent failure).
        let help = """
        'git difftool --tool=<tool>' may be set to one of the following:
        \t\taraxis           Use Araxis Merge (requires a graphical session)
        """
        XCTAssertEqual(DiffTool.availableGUITools(fromToolHelp: help), [])
    }

    func testBundleIDMapCoversRecognizedToolsAndExcludesAraxis() {
        // Araxis is deliberately unmapped: its git detection collides with ImageMagick's `compare`.
        XCTAssertNil(DiffTool.appBundleIDs["araxis"])
        XCTAssertEqual(DiffTool.appBundleIDs["opendiff"], ["com.apple.FileMerge"])
        XCTAssertEqual(DiffTool.appBundleIDs["vscode"], ["com.microsoft.VSCode"])
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
