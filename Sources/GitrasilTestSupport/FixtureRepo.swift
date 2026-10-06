import Foundation
import GitrasilCore

/// Builds a real git repository in a temp directory so derivations can be tested against actual
/// git output — no mocking of git. Commits use pinned dates/identity for reproducibility.
public final class FixtureRepo {
    public let url: URL
    public let runner: GitRunner

    private var clock = 0
    private let identity = [
        "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.com",
        "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.com",
        // Never spawn an interactive editor (rebase/cherry-pick --continue).
        "GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true",
    ]

    public init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitrasil-fixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base
        self.runner = GitRunner(workdir: base, extraEnvironment: identity)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Run a git command, throwing on non-zero exit.
    @discardableResult
    public func git(_ args: [String]) async throws -> String {
        let out = try await runner.run(args)
        guard out.status == 0 else {
            throw FixtureError.gitFailed(args: args, stderr: out.stderrString ?? "")
        }
        return out.trimmedStdout
    }

    /// `git init` on `main`.
    public func initRepo() async throws { try await git(["init", "-q", "-b", "main"]) }

    /// Write a file (relative path), creating parent directories.
    public func writeFile(_ path: String, _ contents: String) throws {
        let fileURL = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Stage everything and commit with a deterministic, monotonically increasing date.
    @discardableResult
    public func commit(_ message: String) async throws -> String {
        clock += 1
        let date = "2026-01-01T00:00:\(String(format: "%02d", clock))"
        try await git(["add", "-A"])
        let dated = GitRunner(workdir: url, extraEnvironment: identity.merging(
            ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]) { $1 })
        let out = try await dated.run(["commit", "-q", "-m", message])
        guard out.status == 0 else { throw FixtureError.gitFailed(args: ["commit"], stderr: out.stderrString ?? "") }
        return try await git(["rev-parse", "HEAD"])
    }

    /// Write one file and commit it.
    @discardableResult
    public func commitFile(_ path: String, _ contents: String, message: String) async throws -> String {
        try writeFile(path, contents)
        return try await commit(message)
    }

    /// `git checkout -b <name>`.
    public func createBranch(_ name: String) async throws { try await git(["checkout", "-q", "-b", name]) }

    /// `git checkout <name>`.
    public func checkout(_ name: String) async throws { try await git(["checkout", "-q", name]) }

    /// Resolve a ref to its full SHA.
    public func sha(_ ref: String = "HEAD") async throws -> String { try await git(["rev-parse", ref]) }
}

public enum FixtureError: Error, CustomStringConvertible {
    case gitFailed(args: [String], stderr: String)
    public var description: String {
        switch self {
        case .gitFailed(let args, let stderr):
            return "git \(args.joined(separator: " ")) failed: \(stderr)"
        }
    }
}
