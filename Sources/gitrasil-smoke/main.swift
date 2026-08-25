import Foundation
import GitrasilCore
import GitrasilTestSupport

// Smoke runner: exercises the core against real git fixtures and the executor against a fake
// runner, printing PASS/FAIL and exiting non-zero on any failure. Mirrors the XCTest suite so we
// have a working verification path while the repo's Xcode is too old to run XCTest (see README).

final class Check {
    var failures: [String] = []
    func expect(_ condition: Bool, _ message: String) {
        if condition { print("  ✓ \(message)") }
        else { print("  ✗ \(message)"); failures.append(message) }
    }
    func equal<T: Equatable>(_ a: T, _ b: T, _ message: String) {
        expect(a == b, "\(message)\(a == b ? "" : " — got \(a), expected \(b)")")
    }
}

let check = Check()

func runDerivations() async throws {
    print("Derivations (real git):")
    let repo = try FixtureRepo()
    try await repo.initRepo()
    try await repo.commitFile("a.txt", "1", message: "root")
    check.equal(try await Derivations.resolveTrunk(runner: repo.runner), "main", "resolveTrunk finds main")
    check.equal(try await Derivations.resolveTrunk(runner: repo.runner, override: "develop"), "develop", "resolveTrunk honors override")

    let root = try await repo.sha("HEAD")
    try await repo.createBranch("feature")
    try await repo.commitFile("b.txt", "2", message: "feature")
    try await repo.checkout("main")
    try await repo.commitFile("c.txt", "3", message: "main ahead")
    let base = try await Derivations.mergeBase("main", "feature", runner: repo.runner)
    check.equal(base, root, "mergeBase is the shared root")
    check.expect(try await Derivations.isBehind(meeting: base, trunk: "main", runner: repo.runner), "isBehind true when trunk advanced")
    check.expect(!(try await Derivations.isDirty(runner: repo.runner)), "clean tree is not dirty")
    try repo.writeFile("c.txt", "changed")
    check.expect(try await Derivations.isDirty(runner: repo.runner), "uncommitted change is dirty")
}

func runBadge() {
    print("Status badge precedence:")
    check.equal(WorktreeStatusFacts(inProgress: true, dirty: true, behind: true).badge, .conflicted, "conflicted wins all")
    check.equal(WorktreeStatusFacts(dirty: true, behind: true).badge, .modified, "modified beats behind")
    check.equal(WorktreeStatusFacts(behind: true).badge, .behind, "behind alone")
    check.expect(WorktreeStatusFacts().badge == nil, "clean shows no badge")
}

func runGraph() async throws {
    print("History graph topology (real git):")

    // Each FixtureRepo must be retained past the derivation — its deinit deletes the temp dir.
    let repoA = try await Topology.caseA()
    let a = try await Derivations.historyGraph(runner: repoA.runner)
    check.equal(a.segments.map(\.kind), [.currentWorktree], "A: single cw lane")
    check.equal(a.segments.first?.commits.map(\.subject) ?? [], ["cw-2", "cw-1"], "A: cw commits newest-first")
    check.expect(a.trunkAhead == nil, "A: no trunk-ahead lane")
    check.equal(a.meetingCommit?.subject ?? "", "root", "A: meeting is root")

    let repoB = try await Topology.caseB()
    let b = try await Derivations.historyGraph(runner: repoB.runner)
    check.equal(b.trunkAhead?.kind, .trunkAhead(branch: "main"), "B: trunk-ahead fork lane present")
    check.equal(b.trunkAhead?.commits.map(\.subject) ?? [], ["main-ahead-2", "main-ahead-1"], "B: trunk-ahead commits")

    let repoC = try await Topology.caseC()
    let c = try await Derivations.historyGraph(runner: repoC.runner)
    check.equal(c.segments.map(\.kind), [.currentWorktree, .intermediate(branch: "feature")], "C: cw + one intermediate")
    check.equal(c.branchesBetween, 1, "C: one branch between")

    let repoChained = try await Topology.chained()
    let chained = try await Derivations.historyGraph(runner: repoChained.runner)
    check.equal(chained.segments.map(\.kind),
                [.currentWorktree, .intermediate(branch: "feature-b"), .intermediate(branch: "feature-a")],
                "chained: cw, feature-b, feature-a in ancestry order")
    check.equal(chained.branchesBetween, 2, "chained: two branches between")

    let repoTrunc = try await Topology.truncatedIntermediate(count: 7)
    let trunc = try await Derivations.historyGraph(runner: repoTrunc.runner)
    let feature = trunc.segments.first { $0.kind == .intermediate(branch: "feature") }
    check.equal(feature?.commits.count ?? 0, 7, "truncation: full run preserved")
    check.equal(feature?.hiddenCount ?? 0, 6, "truncation: 6 hidden")
    check.equal(feature?.collapsedCommits.count ?? 0, 1, "truncation: collapses to tip")

    let repoLong = try await Topology.longCurrentWorktree(count: 7)
    let long = try await Derivations.historyGraph(runner: repoLong.runner)
    check.expect(!(long.segments.first?.isTruncatable ?? true), "cw never truncates (7 commits shown)")

    let repoMerge = try await Topology.mergeOnCurrentWorktree()
    let merge = try await Derivations.historyGraph(runner: repoMerge.runner)
    let mergeSubjects = merge.segments.flatMap { $0.commits.map(\.subject) }
    check.expect(mergeSubjects.contains("merge-side") && !mergeSubjects.contains("side-1"),
                 "merge collapses to first-parent (no second-parent commit)")

    let repoEmpty = try await Topology.empty()
    let empty = try await Derivations.historyGraph(runner: repoEmpty.runner)
    check.expect(empty.isEmpty && empty.meetingCommit == nil, "empty repo → isEmpty")

    let repoDetached = try await Topology.detached()
    let detached = try await Derivations.historyGraph(runner: repoDetached.runner)
    check.expect(detached.isDetached && !detached.isEmpty, "detached HEAD flagged")

    let repoOnTrunk = try await Topology.onTrunk()
    let onTrunk = try await Derivations.historyGraph(runner: repoOnTrunk.runner)
    check.expect(onTrunk.isOnTrunk && onTrunk.segments.isEmpty, "on-trunk → no divergence")
}

func runExecutor() async throws {
    print("Executor serialization & coalescing:")
    let r1 = RecordingRunner(delay: .milliseconds(80))
    let e1 = WorktreeExecutor(runner: r1)
    let m = await e1.mutate { try await $0.run(["MUTATION"]) }
    let rd = await e1.read(.statuses) { try await $0.run(["READ"]) }
    _ = try await m.value; _ = try await rd.value
    check.equal((await r1.snapshot()).finished, ["MUTATION", "READ"], "read finishes after the mutation it queued behind")

    let r2 = RecordingRunner(delay: .milliseconds(80))
    let e2 = WorktreeExecutor(runner: r2)
    let stale = await e2.read(.graph) { try await $0.run(["STALE"]) }
    let fresh = await e2.read(.graph) { try await $0.run(["FRESH"]) }
    var staleCancelled = false
    do { _ = try await stale.value } catch is CancellationError { staleCancelled = true } catch {}
    _ = try await fresh.value
    let finished = (await r2.snapshot()).finished
    check.expect(staleCancelled, "superseded read is cancelled")
    // The stale op may physically begin before the cancel lands, but it must never *finish*.
    check.expect(finished.contains("FRESH") && !finished.contains("STALE"), "newest read wins, stale never completes")
}

do {
    try await runDerivations()
    runBadge()
    try await runGraph()
    try await runExecutor()
} catch {
    print("FATAL: \(error)")
    exit(2)
}

print("")
if check.failures.isEmpty { print("ALL PASS"); exit(0) }
else { print("FAILURES: \(check.failures.count)"); exit(1) }
