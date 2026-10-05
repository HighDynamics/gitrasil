# Gitrasil

A live macOS desktop background drawn from your git branch graph. It sits behind the desktop icons
and redraws as your repositories change. See `docs/live-background/DESIGN.md`.

Gitrasil started as a worktree GUI (one window per repository, one tab per worktree). That app was
removed; it remains in git history up to the `Drop the worktree GUI` commit.

## Architecture

The guiding principle: **all logic lives below the UI layer.** Parsing, topology, and command
sequencing are plain, platform-agnostic Swift (`GitrasilCore`) with no UI dependency, so most of it
is unit-testable from the CLI. The background (`GitrasilWallpaper`) is a thin AppKit/SwiftUI render
layer on top.

### `GitrasilCore`

- **`Git/GitRunner`** — the only thing that shells out to `git` (via `/usr/bin/env`, honoring the
  user's PATH). A `GitRunning` protocol so tests inject a fake. Never uses libgit2; never runs a
  network command.
- **`Execution/WorktreeExecutor`** — a serial command executor whose reads coalesce by kind (newest
  wins), so a burst of filesystem events collapses to one re-derive.
- **`Derive/`** — pure, git-backed derivations (trunk detection, graph topology), tested directly
  against real fixture repos.
- **`Layout/GraphLayout`** — turns a graph into lanes and rows, independent of any renderer.
- **`Reactive/`** — FSEvents watching and the observable stores the background renders from.
- **`Model/`** — immutable domain values.

## Build & test

```bash
swift build
swift test
```

Tests stand up real git repositories in temp dirs (`GitrasilTestSupport`) and assert on the
derived values — no mocking of git.

## Run the background

```bash
scripts/run-wallpaper.sh /path/to/a/git/repo [--quit-after <seconds>]
```

Draws the repo's branch graph in a desktop-level window behind the icons on the primary display, and
redraws as the repo changes. Ctrl-C removes it; nothing is installed.

## Toolchain floors

- **git ≥ 2.30** (modern security baseline; all needed plumbing predates it).
- **macOS 14 (Sonoma)** (SwiftUI + Observation).
