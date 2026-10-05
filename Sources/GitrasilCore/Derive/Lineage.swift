import Foundation

extension Derivations {

    /// The branch a worktree was created from, if recorded as `refs/gitrasil/parent/<branch>`
    /// (`nil` otherwise).
    public static func parentWorktreeBranch(of branch: String, runner: GitRunning) async throws -> String? {
        let out = try await runner.run(["symbolic-ref", "--quiet", parentRef(branch)])
        guard out.status == 0 else { return nil }
        let ref = out.trimmedStdout
        return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : nil
    }

    /// Best-effort, one-time backfill of lineage for a branch with none recorded: adopt the reflog's
    /// "branch: Created from <branch>" and persist it as a durable parent ref — so terminal-made
    /// branches get true attribution before the reflog ages out. No-op when a parent already exists,
    /// or the reflog names a SHA / a branch that no longer exists. Returns the resolved parent branch
    /// (recorded or freshly backfilled), or nil.
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
}
