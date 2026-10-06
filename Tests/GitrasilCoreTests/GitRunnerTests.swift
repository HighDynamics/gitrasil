import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class GitRunnerTests: XCTestCase {

    func testEnvironmentDropsRepositorySelectorsAndKeepsTheRest() {
        let environment = GitRunner.environment(
            inherited: ["GIT_DIR": "/elsewhere/.git", "GIT_WORK_TREE": "/elsewhere", "GIT_INDEX_FILE": "/i",
                        "GIT_PREFIX": ".", "PATH": "/usr/bin", "GIT_EDITOR": "vim"],
            extra: ["GIT_EDITOR": "true"])

        XCTAssertNil(environment["GIT_DIR"])
        XCTAssertNil(environment["GIT_WORK_TREE"])
        XCTAssertNil(environment["GIT_INDEX_FILE"])
        XCTAssertNil(environment["GIT_PREFIX"])
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["GIT_EDITOR"], "true", "extra wins over inherited")
    }

    /// Daniel launched the background from a terminal whose editor had been opened by
    /// `git difftool` in another repository, so the app inherited GIT_DIR/GIT_WORK_TREE for it and
    /// every pin resolved to that repository. The workdir must decide.
    @MainActor
    func testAnInheritedGitDirDoesNotRedirectTheRunner() async throws {
        let other = try FixtureRepo(), a = try FixtureRepo(), b = try FixtureRepo()
        for repo in [other, a, b] {
            try await repo.initRepo()
            try await repo.commitFile("x.txt", "1", message: "root")
        }
        setenv("GIT_DIR", other.url.appendingPathComponent(".git").path, 1)
        setenv("GIT_WORK_TREE", other.url.path, 1)
        defer { unsetenv("GIT_DIR"); unsetenv("GIT_WORK_TREE") }

        let top = try await GitRunner(workdir: a.url).runChecked(["rev-parse", "--show-toplevel"]).trimmedStdout
        XCTAssertEqual(URL(fileURLWithPath: top).resolvingSymlinksInPath(), a.url.resolvingSymlinksInPath())

        final class MemoryPins: PinStorage {
            var pins: [Pin] = []
            func loadPins() -> [Pin] { pins }
            func savePins(_ pins: [Pin]) { self.pins = pins }
        }
        let pins = PinnedRepositories(storage: MemoryPins())
        let pinnedA = try await pins.add(a.url)
        let pinnedB = try await pins.add(b.url)   // failed as "already pinned" before the fix
        XCTAssertEqual(pinnedA.url, a.url.resolvingSymlinksInPath())
        XCTAssertEqual(pinnedB.url, b.url.resolvingSymlinksInPath())
    }
}
