import Foundation

/// The three history mutations plus their safety net (design brief §9, engineering notes →
/// History mutations / Safety). All local, no network. Every mutation writes a backup ref first so
/// it can be undone, and blocks on a dirty or detached worktree (no auto-stash). A mutation that
/// hits a conflict pauses git and reports `.conflicted`; the continue/abort bar (driven by the
/// re-derived snapshot's in-progress state) takes it from there.
public enum Mutations {

    /// Number of backup refs kept per branch before older ones are pruned.
    public static let backupsKept = 10

    // MARK: Mutations

    /// Replay the current branch onto `target` (a branch tip or the trunk). `git rebase <target>`.
    @discardableResult
    public static func rebaseOnto(target: String, branch: String, runner: GitRunning) async throws -> MutationOutcome {
        try await ensureMutable(runner: runner)
        _ = try await writeBackup(branch: branch, runner: runner)
        return try await runPausable(["rebase", target], runner: runner)
    }

    /// Drop a contiguous range of the current branch's own commits by replaying what follows onto
    /// the range's parent: `git rebase --onto <oldest>^ <newest>`.
    @discardableResult
    public static func drop(oldest: String, newest: String, branch: String, runner: GitRunning) async throws -> MutationOutcome {
        try await ensureMutable(runner: runner)
        _ = try await writeBackup(branch: branch, runner: runner)
        return try await runPausable(["rebase", "--onto", "\(oldest)^", newest], runner: runner)
    }

    /// Cherry-pick a contiguous range from another branch into the current one:
    /// `git cherry-pick <oldest>^..<newest>`.
    @discardableResult
    public static func cherryPick(oldest: String, newest: String, branch: String, runner: GitRunning) async throws -> MutationOutcome {
        try await ensureMutable(runner: runner)
        _ = try await writeBackup(branch: branch, runner: runner)
        return try await runPausable(["cherry-pick", "\(oldest)^..\(newest)"], runner: runner)
    }

    // MARK: Conflict flow

    /// Continue a paused operation. May pause again on the next conflict.
    @discardableResult
    public static func continueOperation(_ operation: InProgressOperation, runner: GitRunning) async throws -> MutationOutcome {
        switch operation {
        case .rebase: return try await runPausable(["rebase", "--continue"], runner: runner)
        case .cherryPick: return try await runPausable(["cherry-pick", "--continue"], runner: runner)
        case .merge: return try await runPausable(["commit", "--no-edit"], runner: runner)
        }
    }

    /// Abort a paused operation, returning the worktree to its pre-operation state.
    public static func abortOperation(_ operation: InProgressOperation, runner: GitRunning) async throws {
        switch operation {
        case .rebase: _ = try await runner.runChecked(["rebase", "--abort"])
        case .cherryPick: _ = try await runner.runChecked(["cherry-pick", "--abort"])
        case .merge: _ = try await runner.runChecked(["merge", "--abort"])
        }
    }

    // MARK: Undo

    /// Reset the branch to its most recent backup ref (single-level undo for v1).
    public static func undo(branch: String, runner: GitRunning) async throws {
        guard let latest = try await latestBackup(branch: branch, runner: runner) else {
            throw MutationError.noBackup
        }
        _ = try await runner.runChecked(["reset", "--hard", latest])
    }

    // MARK: - Internals

    /// Block when the working tree is dirty or HEAD is detached — surfaced, never auto-stashed.
    static func ensureMutable(runner: GitRunning) async throws {
        if try await Derivations.isDirty(runner: runner) { throw MutationError.workingTreeDirty }
        let symbolic = try await runner.run(["symbolic-ref", "--quiet", "HEAD"])
        if symbolic.status != 0 { throw MutationError.detachedHead }
    }

    /// Run a command that may pause on conflict: success → completed; non-zero with an in-progress
    /// marker present → conflicted; non-zero with no marker → a hard failure.
    static func runPausable(_ args: [String], runner: GitRunning) async throws -> MutationOutcome {
        let out = try await runner.run(args)
        if out.status == 0 { return .completed }
        if let operation = try await Derivations.inProgressOperation(runner: runner) {
            return .conflicted(operation)
        }
        throw MutationError.failed(out.stderrString ?? "git \(args.joined(separator: " ")) failed")
    }

    /// Write a backup ref at the branch's current tip, then prune old backups.
    @discardableResult
    static func writeBackup(branch: String, runner: GitRunning) async throws -> String {
        let tip = try await runner.runChecked(["rev-parse", "HEAD"]).trimmedStdout
        // Fixed-width millisecond epoch keeps refs chronologically sortable by name; a short random
        // suffix keeps two backups in the same millisecond distinct.
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let ref = "refs/gitrasil/backup/\(branch)/\(stamp)-\(UUID().uuidString.prefix(8))"
        _ = try await runner.runChecked(["update-ref", ref, tip])
        try await pruneBackups(branch: branch, runner: runner)
        return ref
    }

    static func latestBackup(branch: String, runner: GitRunning) async throws -> String? {
        try await backupRefs(branch: branch, runner: runner).first
    }

    static func pruneBackups(branch: String, runner: GitRunning) async throws {
        let refs = try await backupRefs(branch: branch, runner: runner)
        for ref in refs.dropFirst(backupsKept) {
            _ = try await runner.run(["update-ref", "-d", ref])
        }
    }

    /// Backup refs for a branch, newest first (fixed-width millisecond suffix → lexical == chrono).
    static func backupRefs(branch: String, runner: GitRunning) async throws -> [String] {
        let out = try await runner.runChecked(
            ["for-each-ref", "--format=%(refname)", "--sort=-refname", "refs/gitrasil/backup/\(branch)"])
        return out.stdoutString?.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
    }
}

/// The result of a mutation attempt.
public enum MutationOutcome: Sendable, Equatable {
    case completed
    case conflicted(InProgressOperation)
}

public enum MutationError: Error, Sendable, Equatable {
    case workingTreeDirty
    case detachedHead
    case noBackup
    case failed(String)

    public var message: String {
        switch self {
        case .workingTreeDirty: return "Commit or stash your changes to enable history edits."
        case .detachedHead: return "No branch checked out — history edits are unavailable."
        case .noBackup: return "Nothing to undo."
        case .failed(let stderr): return stderr.isEmpty ? "The operation failed." : stderr
        }
    }
}
