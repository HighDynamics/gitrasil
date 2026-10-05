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
swift test
```

Tests stand up real git repositories in temp dirs (`GitrasilTestSupport`) and assert on the
derived values — no mocking of git. The topology and status derivations, the highest-risk logic,
are covered case-by-case there.

## Run the app

```bash
scripts/run.sh /path/to/a/git/repo
```

This builds the app, wraps it in a minimal `.app` bundle, and launches it — necessary because a
bare SwiftPM executable is not reliably shown a window by macOS. Pass a repository path to open it
directly, or omit it and use **Open Repository…** in the window.

The window shows the worktree's status header, an interactive history graph (select a commit for
its detail panel and file diffs), a directory explorer (History / Files toggle), a file viewer, and
an embedded terminal scoped to the worktree — all refreshing live as the repo changes on disk. The
diff viewer is view-only. History mutations (rebase/drop/cherry-pick) are still to come.

## Live background spike

```bash
scripts/run-wallpaper.sh /path/to/a/git/repo [--quit-after <seconds>]
```

Draws the repo's branch graph in a desktop-level window behind the icons on the primary display, and
redraws as the repo changes. Ctrl-C removes it; nothing is installed. See
`docs/live-background/DESIGN.md`.

## Toolchain floors

- **git ≥ 2.30** (modern security baseline; all needed plumbing predates it).
- **macOS 14 (Sonoma)** for the app shell (mature SwiftUI + Observation).
