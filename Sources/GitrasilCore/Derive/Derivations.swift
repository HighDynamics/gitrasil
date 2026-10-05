import Foundation

/// Pure, git-backed derivations that turn `git` output into domain values. These are the
/// highest-risk logic in the app (parsing + topology) and, being free functions over a
/// `GitRunning`, they're exercised directly against real fixture repos in tests.
///
/// This is the seed of the derivation layer; graph topology, the file-status overlay, and
/// diff parsing land here as the build proceeds.
public enum Derivations {

    // MARK: Trunk detection (engineering notes → Trunk detection)

    public enum TrunkError: Error, Sendable { case notFound }

    /// Resolve the trunk ref, in order: user override → `origin/HEAD` → local `main` → local `master`.
    /// `origin/HEAD` is read as-is (never network-refreshed), matching the no-network product rule.
    /// Returns a ref name usable with `merge-base`/`rev-list` (e.g. `origin/main`, `main`).
    public static func resolveTrunk(runner: GitRunning, override: String? = nil) async throws -> String {
        if let override, !override.isEmpty { return override }

        let symbolic = try await runner.run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"])
        if symbolic.status == 0 {
            let ref = symbolic.trimmedStdout
            if !ref.isEmpty {
                // refs/remotes/origin/main → origin/main
                return ref.replacingOccurrences(of: "refs/remotes/", with: "")
            }
        }

        for candidate in ["main", "master"] {
            let verify = try await runner.run(["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"])
            if verify.status == 0 { return candidate }
        }

        throw TrunkError.notFound
    }

    // MARK: Meeting commit

    public enum MergeBaseError: Error, Sendable { case noCommonAncestor }

    /// The meeting commit (graph anchor): `git merge-base <a> <b>`.
    /// A status of 1 means the two refs share no ancestor — surfaced as data, not a crash.
    public static func mergeBase(_ a: String, _ b: String, runner: GitRunning) async throws -> String {
        let out = try await runner.run(["merge-base", a, b])
        if out.status == 1 { throw MergeBaseError.noCommonAncestor }
        guard out.status == 0 else {
            throw GitError.commandFailed(args: ["merge-base", a, b], status: out.status, stderr: out.stderrString ?? "")
        }
        return out.trimmedStdout
    }

    /// Does the working tree have uncommitted changes? (`status --porcelain=v2 -z` non-empty)
    public static func isDirty(runner: GitRunning) async throws -> Bool {
        let out = try await runner.runChecked(["status", "--porcelain=v2", "-z"])
        return !out.trimmedStdout.isEmpty
    }
}
