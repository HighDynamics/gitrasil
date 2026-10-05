import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

/// In memory, so tests never write to the user's preferences.
private final class MemoryPins: PinStorage {
    var paths: [String] = []
    func loadPins() -> [String] { paths }
    func savePins(_ paths: [String]) { self.paths = paths }
}

@MainActor
final class PinnedRepositoriesTests: XCTestCase {

    private let storage = MemoryPins()

    private func repo() async throws -> FixtureRepo {
        let r = try FixtureRepo()
        try await r.initRepo()
        try await r.commitFile("a.txt", "1", message: "root")
        return r
    }

    func testAddPinsTheRepositoryTopAndPersists() async throws {
        let repo = try await repo()
        try FileManager.default.createDirectory(at: repo.url.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let pins = PinnedRepositories(storage: storage)

        let pinned = try await pins.add(repo.url.appendingPathComponent("sub"))

        let top = repo.url.resolvingSymlinksInPath()
        XCTAssertEqual(pinned.path, top.path, "a subfolder pins its repository's top")
        XCTAssertEqual(pins.urls.map(\.path), [top.path])
        XCTAssertEqual(PinnedRepositories(storage: storage).urls.map(\.path), [top.path], "saved between launches")
    }

    func testRejectsAFolderOutsideAnyRepository() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitrasil-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pins = PinnedRepositories(storage: storage)

        do {
            try await pins.add(dir)
            XCTFail("expected notARepository")
        } catch let error as PinnedRepositories.PinError {
            XCTAssertEqual(error, .notARepository(path: dir.path))
        }
        do {
            try await pins.add(dir.appendingPathComponent("missing"))
            XCTFail("expected notARepository for a missing folder")
        } catch is PinnedRepositories.PinError {}
        XCTAssertTrue(pins.urls.isEmpty)
    }

    func testTheSameRepositoryPinsOnceWhicheverFolderIsPicked() async throws {
        let repo = try await repo()
        let worktree = repo.url.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString)")
        try await repo.git(["worktree", "add", "-q", "-b", "side", worktree.path])
        defer { try? FileManager.default.removeItem(at: worktree) }
        let pins = PinnedRepositories(storage: storage)

        try await pins.add(repo.url)
        for folder in [repo.url, worktree] {
            do {
                try await pins.add(folder)
                XCTFail("expected alreadyPinned for \(folder.path)")
            } catch let error as PinnedRepositories.PinError {
                XCTAssertEqual(error, .alreadyPinned(path: repo.url.resolvingSymlinksInPath().path))
            }
        }
        XCTAssertEqual(pins.urls.count, 1)
    }

    func testRemoveUnpinsAndPersists() async throws {
        let a = try await repo(), b = try await repo()
        let pins = PinnedRepositories(storage: storage)
        let pinnedA = try await pins.add(a.url)
        let pinnedB = try await pins.add(b.url)

        pins.remove(pinnedA)

        XCTAssertEqual(pins.urls, [pinnedB])
        XCTAssertEqual(PinnedRepositories(storage: storage).urls.map(\.path), [pinnedB.path])
    }

    func testTheSuiteOverride() {
        XCTAssertEqual(PinnedRepositories.appSuiteName(environment: [:]), "com.gitrasil.background")
        XCTAssertEqual(PinnedRepositories.appSuiteName(
            environment: [PinnedRepositories.suiteOverrideVariable: "scratch"]), "scratch")
    }
}
