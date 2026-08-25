import Foundation

extension Derivations {

    /// The empty-tree object hash — a stable diff baseline for a parentless (root) commit.
    private static let emptyTreeHash = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// Compute a view-only file diff for the given source (design brief §6). Renders git's own
    /// unified-diff output; binary differences are flagged for external handoff rather than shown.
    public static func fileDiff(source: DiffSource, path: String, runner: GitRunning) async throws -> FileDiff {
        let (args, label) = try await diffInvocation(source: source, path: path, runner: runner)
        let out = try await runner.runChecked(args)
        let text = out.stdoutString ?? ""
        return FileDiff(path: path, unifiedText: text, isBinary: isBinaryDiff(text), label: label)
    }

    /// Build the `git diff` argv and the human-readable label for a source.
    private static func diffInvocation(
        source: DiffSource, path: String, runner: GitRunning
    ) async throws -> (args: [String], label: String) {
        switch source {
        case .explorer(let meetingBase):
            return (["diff", meetingBase, "--", path], "base → working tree")

        case .commit(let sha, let shortSHA):
            // Root commits have no parent; fall back to the empty tree so the addition still shows.
            let left = (try? await runner.runChecked(["rev-parse", "--verify", "-q", "\(sha)^"])) != nil
                ? "\(sha)^" : emptyTreeHash
            return (["diff", left, sha, "--", path], "parent → \(shortSHA)")

        case .range(let oldest, let newest, let newestShort):
            let left = (try? await runner.runChecked(["rev-parse", "--verify", "-q", "\(oldest)^"])) != nil
                ? "\(oldest)^" : emptyTreeHash
            return (["diff", left, newest, "--", path], "range → \(newestShort)")

        case .against(let ref):
            return (["diff", ref, "--", path], "\(ref) → working tree")
        }
    }

    /// git reports a binary change as a "Binary files … differ" line instead of hunks.
    static func isBinaryDiff(_ text: String) -> Bool {
        text.contains("\nBinary files ") || text.hasPrefix("Binary files ")
    }
}
