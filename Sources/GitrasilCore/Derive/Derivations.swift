import Foundation

/// Pure, git-backed derivations that turn `git` output into domain values. These are the
/// highest-risk logic in the app (parsing and topology) and, being free functions over a
/// `GitRunning`, they're exercised directly against real fixture repos in tests.
public enum Derivations {

    // MARK: Trunk detection (engineering notes → Trunk detection)

    public enum TrunkError: Error, Sendable { case notFound }

    /// Resolve the trunk ref, in order: `origin/HEAD` → local `main` → local `master`. `origin/HEAD` is
    /// read as-is (never network-refreshed), matching the no-network product rule. Returns a ref name
    /// usable with `git log` (e.g. `origin/main`, `main`).
    public static func resolveTrunk(runner: GitRunning) async throws -> String {
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
}
