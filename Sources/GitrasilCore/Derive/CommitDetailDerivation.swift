import Foundation

extension Derivations {

    /// The commit detail panel content for a single commit: metadata + files touched
    /// (engineering notes → Commit detail panel).
    public static func commitDetail(sha: String, runner: GitRunning) async throws -> CommitDetail {
        let node = try await commit(sha, runner: runner)
        let message = try await runner.runChecked(["show", "-s", "--format=%B", sha]).trimmedStdout

        // -M detects renames; --root makes a parentless (initial) commit report its files as additions.
        let out = try await runner.runChecked(
            ["diff-tree", "--no-commit-id", "--name-status", "-M", "-r", "-z", "--root", sha])
        let files = parseNameStatus(out.stdoutString ?? "")
        return CommitDetail(commit: node, fullMessage: message, files: files, commitCount: 1)
    }

    /// The detail for a contiguous range: the tip's metadata plus the union of files changed
    /// across the whole span, each with its net change type (design brief §5).
    public static func rangeDetail(oldest: String, newest: String, runner: GitRunning) async throws -> CommitDetail {
        let node = try await commit(newest, runner: runner)
        // A parentless (root) oldest has no `oldest^`; fall back to the empty tree so a
        // root-inclusive range still resolves (mirrors DiffDerivation).
        let hasParent = (try? await runner.runChecked(["rev-parse", "--verify", "-q", "\(oldest)^"])) != nil
        let left = hasParent ? "\(oldest)^" : emptyTreeHash

        let countArgs = hasParent ? ["rev-list", "--count", "\(oldest)^..\(newest)"]
                                  : ["rev-list", "--count", newest]
        let count = Int(try await runner.runChecked(countArgs).trimmedStdout) ?? 1

        let out = try await runner.runChecked(["diff", "--name-status", "-M", "-z", left, newest])
        let files = parseNameStatus(out.stdoutString ?? "")
        return CommitDetail(commit: node, fullMessage: node.subject, files: files, commitCount: count)
    }

    /// Parse `--name-status -z` output. Entries are NUL-separated tokens: a status token followed
    /// by one path, except R/C entries which carry two (old, new).
    static func parseNameStatus(_ text: String) -> [FileChange] {
        let tokens = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var files: [FileChange] = []
        var i = 0
        while i < tokens.count {
            let status = tokens[i]; i += 1
            guard let code = status.first else { continue }
            switch code {
            case "R":
                guard i + 1 < tokens.count else { break }
                let from = tokens[i]; let to = tokens[i + 1]; i += 2
                files.append(FileChange(path: to, kind: .renamed(from: from)))
            case "C":
                guard i + 1 < tokens.count else { break }
                let from = tokens[i]; let to = tokens[i + 1]; i += 2
                files.append(FileChange(path: to, kind: .copied(from: from)))
            default:
                guard i < tokens.count else { break }
                let path = tokens[i]; i += 1
                files.append(FileChange(path: path, kind: kind(for: code)))
            }
        }
        return files
    }

    private static func kind(for code: Character) -> FileChangeKind {
        switch code {
        case "A": return .added
        case "D": return .deleted
        default: return .modified   // M, T (type change), and anything else read as modified
        }
    }
}
