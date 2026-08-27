import Foundation

extension Derivations {

    /// Enumerate the repository's worktrees via `git worktree list --porcelain`. The first record is
    /// always the main worktree; the rest are linked worktrees, in git's own order. Bare entries are
    /// kept (flagged) so callers can filter them out of the tab strip.
    ///
    /// Porcelain format: newline-separated `key value` lines, records separated by a blank line, e.g.
    ///
    ///     worktree /path/to/main
    ///     HEAD 1a2b3c…
    ///     branch refs/heads/main
    ///
    ///     worktree /path/to/feature
    ///     HEAD 4d5e6f…
    ///     detached
    ///
    /// A bare repo's record carries `bare` in place of HEAD/branch; `locked` and `prunable` lines
    /// are optional attributes.
    public static func worktrees(runner: GitRunning) async throws -> [WorktreeInfo] {
        let out = try await runner.runChecked(["worktree", "list", "--porcelain"])
        let text = out.stdoutString ?? ""
        var infos: [WorktreeInfo] = []

        // Split into records on blank lines; parse each record's key/value lines.
        for record in text.components(separatedBy: "\n\n") {
            var path: String?
            var head: String?
            var branch: String?
            var isBare = false, isDetached = false, isLocked = false

            for line in record.split(separator: "\n", omittingEmptySubsequences: true) {
                let raw = String(line)
                if raw == "bare" { isBare = true; continue }
                if raw == "detached" { isDetached = true; continue }
                if raw == "locked" || raw.hasPrefix("locked ") { isLocked = true; continue }
                if raw.hasPrefix("prunable") { continue }

                guard let sep = raw.firstIndex(of: " ") else { continue }
                let key = String(raw[..<sep])
                let value = String(raw[raw.index(after: sep)...])
                switch key {
                case "worktree": path = value
                case "HEAD": head = value
                case "branch":
                    branch = value.hasPrefix("refs/heads/")
                        ? String(value.dropFirst("refs/heads/".count)) : value
                default: break
                }
            }

            guard let path else { continue }   // skip empty trailing record
            infos.append(WorktreeInfo(
                path: URL(fileURLWithPath: path).standardizedFileURL,
                head: head, branch: branch, isBare: isBare,
                isDetached: isDetached, isLocked: isLocked,
                isMain: infos.isEmpty))
        }
        return infos
    }
}
