import Foundation
import XCTest
@testable import GitrasilCore

/// Builds a real git repository in a temp directory so derivations can be tested against
/// actual git output — no mocking of git. Commits use pinned dates/identity for reproducibility.
///
/// This is the backbone of the test strategy (architecture decision #13): every topology and
/// status case is expressed as a fixture and asserted on the derived value.
final class FixtureRepo {
    let url: URL
    let runner: GitRunner

    private var clock = 0

    init(file: StaticString = #filePath, line: UInt = #line) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitrasil-fixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base
        // Pin identity + dates so commit SHAs and ordering are deterministic across runs.
        self.runner = GitRunner(workdir: base, extraEnvironment: [
            "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.com",
            "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.com",
        ])
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Run a git command, failing the test on non-zero exit.
    @discardableResult
    func git(_ args: [String]) async throws -> String {
        let out = try await runner.run(args)
        guard out.status == 0 else {
            throw NSError(domain: "FixtureRepo", code: Int(out.status), userInfo: [
                NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(out.stderrString ?? "")",
            ])
        }
        return out.trimmedStdout
    }

    /// `git init` on `main` with a stable initial config.
    func initRepo() async throws {
        try await git(["init", "-q", "-b", "main"])
    }

    /// Write a file (relative path) and stage it.
    func writeFile(_ path: String, _ contents: String) throws {
        let fileURL = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Stage everything and commit with a deterministic, monotonically increasing date.
    @discardableResult
    func commit(_ message: String) async throws -> String {
        clock += 1
        let date = "2026-01-01T00:00:\(String(format: "%02d", clock))"
        try await git(["add", "-A"])
        let env = ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]
        let dateRunner = GitRunner(workdir: url, extraEnvironment: gitIdentity.merging(env) { $1 })
        let out = try await dateRunner.run(["commit", "-q", "-m", message])
        guard out.status == 0 else {
            throw NSError(domain: "FixtureRepo", code: Int(out.status),
                          userInfo: [NSLocalizedDescriptionKey: out.stderrString ?? "commit failed"])
        }
        return try await git(["rev-parse", "HEAD"])
    }

    private let gitIdentity = [
        "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.com",
        "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.com",
    ]

    /// Convenience: write one file and commit it.
    @discardableResult
    func commitFile(_ path: String, _ contents: String, message: String) async throws -> String {
        try writeFile(path, contents)
        return try await commit(message)
    }
}
