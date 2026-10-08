import XCTest
@testable import GitrasilCore

final class ReleaseVersionTests: XCTestCase {

    func testReadsTagsAndPlainVersions() {
        XCTAssertEqual(ReleaseVersion("v1.2.3")?.numbers, [1, 2, 3])
        XCTAssertEqual(ReleaseVersion("0.10")?.numbers, [0, 10])
        XCTAssertEqual(ReleaseVersion("v2")?.description, "2")
    }

    func testAnythingElseIsntAVersion() {
        for text in ["", "v", "1..2", "1.2.", ".1", "1.2.3-beta", "v1.2 ", "release", "-1.0", "+1.0", "V1.0", "1.99999999999"] {
            XCTAssertNil(ReleaseVersion(text), text)
        }
    }

    func testDigitsAreASCIIOnly() {
        // A digit with a combining mark is one Character that sorts among "0"..."9"; other scripts'
        // digits are numbers to Swift's Character but not to Int.
        for text in ["v5\u{301}.0", "1.2\u{20DD}", "\u{661}.\u{662}", "\u{FF11}.0", "1.\u{0663}"] {
            XCTAssertNil(ReleaseVersion(text), text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))
        }
    }

    func testOrdersByNumberNotByText() {
        XCTAssertLessThan(ReleaseVersion("0.9.0")!, ReleaseVersion("0.10.0")!)
        XCTAssertLessThan(ReleaseVersion("1.2")!, ReleaseVersion("1.2.1")!)
        XCTAssertLessThan(ReleaseVersion("1.9.9")!, ReleaseVersion("2")!)
        XCTAssertEqual(ReleaseVersion("1.2")!, ReleaseVersion("v1.2.0")!, "a missing number counts as 0")
        XCTAssertFalse(ReleaseVersion("1.2")! < ReleaseVersion("1.2.0")!)
    }
}

@MainActor
final class UpdateCheckTests: XCTestCase {

    /// A stand-in for GitHub: answers each request with `status` and `body`, and records it.
    final class FakeGitHub: @unchecked Sendable {
        var status = 200
        var body = Data()
        var error: Error?
        private(set) var requests: [URLRequest] = []

        func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) {
            status = 200
            body = Data("""
                {"tag_name": "\(tag)", "html_url": "https://example.com/elsewhere", "draft": \(draft), "prerelease": \(prerelease), "name": "Gitrasil"}
                """.utf8)
        }

        var fetch: UpdateCheck.Fetch {
            { request in
                self.requests.append(request)
                if let error = self.error { throw error }
                let response = HTTPURLResponse(url: request.url!, statusCode: self.status, httpVersion: nil, headerFields: nil)!
                return (self.body, response)
            }
        }
    }

    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let github = FakeGitHub()

    private func check(_ current: String = "0.1.0", storage: MemorySettings = MemorySettings()) -> UpdateCheck {
        UpdateCheck(current: ReleaseVersion(current)!, repository: "HighDynamics/gitrasil", storage: storage,
                    fetch: github.fetch, now: { [unowned self] in clock })
    }

    func testOffUntilTurnedOn() async {
        let storage = MemorySettings()
        let updates = check(storage: storage)
        XCTAssertFalse(updates.isEnabled)
        await updates.checkIfDue()
        XCTAssertTrue(github.requests.isEmpty, "nothing is sent until daily checks are turned on")

        updates.isEnabled = true
        XCTAssertEqual(storage.saved["checksForUpdates"] as? Bool, true)
        XCTAssertTrue(check(storage: storage).isEnabled, "the choice is kept")
    }

    func testAtMostDaily() async {
        github.release("v0.1.0")
        let updates = check()
        updates.isEnabled = true
        await updates.checkIfDue()
        XCTAssertEqual(github.requests.count, 1)

        clock += UpdateCheck.interval - 60
        await updates.checkIfDue()
        XCTAssertEqual(github.requests.count, 1, "not again within a day")

        clock += 60
        await updates.checkIfDue()
        XCTAssertEqual(github.requests.count, 2, "a day on, it's due")
    }

    func testAFailedCheckStillWaitsADay() async {
        github.error = URLError(.notConnectedToInternet)
        let updates = check()
        updates.isEnabled = true
        await updates.checkIfDue()
        await updates.checkIfDue()
        XCTAssertEqual(github.requests.count, 1)
        XCTAssertFalse(updates.isDue())
    }

    func testTheLastCheckIsKeptBetweenLaunches() async throws {
        github.release("v0.1.0")
        let storage = MemorySettings()
        try await check(storage: storage).check()
        clock += 60
        let relaunched = check(storage: storage)
        relaunched.isEnabled = true
        XCTAssertFalse(relaunched.isDue())
        await relaunched.checkIfDue()
        XCTAssertEqual(github.requests.count, 1)
    }

    func testAClockTurnedBackMakesItDue() async throws {
        github.release("v0.1.0")
        let updates = check()
        try await updates.check()
        clock -= 3600
        XCTAssertTrue(updates.isDue())
    }

    func testFindsANewerRelease() async throws {
        github.release("v0.2.0")
        let updates = check()
        let outcome = try await updates.check()
        let expected = Release(version: ReleaseVersion("0.2.0")!,
                               page: URL(string: "https://github.com/HighDynamics/gitrasil/releases/tag/v0.2.0")!)
        XCTAssertEqual(outcome, .newer(expected))
        XCTAssertEqual(updates.available, expected, "the page is github.com's, not whatever the reply says")
    }

    func testTheSameOrAnOlderReleaseIsUpToDate() async throws {
        for (tag, latest) in [("v0.1.0", "0.1.0"), ("v0.0.9", "0.0.9")] {
            github.release(tag)
            let outcome = try await check().check()
            XCTAssertEqual(outcome, .upToDate(latest: ReleaseVersion(latest)!), tag)
        }
    }

    func testNoReleaseYet() async throws {
        // Before the first release, or a private repository: GitHub says not found.
        github.status = 404
        github.body = Data(#"{"message": "Not Found"}"#.utf8)
        let outcome = try await check().check()
        XCTAssertEqual(outcome, .noRelease)
    }

    func testDraftsPreReleasesAndOddTagsArentOffered() async throws {
        for (tag, draft, prerelease) in [("v0.2.0", true, false), ("v0.2.0", false, true), ("nightly", false, false)] {
            github.release(tag, draft: draft, prerelease: prerelease)
            let updates = check()
            let outcome = try await updates.check()
            XCTAssertEqual(outcome, .noRelease, tag)
            XCTAssertNil(updates.available)
        }
    }

    func testErrorsAreThrown() async {
        github.status = 403
        github.body = Data(#"{"message": "API rate limit exceeded"}"#.utf8)
        do {
            try await check().check()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? UpdateCheck.CheckError, .status(403))
        }

        github.status = 200
        github.body = Data("<html>".utf8)
        do {
            try await check().check()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? UpdateCheck.CheckError, .unreadable)
        }
    }

    func testANewerReleaseIsOfferedAfterARelaunchUntilItsRunning() async throws {
        github.release("v0.2.0")
        let storage = MemorySettings()
        try await check(storage: storage).check()
        XCTAssertEqual(check(storage: storage).available?.version, ReleaseVersion("0.2.0"))

        let updated = check("0.2.0", storage: storage)
        XCTAssertNil(updated.available, "once running it, there's nothing to offer")
        XCTAssertNil(storage.saved["availableRelease"] ?? nil)
    }

    func testANewerReleaseIsForgottenWhenTheLatestIsntNewer() async throws {
        // A release withdrawn (made a draft again): the next check stops offering it.
        github.release("v0.2.0")
        let updates = check()
        try await updates.check()
        github.release("v0.1.0")
        try await updates.check()
        XCTAssertNil(updates.available)
    }

    func testARepositoryIsOwnerSlashName() {
        for text in ["HighDynamics/gitrasil", "high-dynamics/git.rasil_2", "a/b"] {
            XCTAssertTrue(UpdateCheck.isRepository(text), text)
        }
        for text in ["", "gitrasil", "/gitrasil", "HighDynamics/", "a/b/c", "../..", "a/..", "a b/c", "a/b?c", "a/b#c",
                     "a/b|c", "a/b&c", "a/b%2F", "ö/b", "a/b\n"] {
            XCTAssertFalse(UpdateCheck.isRepository(text), text)
        }
    }

    func testAMalformedRepositoryFailsTheCheckWithoutAsking() async {
        github.release("v0.2.0")
        for repository in ["not a repository", "a/b/c", "a/b?x=1", ""] {
            let updates = UpdateCheck(current: ReleaseVersion("0.1.0")!, repository: repository, storage: MemorySettings(),
                                      fetch: github.fetch, now: { [unowned self] in clock })
            do {
                try await updates.check()
                XCTFail("expected an error for \(repository)")
            } catch {
                XCTAssertEqual(error as? UpdateCheck.CheckError, .notARepository(repository))
            }
        }
        XCTAssertTrue(github.requests.isEmpty)
    }

    func testASavedReleaseOfAMalformedRepositoryIsntOffered() {
        let storage = MemorySettings(["availableRelease": "0.2.0"])
        let updates = UpdateCheck(current: ReleaseVersion("0.1.0")!, repository: "a b", storage: storage,
                                  fetch: github.fetch, now: { [unowned self] in clock })
        XCTAssertNil(updates.available)
    }

    func testTheRequestCarriesNothingButTheVersion() async throws {
        github.release("v0.1.0")
        try await check().check()
        let request = try XCTUnwrap(github.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/HighDynamics/gitrasil/releases/latest")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.allHTTPHeaderFields, [
            "Accept": "application/vnd.github+json",
            "Accept-Language": "en",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "Gitrasil/0.1.0"
        ])
    }
}
