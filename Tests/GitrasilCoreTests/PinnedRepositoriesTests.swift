import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

/// In memory, so tests never write to the user's preferences.
private final class MemoryPins: PinStorage {
    var pins: [Pin] = []
    func loadPins() -> [Pin] { pins }
    func savePins(_ pins: [Pin]) { self.pins = pins }
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
        XCTAssertEqual(pinned, Pin(.repository, top), "a subfolder pins its repository's top")
        XCTAssertEqual(pins.pins.map(\.url.path), [top.path])
        XCTAssertEqual(pins.shown.map(\.path), [top.path])
        XCTAssertEqual(PinnedRepositories(storage: storage).pins.map(\.url.path), [top.path], "saved between launches")
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
        XCTAssertTrue(pins.pins.isEmpty)
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
        XCTAssertEqual(pins.pins.count, 1)
    }

    func testRemoveUnpinsAndPersists() async throws {
        let a = try await repo(), b = try await repo()
        let pins = PinnedRepositories(storage: storage)
        let pinnedA = try await pins.add(a.url)
        let pinnedB = try await pins.add(b.url)

        pins.remove(pinnedA)

        XCTAssertEqual(pins.pins, [pinnedB])
        XCTAssertEqual(PinnedRepositories(storage: storage).pins.map(\.url.path), [pinnedB.url.path])
    }

    // MARK: Folder pins

    /// A folder laid out for pinning: repositories (a `.git` folder each; looking in a folder runs no
    /// git) one level down, two through a plain subfolder, and linked worktrees (a `.git` file).
    private func folder(_ layout: [String: String?]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitrasil-folder-\(UUID().uuidString)").resolvingSymlinksInPath()
        for (path, worktreeOf) in layout {
            let repo = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            if let main = worktreeOf {
                let gitdir = root.appendingPathComponent(main).appendingPathComponent(".git/worktrees/\(repo.lastPathComponent)")
                try "gitdir: \(gitdir.path)\n".write(to: repo.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
            } else {
                try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/logs"), withIntermediateDirectories: true)
                try "ref: refs/heads/main\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func touch(_ repo: URL, daysAgo: Double) throws {
        let log = repo.appendingPathComponent(".git/logs/HEAD")
        try "x\n".write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -daysAgo * 86_400)],
                                              ofItemAtPath: log.path)
    }

    func testAFolderHoldingRepositoriesIsPinnedAsAFolder() async throws {
        let root = try folder(["elm": nil, "ash": nil, "work/rowan": nil, "ash-wasm": "ash", "elsewhere-wt": "gone",
                               "notes": nil])
        try FileManager.default.removeItem(at: root.appendingPathComponent("notes/.git"))   // a plain folder
        let pins = PinnedRepositories(storage: storage)

        let pin = try await pins.add(root)

        XCTAssertEqual(pin, Pin(.folder, root))
        XCTAssertEqual(pins.contents[pin.url]?.map(\.lastPathComponent), ["ash", "elm", "elsewhere-wt", "rowan"],
                       "two levels down through a plain folder, in name order; a worktree of a repository there is left out")
        XCTAssertEqual(pins.shown, pins.contents[pin.url])
        XCTAssertEqual(storage.pins, [Pin(.folder, root)])
        do {
            try await pins.add(root)
            XCTFail("expected alreadyPinned")
        } catch let error as PinnedRepositories.PinError {
            XCTAssertEqual(error, .alreadyPinned(path: root.path))
        }
    }

    func testAFolderWithMoreThanFitShowsTheMostRecentlyActiveInNameOrder() throws {
        let root = try folder(["a": nil, "b": nil, "c": nil, "d": nil, "e": nil, "f": nil])
        for (name, days) in [("a", 9.0), ("b", 1), ("c", 30), ("d", 2), ("e", 3), ("f", 0.5)] {
            try touch(root.appendingPathComponent(name), daysAgo: days)
        }
        storage.pins = [Pin(.folder, root)]
        let pins = PinnedRepositories(storage: storage, limit: 4)

        XCTAssertEqual(pins.shown.map(\.lastPathComponent), ["b", "d", "e", "f"])
        XCTAssertTrue(pins.shownCount(of: Pin(.folder, root)) == (4, 6))

        try touch(root.appendingPathComponent("c"), daysAgo: 0)
        pins.refresh()
        XCTAssertEqual(pins.shown.map(\.lastPathComponent), ["b", "c", "d", "f"], "re-ranked when refreshed")
    }

    func testPinsExpandInOrderUpToTheLimitAndARepositoryShowsOnce() {
        let folder = URL(fileURLWithPath: "/r"), x = URL(fileURLWithPath: "/x")
        let inside = ["a", "b", "c"].map { URL(fileURLWithPath: "/r/\($0)") }
        let activity = [inside[0]: Date(timeIntervalSince1970: 3), inside[1]: Date(timeIntervalSince1970: 1),
                        inside[2]: Date(timeIntervalSince1970: 2)]
        func resolve(_ pins: [Pin], limit: Int = 4) -> [String] {
            PinnedRepositories.resolve(pins, contents: [Pin(.folder, folder).url: inside], activity: activity, limit: limit).map(\.path)
        }

        XCTAssertEqual(resolve([Pin(.repository, x), Pin(.folder, folder)]), ["/x", "/r/a", "/r/b", "/r/c"])
        XCTAssertEqual(resolve([Pin(.repository, x), Pin(.folder, folder)], limit: 3), ["/x", "/r/a", "/r/c"],
                       "the two most recently active, in name order")
        XCTAssertEqual(resolve([Pin(.folder, folder), Pin(.repository, x)], limit: 3), ["/r/a", "/r/b", "/r/c"],
                       "a pin after the limit isn't shown")
        XCTAssertEqual(resolve([Pin(.repository, inside[1]), Pin(.folder, folder)]), ["/r/b", "/r/a", "/r/c"],
                       "a repository pinned on its own isn't shown again for its folder")
    }

    func testAPinnedFolderPicksUpARepositoryAddedLater() async throws {
        let root = try folder(["ash": nil, "work/elm": nil])
        storage.pins = [Pin(.folder, root)]
        let pins = PinnedRepositories(storage: storage)
        XCTAssertEqual(pins.shown.map(\.lastPathComponent), ["ash", "elm"])

        try FileManager.default.createDirectory(at: root.appendingPathComponent("work/oak/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("birch/.git"), withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: root.appendingPathComponent("ash"))

        let deadline = Date().addingTimeInterval(5)
        while pins.shown.map(\.lastPathComponent) != ["birch", "elm", "oak"], Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(pins.shown.map(\.lastPathComponent), ["birch", "elm", "oak"], "seen by watching, without a refresh")
    }

    func testAnUnpinnedPinGoesBackInItsPlace() {
        let a = Pin(.repository, URL(fileURLWithPath: "/a")), b = Pin(.folder, URL(fileURLWithPath: "/b")),
            c = Pin(.repository, URL(fileURLWithPath: "/c"))
        storage.pins = [a, b, c]
        let pins = PinnedRepositories(storage: storage)

        pins.remove(b)
        pins.remove(a)
        XCTAssertEqual(pins.pins, [c])
        pins.insert(b, at: 0)
        pins.insert(a, at: 0)
        pins.insert(a, at: 2)
        XCTAssertEqual(pins.pins, [a, b, c], "and never twice")
        XCTAssertEqual(storage.pins, [a, b, c])
    }

    func testPinsAreSavedWithTheirKindAndTheOldListStillWritten() throws {
        let suite = "com.gitrasil.tests.pins-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/old/a", "/old/b"], forKey: "pinnedRepositories")
        XCTAssertEqual(defaults.loadPins(), [Pin(.repository, URL(fileURLWithPath: "/old/a")),
                                             Pin(.repository, URL(fileURLWithPath: "/old/b"))],
                       "an older build's pins load as repositories")

        let saved = [Pin(.repository, URL(fileURLWithPath: "/a")), Pin(.folder, URL(fileURLWithPath: "/repos"))]
        defaults.savePins(saved)

        XCTAssertEqual(defaults.loadPins(), saved)
        XCTAssertEqual(defaults.stringArray(forKey: "pinnedRepositories"), ["/a"],
                       "an older build still sees the repository pins")
    }

    func testTheSuiteOverride() {
        XCTAssertEqual(PinnedRepositories.appSuiteName(environment: [:]), "com.gitrasil.background")
        XCTAssertEqual(PinnedRepositories.appSuiteName(
            environment: [PinnedRepositories.suiteOverrideVariable: "scratch"]), "scratch")
    }

    func testSeedsAreTheNameUnlessAnEarlierRepositoryHasIt() {
        let seeds = PinnedRepositories.seeds([URL(fileURLWithPath: "/work/app"), URL(fileURLWithPath: "/work/lib"),
                                              URL(fileURLWithPath: "/home/app"), URL(fileURLWithPath: "/old/app")])
        XCTAssertEqual(seeds[0], "app", "the first keeps its name, so its tree keeps its shape")
        XCTAssertEqual(seeds[1], "lib")
        XCTAssertEqual(Set(seeds).count, 4, "two folders with one name grow differently")
        XCTAssertTrue(seeds[2].hasSuffix("/home/app"))
        XCTAssertEqual(PinnedRepositories.seeds([URL(fileURLWithPath: "/home/app")]), ["app"],
                       "once alone again, a repository's seed is its name")
    }
}
