import Foundation

/// One installed GUI diff tool git can drive, e.g. `opendiff` → "FileMerge".
public struct DiffToolOption: Sendable, Equatable, Identifiable {
    /// git's tool id, passed as `--tool=<id>` / stored in `diff.guitool`.
    public let id: String
    /// Human-readable name from `--tool-help`, e.g. "FileMerge", "Visual Studio Code".
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// External diff-tool handoff (roadmap item #2). Normal git reads route through `WorktreeExecutor`
/// (serialized, output-captured); `git difftool` must NOT — a GUI difftool blocks until the user
/// closes it, which would stall the executor for that worktree. So it launches as a detached,
/// fire-and-forget `Process` instead.
public enum DiffTool {

    /// Pure: map a `DiffSource` + path to the `git difftool` argument vector. No I/O, unit-tested.
    /// `tool` selects an explicit tool (`--tool=<tool>`); nil uses the user's configured GUI tool
    /// (`-g`). `-y`/`--no-prompt` skips git's per-file confirmation.
    ///
    /// Unlike the in-app diff (`Derivations.fileDiff`), this does not fall back to the empty tree
    /// for a root commit's missing parent — staying I/O-free is the point — so difftool on a root
    /// commit's file is an accepted edge case (git will report the unresolved `<sha>^`).
    public static func diffToolArguments(source: DiffSource, path: String, tool: String? = nil) -> [String] {
        let selector = tool.map { ["--tool=\($0)"] } ?? ["-g"]
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
        return ["difftool"] + selector + ["-y"] + endpoints + ["--", path]
    }

    /// Parse `git difftool --tool-help` into the GUI diff tools that are actually installed. Only
    /// tools git marks "(requires a graphical session)" are kept — terminal tools (vimdiff, …)
    /// can't run from our detached, terminal-less GUI launch. Pure, so unit-tested against captured
    /// output. Order follows git's own (which lists the platform's preferred tools first).
    public static func availableGUITools(fromToolHelp text: String) -> [DiffToolOption] {
        let guiMarker = "(requires a graphical session)"
        // git prints installed tools first, then a "valid, but not currently available" section.
        let installedBlock = text.components(separatedBy: "valid, but not currently available").first ?? text
        var options: [DiffToolOption] = []
        for rawLine in installedBlock.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains(guiMarker) else { continue }   // GUI tools only
            // "<id>    Use <Name> (requires a graphical session)"
            guard let idEnd = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let id = String(line[..<idEnd])
            var name = String(line[idEnd...]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("Use ") { name.removeFirst(4) }
            if let markerRange = name.range(of: guiMarker) { name.removeSubrange(markerRange.lowerBound..<name.endIndex) }
            name = name.trimmingCharacters(in: .whitespaces)
            options.append(DiffToolOption(id: id, name: name.isEmpty ? id : name))
        }
        return options
    }

    /// The GUI diff tools installed on this machine (via `git difftool --tool-help`).
    public static func installedGUITools(runner: GitRunning) async throws -> [DiffToolOption] {
        let out = try await runner.run(["difftool", "--tool-help"])
        return availableGUITools(fromToolHelp: out.stdoutString ?? "")
    }

    /// The user's configured diff tool, or nil. `git difftool -g` resolves `diff.guitool` then
    /// `diff.tool`, so either counts as configured.
    public static func configuredTool(runner: GitRunning) async -> String? {
        for key in ["diff.guitool", "diff.tool"] {
            if let out = try? await runner.run(["config", "--get", key]), out.status == 0 {
                let value = out.trimmedStdout
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Persist the default GUI diff tool in the user's global git config (`diff.guitool`), so every
    /// future `-g` launch uses it without prompting. A user preference, hence `--global`.
    public static func setDefaultTool(_ id: String, runner: GitRunning) async throws {
        try await runner.runChecked(["config", "--global", "diff.guitool", id])
    }

    /// Clear the configured default GUI diff tool. `--unset` exits 5 when the key isn't set, which
    /// is not an error here (already cleared).
    public static func clearDefaultTool(runner: GitRunning) async throws {
        let args = ["config", "--global", "--unset", "diff.guitool"]
        let out = try await runner.run(args)
        if out.status != 0 && out.status != 5 {
            throw GitError.commandFailed(args: args, status: out.status, stderr: out.stderrString ?? "")
        }
    }

    /// Launch `git difftool …` in `worktreeURL` without blocking. Detached and fire-and-forget: a
    /// GUI difftool stays open until the user closes it, so we neither `waitUntilExit()` nor route
    /// through `WorktreeExecutor`. Launches `git` via `/usr/bin/env` (honoring the user's PATH) and
    /// seeds the shared `GitRunner.appEnvironment`, exactly like the normal runner. `tool` forces a
    /// specific tool; nil uses the configured GUI tool. Throws only if the process itself can't be
    /// launched (`GitError.launchFailed`).
    public static func launchDiffTool(source: DiffSource, path: String, worktreeURL: URL, tool: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + diffToolArguments(source: source, path: path, tool: tool)
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
