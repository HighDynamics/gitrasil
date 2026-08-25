# Gitrasil

A macOS-native app that treats git worktrees as first-class citizens. One window = one
repository; one tab = one worktree.

See the handoff docs (design brief, history-view topology, engineering notes, architecture
decisions) for the full specification.

## Architecture

The guiding principle: **all logic lives below the SwiftUI layer.** Parsing, topology, status
derivation, git-command building, and command sequencing are plain, platform-agnostic Swift
(`GitrasilCore`) with no UI dependency — so ~90% of the app is unit-testable from the CLI. The
SwiftUI app shell (macOS 14+, Observation, SwiftTerm embedded terminal) is a thin render layer
added on top later.

### `GitrasilCore` (this package)

- **`Git/GitRunner`** — the only thing that shells out to `git` (via `/usr/bin/env`, honoring the
  user's PATH). A `GitRunning` protocol so tests inject a fake. Never uses libgit2; never runs a
  network command.
- **`Execution/WorktreeExecutor`** — per-worktree serial command executor (architecture decision
  #1). Mutations are exclusive; reads coalesce by kind (newest wins). This is the primitive that
  makes the "derive-and-publish" state model race-free.
- **`Derive/Derivations`** — pure, git-backed derivations (trunk detection, meeting commit, status
  facts). The highest-risk logic, tested directly against real fixture repos. Graph topology, the
  file-status overlay, and diff parsing land here next.
- **`Model/`** — immutable domain values (e.g. `StatusBadge`, `WorktreeStatusFacts`).

## Build & test

```bash
swift build
swift run gitrasil-smoke   # verifies the core end-to-end against real git
```

### Note on the test suite

The canonical tests are XCTest (`Tests/GitrasilCoreTests`), which is what CI runs. **They do not
run under this checkout's Xcode (14.3)** — its bundled XCTest helper is too old for the host macOS
and segfaults during test discovery. Until Xcode is updated (target: a modern Xcode with the
macOS 14 SDK), use `swift run gitrasil-smoke`, which mirrors the same assertions through a plain
executable. Once Xcode is current, `swift test` becomes the primary command and the smoke runner
can retire.

## Toolchain floors

- **git ≥ 2.30** (modern security baseline; all needed plumbing predates it).
- **macOS 14 (Sonoma)** for the app shell (mature SwiftUI + Observation).
