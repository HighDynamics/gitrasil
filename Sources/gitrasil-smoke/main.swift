import Foundation
import GitrasilCore

// Smoke runner: exercises the core against real git fixtures and the executor against a fake
// runner, printing PASS/FAIL and exiting non-zero on any failure. Mirrors the XCTest suite so
// we have a working verification path while the repo's Xcode is too old to run XCTest (see
// Package.swift). Not a replacement for XCTest — a bridge until the toolchain is updated.

// MARK: - Tiny assertion harness

final class Check {
    var failures: [String] = []
    func expect(_ condition: Bool, _ message: String) {
        if condition { print("  ✓ \(message)") }
        else { print("  ✗ \(message)"); failures.append(message) }
    }
    func equal<T: Equatable>(_ a: T, _ b: T, _ message: String) {
        expect(a == b, "\(message) (\(a) == \(b))")
    }
}

// MARK: - Inline fixture repo (mirrors Tests/.../FixtureRepo.swift)

let identity = [
    "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.com",
    "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.com",
]

func makeRepo() throws -> (URL, GitRunner) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gitrasil-smoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (dir, GitRunner(workdir: dir, extraEnvironment: identity))
}

func commit(_ runner: GitRunner, _ dir: URL, file: String, _ contents: String, message: String, seq: Int) async throws {
    try contents.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    _ = try await runner.runChecked(["add", "-A"])
    let date = "2026-01-01T00:00:\(String(format: "%02d", seq))"
    let dated = GitRunner(workdir: dir, extraEnvironment: identity.merging(
        ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]) { $1 })
    _ = try await dated.runChecked(["commit", "-q", "-m", message])
}

// MARK: - Runs

let check = Check()

func runDerivations() async throws {
    print("Derivations (real git):")
    let (dir, runner) = try makeRepo()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try await runner.runChecked(["init", "-q", "-b", "main"])
    try await commit(runner, dir, file: "a.txt", "1", message: "root", seq: 1)

    let trunk = try await Derivations.resolveTrunk(runner: runner)
    check.equal(trunk, "main", "resolveTrunk finds main")

    let override = try await Derivations.resolveTrunk(runner: runner, override: "develop")
    check.equal(override, "develop", "resolveTrunk honors override")

    let root = try await runner.runChecked(["rev-parse", "HEAD"]).trimmedStdout
    _ = try await runner.runChecked(["checkout", "-q", "-b", "feature"])
    try await commit(runner, dir, file: "b.txt", "2", message: "feature", seq: 2)
    _ = try await runner.runChecked(["checkout", "-q", "main"])
    try await commit(runner, dir, file: "c.txt", "3", message: "main ahead", seq: 3)

    let base = try await Derivations.mergeBase("main", "feature", runner: runner)
    check.equal(base, root, "mergeBase is the shared root")

    let behind = try await Derivations.isBehind(meeting: base, trunk: "main", runner: runner)
    check.expect(behind, "isBehind true when trunk advanced")

    var dirty = try await Derivations.isDirty(runner: runner)
    check.expect(!dirty, "clean tree is not dirty")
    try "changed".write(to: dir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
    dirty = try await Derivations.isDirty(runner: runner)
    check.expect(dirty, "uncommitted change is dirty")
}

func runBadge() {
    print("Status badge precedence:")
    check.equal(WorktreeStatusFacts(inProgress: true, dirty: true, behind: true).badge, .conflicted, "conflicted wins all")
    check.equal(WorktreeStatusFacts(dirty: true, behind: true).badge, .modified, "modified beats behind")
    check.equal(WorktreeStatusFacts(behind: true).badge, .behind, "behind alone")
    check.expect(WorktreeStatusFacts().badge == nil, "clean shows no badge")
}

// A minimal fake runner recording execution order (mirrors Tests/.../RecordingRunner.swift).
actor Recorder: GitRunning {
    private(set) var finished: [String] = []
    private(set) var started: [String] = []
    let delay: Duration
    init(delay: Duration) { self.delay = delay }
    nonisolated func run(_ args: [String]) async throws -> GitOutput {
        let label = args.joined(separator: " ")
        await note(started: label)
        try? await Task.sleep(for: delay)
        try Task.checkCancellation()
        await note(finished: label)
        return GitOutput(status: 0, stdout: Data(label.utf8), stderr: Data())
    }
    private func note(started s: String) { started.append(s) }
    private func note(finished s: String) { finished.append(s) }
    func snapshot() -> ([String], [String]) { (started, finished) }
}

func runExecutor() async throws {
    print("Executor serialization & coalescing:")

    let r1 = Recorder(delay: .milliseconds(80))
    let e1 = WorktreeExecutor(runner: r1)
    let m = await e1.mutate { try await $0.run(["MUTATION"]) }
    let rd = await e1.read(.statuses) { try await $0.run(["READ"]) }
    _ = try await m.value; _ = try await rd.value
    let (_, finished1) = await r1.snapshot()
    check.equal(finished1, ["MUTATION", "READ"], "read finishes after the mutation it queued behind")

    let r2 = Recorder(delay: .milliseconds(80))
    let e2 = WorktreeExecutor(runner: r2)
    let stale = await e2.read(.graph) { try await $0.run(["STALE"]) }
    let fresh = await e2.read(.graph) { try await $0.run(["FRESH"]) }
    var staleCancelled = false
    do { _ = try await stale.value } catch is CancellationError { staleCancelled = true } catch {}
    _ = try await fresh.value
    let (started2, _) = await r2.snapshot()
    check.expect(staleCancelled, "superseded read is cancelled")
    check.expect(started2.contains("FRESH") && !started2.contains("STALE"), "newest read wins, stale never runs")
}

do {
    try await runDerivations()
    runBadge()
    try await runExecutor()
} catch {
    print("FATAL: \(error)")
    exit(2)
}

print("")
if check.failures.isEmpty {
    print("ALL PASS")
    exit(0)
} else {
    print("FAILURES: \(check.failures.count)")
    exit(1)
}
