import Foundation

extension Mutations {

    /// Create a worktree at `path`. With `newBranch`, create that branch off `base` and check it out
    /// there; otherwise check out the existing branch `base` (git refuses if it's already checked out
    /// in another worktree). `source` is the branch of the worktree this was created *from*, recorded
    /// as durable lineage so the graph can attribute an ahead-branch to its origin worktree even when
    /// several worktrees share the fork commit.
    public static func addWorktree(
        at path: URL, newBranch: String?, base: String, source: String?, runner: GitRunning
    ) async throws {
        var args = ["worktree", "add"]
        if let newBranch { args += ["-b", newBranch] }
        args += [path.path, base]
        let out = try await runner.run(args)
        guard out.status == 0 else { throw MutationError.failed(gitMessage(out, fallback: "Could not create the worktree.")) }

        // Parent-worktree lineage: a symbolic ref recording the source branch *by name*, so it
        // survives reflog expiry and stays unambiguous when worktrees overlap on one commit. Absent
        // for worktrees created outside the app — those simply have no recorded origin.
        if let source {
            let created = newBranch ?? base   // the branch now checked out in the new worktree
            _ = try? await runner.run(["symbolic-ref", parentRef(created), "refs/heads/\(source)"])
        }
    }

    /// Remove the worktree at `path`, and its recorded lineage. Fails on a dirty or locked worktree
    /// unless `force`; git also refuses to remove the main worktree.
    public static func removeWorktree(at path: URL, branch: String?, force: Bool, runner: GitRunning) async throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path.path)
        let out = try await runner.run(args)
        guard out.status == 0 else { throw MutationError.failed(gitMessage(out, fallback: "Could not remove the worktree.")) }
        if let branch { _ = try? await runner.run(["symbolic-ref", "--delete", parentRef(branch)]) }
    }

    /// The branch a worktree was created from, if the app recorded it (`nil` otherwise).
    public static func parentWorktreeBranch(of branch: String, runner: GitRunning) async throws -> String? {
        let out = try await runner.run(["symbolic-ref", "--quiet", parentRef(branch)])
        guard out.status == 0 else { return nil }
        let ref = out.trimmedStdout
        return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : nil
    }

    /// Best-effort, one-time backfill of lineage for a branch created outside the app: if no parent
    /// is recorded, adopt the reflog's "branch: Created from <branch>" and persist it as a durable
    /// parent ref — so terminal-made branches get true attribution before the reflog ages out. No-op
    /// when a parent already exists, or the reflog names a SHA / a branch that no longer exists.
    /// Returns the resolved parent branch (recorded or freshly backfilled), or nil.
    @discardableResult
    public static func backfillLineage(for branch: String, runner: GitRunning) async throws -> String? {
        if let existing = try await parentWorktreeBranch(of: branch, runner: runner) { return existing }
        let out = try await runner.run(["reflog", "show", branch])
        guard out.status == 0, let text = out.stdoutString else { return nil }
        // The creation entry is the oldest "... branch: Created from <ref>" line.
        let marker = "branch: Created from "
        guard let line = text.split(separator: "\n").last(where: { $0.contains(marker) }),
              let range = line.range(of: marker) else { return nil }
        let source = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        // Only adopt a real local branch — never a SHA or HEAD (the ambiguous cases we don't trust).
        let exists = try await runner.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(source)"])
        guard exists.status == 0 else { return nil }
        _ = try? await runner.run(["symbolic-ref", parentRef(branch), "refs/heads/\(source)"])
        return source
    }

    private static func parentRef(_ branch: String) -> String { "refs/gitrasil/parent/\(branch)" }

    private static func gitMessage(_ out: GitOutput, fallback: String) -> String {
        let stderr = (out.stderrString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? fallback : stderr
    }
}
