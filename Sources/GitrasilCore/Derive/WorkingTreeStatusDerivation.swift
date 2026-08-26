import Foundation

extension Derivations {

    /// Map of worktree-relative path → working-tree status, for explorer decorations
    /// (engineering notes → Directory explorer). Parses `status --porcelain=v2 -z`.
    public static func workingTreeStatus(runner: GitRunning) async throws -> [String: WorkingFileStatus] {
        let out = try await runner.runChecked(["status", "--porcelain=v2", "-z"])
        return parsePorcelainV2(out.stdoutString ?? "")
    }

    /// Ignored files and directories (worktree-relative), for hiding gitignored paths by default.
    /// `--directory` collapses a fully-ignored directory to a single `dir/` entry.
    public static func ignoredPaths(runner: GitRunning) async throws -> Set<String> {
        let out = try await runner.runChecked(
            ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"])
        return Set(out.stdoutString?.split(separator: "\0", omittingEmptySubsequences: true).map(String.init) ?? [])
    }

    /// Parse porcelain v2 (`-z`). Records are NUL-separated; a rename/copy ("2") record is followed
    /// by an extra NUL-separated original path that must be consumed. We map to the coarse
    /// working-tree status the explorer shows.
    static func parsePorcelainV2(_ text: String) -> [String: WorkingFileStatus] {
        let tokens = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result: [String: WorkingFileStatus] = [:]
        var i = 0
        while i < tokens.count {
            let record = tokens[i]
            guard let kind = record.first else { i += 1; continue }
            switch kind {
            case "1":  // ordinary change: "1 XY sub mH mI mW hH hI path"
                let parts = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                if parts.count == 9 { result[String(parts[8])] = status(forXY: String(parts[1])) }
                i += 1
            case "2":  // rename/copy: "2 XY sub mH mI mW hH hI Xscore path" then NUL <origPath>
                let parts = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                if parts.count == 10 { result[String(parts[9])] = .renamed }
                i += 2  // skip the trailing original-path token
            case "u":  // unmerged (conflict): "u XY ... path"
                let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if let path = parts.last { result[String(path)] = .conflicted }
                i += 1
            case "?":  // untracked: "? path"
                result[String(record.dropFirst(2))] = .untracked
                i += 1
            default:   // "!" ignored, or anything else — skip
                i += 1
            }
        }
        return result
    }

    /// Collapse the two-char XY status to the explorer's coarse status. Prefer the working-tree
    /// (Y) change when present, else the staged (X) change.
    private static func status(forXY xy: String) -> WorkingFileStatus {
        let chars = Array(xy)
        let x = chars.first ?? "."
        let y = chars.count > 1 ? chars[1] : "."
        for c in [y, x] {
            switch c {
            case "M": return .modified
            case "A": return .added
            case "D": return .deleted
            case "R", "C": return .renamed
            default: continue
            }
        }
        return .modified
    }
}
