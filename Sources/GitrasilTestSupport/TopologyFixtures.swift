import Foundation
import GitrasilCore

/// Scenario builders — one per topology case from the topology doc and the degenerate states.
/// Each returns a `FixtureRepo` positioned so `Derivations.historyGraph` can be asserted on.
/// Shared by XCTest and the smoke runner so both cover the identical git states.
public enum Topology {

    /// Case A — cw directly off main, main not ahead. Single lane: meeting + two cw commits.
    public static func caseA() async throws -> FixtureRepo {
        let r = try await base()
        try await r.createBranch("cw")
        try await r.commitFile("cw1.txt", "1", message: "cw-1")
        try await r.commitFile("cw2.txt", "2", message: "cw-2")
        return r
    }

    /// Case B — cw off main, main ahead. Fork: one cw commit + a two-commit trunk-ahead lane.
    public static func caseB() async throws -> FixtureRepo {
        let r = try await base()
        try await r.createBranch("cw")
        try await r.commitFile("cw1.txt", "1", message: "cw-1")
        try await r.checkout("main")
        try await r.commitFile("m1.txt", "1", message: "main-ahead-1")
        try await r.commitFile("m2.txt", "2", message: "main-ahead-2")
        try await r.checkout("cw")
        return r
    }

    /// Case C — one intermediate branch (feature) between cw and main; main not ahead.
    public static func caseC() async throws -> FixtureRepo {
        let r = try await base()
        try await r.createBranch("feature")
        try await r.commitFile("f1.txt", "1", message: "feature-1")
        try await r.commitFile("f2.txt", "2", message: "feature-2")
        try await r.createBranch("cw")
        try await r.commitFile("cw1.txt", "1", message: "cw-1")
        return r
    }

    /// A chain: feature-a off main, feature-b off feature-a, cw off feature-b. Two intermediates.
    public static func chained() async throws -> FixtureRepo {
        let r = try await base()
        try await r.createBranch("feature-a")
        try await r.commitFile("fa1.txt", "1", message: "fa-1")
        try await r.commitFile("fa2.txt", "2", message: "fa-2")
        try await r.createBranch("feature-b")
        try await r.commitFile("fb1.txt", "1", message: "fb-1")
        try await r.commitFile("fb2.txt", "2", message: "fb-2")
        try await r.createBranch("cw")
        try await r.commitFile("cw1.txt", "1", message: "cw-1")
        return r
    }

    /// An intermediate branch with `count` commits (for truncation), cw with a single commit.
    public static func truncatedIntermediate(count: Int) async throws -> FixtureRepo {
        let r = try await base()
        try await r.createBranch("feature")
        for i in 1...count { try await r.commitFile("f\(i).txt", "\(i)", message: "feature-\(i)") }
        try await r.createBranch("cw")
        try await r.commitFile("cw1.txt", "1", message: "cw-1")
        return r
    }

    /// cw with `count` commits (to prove cw is never truncated).
    public static func longCurrentWorktree(count: Int) async throws -> FixtureRepo {
        let r = try await base()
        try await r.createBranch("cw")
        for i in 1...count { try await r.commitFile("cw\(i).txt", "\(i)", message: "cw-\(i)") }
        return r
    }

    /// A merge commit on cw's line — its second-parent commits must not appear (first-parent walk).
    public static func mergeOnCurrentWorktree() async throws -> FixtureRepo {
        let r = try await base()
        try await r.createBranch("cw")
        try await r.commitFile("cw1.txt", "1", message: "cw-1")
        try await r.createBranch("side")
        try await r.commitFile("side1.txt", "1", message: "side-1")
        try await r.checkout("cw")
        try await r.commitFile("cw2.txt", "2", message: "cw-2")
        try await r.git(["merge", "--no-ff", "-m", "merge-side", "side"])
        return r
    }

    /// Detached HEAD at an earlier commit; main is ahead.
    public static func detached() async throws -> FixtureRepo {
        let r = try await base()
        let first = try await r.sha("HEAD")
        try await r.commitFile("c2.txt", "2", message: "main-2")
        try await r.git(["checkout", "-q", first])
        return r
    }

    /// cw's checked-out branch *is* trunk (main): a no-divergence state.
    public static func onTrunk() async throws -> FixtureRepo {
        let r = try await base()
        try await r.commitFile("c2.txt", "2", message: "root-2")
        return r
    }

    /// A rebase paused on a conflict: cw and main both change the same line, then `rebase main`
    /// halts. Leaves the worktree mid-operation (rebase-merge/ present, working tree conflicted).
    public static func conflictedRebase() async throws -> FixtureRepo {
        let r = try FixtureRepo()
        try await r.initRepo()
        try await r.commitFile("x.txt", "base\n", message: "root")
        try await r.createBranch("cw")
        try await r.commitFile("x.txt", "cw change\n", message: "cw-1")
        try await r.checkout("main")
        try await r.commitFile("x.txt", "main change\n", message: "main-1")
        try await r.checkout("cw")
        // Rebase conflicts on x.txt and pauses; exits non-zero, so don't route through `git`.
        _ = try await r.runner.run(["rebase", "main"])
        return r
    }

    /// An initialized repo with no commits yet.
    public static func empty() async throws -> FixtureRepo {
        let r = try FixtureRepo()
        try await r.initRepo()
        return r
    }

    /// main with a single "root" commit — the shared base for most cases above.
    private static func base() async throws -> FixtureRepo {
        let r = try FixtureRepo()
        try await r.initRepo()
        try await r.commitFile("root.txt", "0", message: "root")
        return r
    }
}
