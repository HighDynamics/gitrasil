import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class GraphDerivationTests: XCTestCase {

    func testCaseA_singleLaneNoFork() async throws {
        let repo = try await Topology.caseA()
        let graph = try await Derivations.historyGraph(runner: repo.runner)

        XCTAssertEqual(graph.segments.count, 1)
        XCTAssertEqual(graph.segments.first?.kind, .currentWorktree)
        XCTAssertEqual(graph.segments.first?.commits.map(\.subject), ["cw-2", "cw-1"])
        XCTAssertNil(graph.trunkAhead, "main is not ahead")
        XCTAssertEqual(graph.branchesBetween, 0)
        XCTAssertEqual(graph.meetingCommit?.subject, "root")
        XCTAssertFalse(graph.hasUncommittedChanges)
    }

    func testCaseB_trunkAheadForkLane() async throws {
        let repo = try await Topology.caseB()
        let graph = try await Derivations.historyGraph(runner: repo.runner)

        XCTAssertEqual(graph.segments.map(\.kind), [.currentWorktree])
        XCTAssertEqual(graph.segments.first?.commits.map(\.subject), ["cw-1"])
        XCTAssertEqual(graph.trunkAhead?.kind, .trunkAhead(branch: "main"))
        XCTAssertEqual(graph.trunkAhead?.commits.map(\.subject), ["main-ahead-2", "main-ahead-1"])
        XCTAssertEqual(graph.meetingCommit?.subject, "root")
    }

    func testCaseC_oneIntermediateSegment() async throws {
        let repo = try await Topology.caseC()
        let graph = try await Derivations.historyGraph(runner: repo.runner)

        XCTAssertEqual(graph.segments.map(\.kind), [.currentWorktree, .intermediate(branch: "feature")])
        XCTAssertEqual(graph.segments[0].commits.map(\.subject), ["cw-1"])
        XCTAssertEqual(graph.segments[1].commits.map(\.subject), ["feature-2", "feature-1"])
        XCTAssertEqual(graph.branchesBetween, 1)
        XCTAssertNil(graph.trunkAhead)
    }

    func testChained_twoIntermediatesInAncestryOrder() async throws {
        let repo = try await Topology.chained()
        let graph = try await Derivations.historyGraph(runner: repo.runner)

        XCTAssertEqual(graph.segments.map(\.kind),
                       [.currentWorktree, .intermediate(branch: "feature-b"), .intermediate(branch: "feature-a")])
        XCTAssertEqual(graph.segments[1].commits.map(\.subject), ["fb-2", "fb-1"])
        XCTAssertEqual(graph.segments[2].commits.map(\.subject), ["fa-2", "fa-1"])
        XCTAssertEqual(graph.branchesBetween, 2)
    }

    func testTruncation_intermediateCollapsesToTip() async throws {
        let repo = try await Topology.truncatedIntermediate(count: 7)
        let graph = try await Derivations.historyGraph(runner: repo.runner)

        let feature = graph.segments.first { $0.kind == .intermediate(branch: "feature") }
        XCTAssertNotNil(feature)
        XCTAssertEqual(feature?.commits.count, 7, "full run is preserved")
        XCTAssertTrue(feature?.isTruncatable ?? false)
        XCTAssertEqual(feature?.hiddenCount, 6)
        XCTAssertEqual(feature?.collapsedCommits.count, 1, "collapses to just its tip")
        XCTAssertEqual(feature?.collapsedCommits.first?.subject, "feature-7")
    }

    func testCurrentWorktreeIsNeverTruncated() async throws {
        let repo = try await Topology.longCurrentWorktree(count: 7)
        let graph = try await Derivations.historyGraph(runner: repo.runner)

        let cw = graph.segments.first
        XCTAssertEqual(cw?.kind, .currentWorktree)
        XCTAssertEqual(cw?.commits.count, 7)
        XCTAssertFalse(cw?.isTruncatable ?? true, "cw is exempt from truncation")
        XCTAssertEqual(cw?.hiddenCount, 0)
        XCTAssertEqual(cw?.collapsedCommits.count, 7)
    }

    func testMergeCommitsCollapseToFirstParent() async throws {
        let repo = try await Topology.mergeOnCurrentWorktree()
        let graph = try await Derivations.historyGraph(runner: repo.runner)

        let subjects = graph.segments.flatMap { $0.commits.map(\.subject) }
        XCTAssertTrue(subjects.contains("merge-side"))
        XCTAssertTrue(subjects.contains("cw-2"))
        XCTAssertTrue(subjects.contains("cw-1"))
        XCTAssertFalse(subjects.contains("side-1"), "second-parent commit must not appear")
    }

    func testEmptyRepo() async throws {
        let repo = try await Topology.empty()
        let graph = try await Derivations.historyGraph(runner: repo.runner)
        XCTAssertTrue(graph.isEmpty)
        XCTAssertNil(graph.meetingCommit)
    }

    func testDetachedHead() async throws {
        let repo = try await Topology.detached()
        let graph = try await Derivations.historyGraph(runner: repo.runner)
        XCTAssertTrue(graph.isDetached)
        XCTAssertFalse(graph.isEmpty)
    }

    func testOnTrunk() async throws {
        let repo = try await Topology.onTrunk()
        let graph = try await Derivations.historyGraph(runner: repo.runner)
        XCTAssertTrue(graph.isOnTrunk)
        XCTAssertTrue(graph.segments.isEmpty, "no divergence, so no cw commits")
        XCTAssertNil(graph.trunkAhead)
        XCTAssertEqual(graph.meetingCommit?.subject, "root-2")
    }

    func testRevealedBranchAppearsAsLane() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.createBranch("other")
        try await repo.commitFile("o.txt", "o\n", message: "on-other-1")
        try await repo.commitFile("o2.txt", "o2\n", message: "on-other-2")
        try await repo.checkout("main")
        try await repo.createBranch("cw")
        try await repo.commitFile("cw.txt", "cw\n", message: "cw-1")

        let bare = try await Derivations.historyGraph(runner: repo.runner)
        XCTAssertTrue(bare.revealedLanes.isEmpty, "nothing revealed by default")

        let graph = try await Derivations.historyGraph(runner: repo.runner, revealedBranches: ["other"])
        XCTAssertEqual(graph.revealedLanes.count, 1)
        XCTAssertEqual(graph.revealedLanes.first?.kind, .revealed(branch: "other"))
        XCTAssertEqual(graph.revealedLanes.first?.commits.map(\.subject), ["on-other-2", "on-other-1"])
    }

    func testRevealedBranchExcludesTrunkAndCwCommits() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.createBranch("cw")
        try await repo.commitFile("cw.txt", "cw\n", message: "cw-1")
        try await repo.checkout("main")
        try await repo.commitFile("m.txt", "m\n", message: "main-ahead")
        // Branch off the advanced main, so main-ahead is an ancestor of the revealed branch.
        try await repo.createBranch("fix")
        try await repo.commitFile("fix.txt", "f\n", message: "fix-only")
        try await repo.checkout("cw")

        let graph = try await Derivations.historyGraph(runner: repo.runner, revealedBranches: ["fix"])
        let lane = graph.revealedLanes.first
        XCTAssertEqual(lane?.commits.map(\.subject), ["fix-only"],
                       "revealed lane shows only commits unique to the branch, not main's ahead-commits")
    }

    func testRevealedBranchPartitionsAtIntermediary() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()                                    // main
        try await repo.commitFile("r.txt", "r\n", message: "root")
        try await repo.createBranch("seed")
        try await repo.commitFile("b1.txt", "1\n", message: "base-1")
        try await repo.commitFile("b2.txt", "2\n", message: "base-2")
        try await repo.git(["branch", "mid"])                        // intermediary tip at base-2
        try await repo.commitFile("o1.txt", "1\n", message: "own-1")
        try await repo.commitFile("o2.txt", "2\n", message: "own-2") // seed tip
        try await repo.checkout("main")
        try await repo.createBranch("cw")                            // cw diverges from seed at root
        try await repo.commitFile("cw.txt", "c\n", message: "cw-1")

        let graph = try await Derivations.historyGraph(runner: repo.runner, revealedBranches: ["seed"])
        // seed's own commits stay a .revealed segment; the `mid` intermediary is split into its own
        // .intermediate segment rather than being swallowed into seed's lane.
        let revealed = graph.revealedLanes.first { if case .revealed = $0.kind { return true } else { return false } }
        let intermediate = graph.revealedLanes.first { if case .intermediate = $0.kind { return true } else { return false } }
        XCTAssertEqual(revealed?.kind, .revealed(branch: "seed"))
        XCTAssertEqual(revealed?.commits.map(\.subject), ["own-2", "own-1"])
        XCTAssertEqual(intermediate?.kind, .intermediate(branch: "mid"))
        XCTAssertEqual(intermediate?.commits.map(\.subject), ["base-2", "base-1"])
    }

    func testRevealedBranchWithNoOwnCommitsBecomesPointer() async throws {
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.createBranch("cw")
        let c1 = try await repo.commitFile("c1.txt", "1\n", message: "c1")
        try await repo.commitFile("c2.txt", "2\n", message: "cw tip")
        try await repo.git(["branch", "parked", c1])   // points at a commit already on cw's spine

        let graph = try await Derivations.historyGraph(runner: repo.runner, revealedBranches: ["parked"])
        XCTAssertTrue(graph.revealedLanes.isEmpty, "no lane — parked adds no commits of its own")
        XCTAssertEqual(graph.revealedPointers[c1], ["parked"],
                       "the branch is kept as a ref pill on the commit it points at, not dropped")
    }

    func testCwSpineLabelsSharedForkByItsOwnLineage() async throws {
        // Two parallel worktrees, `feature` (lex-first) and `qa`, sit at the same fork commit; cw was
        // created from `qa`. cw's own view must name `qa` at the fork — its true ancestor — and must
        // not surface the coincidental sibling `feature` at all.
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.createBranch("feature")
        try await repo.commitFile("f1.txt", "1\n", message: "f1")
        try await repo.commitFile("f2.txt", "2\n", message: "f2")   // fork commit
        // qa is a sibling worktree parked at the same commit, with no recorded lineage of its own
        // (update-ref writes no "Created from" reflog) — exactly the real coincidental-sibling case.
        try await repo.git(["update-ref", "refs/heads/qa", "refs/heads/feature"])
        try await repo.createBranch("cw")                           // cw off the fork
        try await repo.commitFile("c1.txt", "1\n", message: "cw tip")
        try await repo.git(["symbolic-ref", "refs/gitrasil/parent/cw", "refs/heads/qa"])

        let graph = try await Derivations.historyGraph(runner: repo.runner)

        XCTAssertEqual(graph.segments.map(\.kind),
                       [.currentWorktree, .intermediate(branch: "qa")],
                       "the fork is labeled by cw's own origin, not the lex-first sibling")
        XCTAssertFalse(graph.segments.contains { $0.kind == .intermediate(branch: "feature") },
                       "a coincidental sibling worktree must not appear")
        XCTAssertTrue(graph.revealedPointers.isEmpty,
                      "cw's own origin is the spine label, not a sliver on its own view")
    }

    func testRevealedBranchSurfacesItsRecordedParent() async throws {
        // cw is `feature`; `qa` (a sibling worktree) sits at feature's tip; `child` was created from
        // qa. Revealing `child` should surface `qa` as a pointer on the shared commit and record it
        // as child's parent, so child's fork joins qa rather than the bare commit.
        let repo = try FixtureRepo()
        try await repo.initRepo()
        try await repo.commitFile("a.txt", "a\n", message: "root")
        try await repo.createBranch("feature")
        try await repo.commitFile("f1.txt", "1\n", message: "f1")
        let fork = try await repo.commitFile("f2.txt", "2\n", message: "f2")
        try await repo.git(["update-ref", "refs/heads/qa", "refs/heads/feature"])  // sibling, no lineage
        try await repo.git(["checkout", "-q", "-b", "child", "qa"])
        try await repo.commitFile("ch1.txt", "1\n", message: "ch1")
        try await repo.git(["symbolic-ref", "refs/gitrasil/parent/child", "refs/heads/qa"])
        try await repo.git(["checkout", "-q", "feature"])

        let graph = try await Derivations.historyGraph(runner: repo.runner, revealedBranches: ["child"])

        XCTAssertEqual(graph.branchParents["child"], "qa")
        XCTAssertEqual(graph.revealedPointers[fork], ["qa"],
                       "child's recorded origin is surfaced so its fork can join it")
    }

    func testUncommittedChangesFlag() async throws {
        let repo = try await Topology.caseA()
        try repo.writeFile("cw1.txt", "dirty")
        let graph = try await Derivations.historyGraph(runner: repo.runner)
        XCTAssertTrue(graph.hasUncommittedChanges)
    }
}
