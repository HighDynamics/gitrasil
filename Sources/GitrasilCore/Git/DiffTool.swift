import Foundation

/// External diff-tool handoff (roadmap item #2). Normal git reads route through `WorktreeExecutor`
/// (serialized, output-captured); `git difftool` must NOT — a GUI difftool blocks until the user
/// closes it, which would stall the executor for that worktree. So it launches as a detached,
/// fire-and-forget `Process` instead.
public enum DiffTool {

    /// Pure: map a `DiffSource` + path to the `git difftool` argument vector. No I/O, unit-tested.
    /// `-g` uses the configured GUI tool; `-y`/`--no-prompt` skips git's per-file confirmation.
    ///
    /// Unlike the in-app diff (`Derivations.fileDiff`), this does not fall back to the empty tree
    /// for a root commit's missing parent — staying I/O-free is the point — so difftool on a root
    /// commit's file is an accepted edge case (git will report the unresolved `<sha>^`).
    public static func diffToolArguments(source: DiffSource, path: String) -> [String] {
        let endpoints: [String]
        switch source {
        case .explorer(let meetingBase):
            endpoints = [meetingBase]                 // base → working tree
        case .commit(let sha, _):
            endpoints = ["\(sha)^", sha]              // parent → commit
        case .range(let oldest, let newest, _):
            endpoints = ["\(oldest)^", newest]        // before the range → its tip
        case .against(let ref):
            endpoints = [ref]                         // ref → working tree
        }
        return ["difftool", "-g", "-y"] + endpoints + ["--", path]
    }

    /// Launch `git difftool …` in `worktreeURL` without blocking. Detached and fire-and-forget: a
    /// GUI difftool stays open until the user closes it, so we neither `waitUntilExit()` nor route
    /// through `WorktreeExecutor`. Launches `git` via `/usr/bin/env` (honoring the user's PATH) and
    /// seeds the shared `GitRunner.appEnvironment`, exactly like the normal runner. Throws only if
    /// the process itself can't be launched (`GitError.launchFailed`).
    public static func launchDiffTool(source: DiffSource, path: String, worktreeURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + diffToolArguments(source: source, path: path)
        process.currentDirectoryURL = worktreeURL

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in GitRunner.appEnvironment { environment[key] = value }
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw GitError.launchFailed(underlying: String(describing: error))
        }
    }
}
