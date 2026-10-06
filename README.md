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
- **`Reactive/`** — FSEvents watching and `RepoGraphStore`, which keeps one repository's graph live
  (ref changes only, settled, fingerprint-gated).
- **`Settings/`** — `PinnedRepositories`, the saved list of repositories the background draws.
- **`Model/`** — immutable domain values.

### `GitrasilWallpaper`

The desktop-level window, the menu-bar item, and the drawing. The look is a `WallpaperStyle` value
(currently ink on cream); the drawing code reads only that, so restyling is a new value.

## Build & test

```bash
swift build
swift test
```

Tests stand up real git repositories in temp dirs (`GitrasilTestSupport`) and assert on the
derived values — no mocking of git.

## Run the background

```bash
scripts/run-wallpaper.sh [--quit-after <seconds>]
```

Pin repositories from the menu-bar item (the branch icon). The background draws the first four side
by side, in a desktop-level window behind the icons on every display, and redraws as they change. Pins are saved between launches in the `com.gitrasil.background` defaults
(`GITRASIL_BACKGROUND_DEFAULTS_SUITE` names another suite, e.g. for a test run).
`GITRASIL_BACKGROUND_APPEARANCE=light|dark` previews a mode without changing the system's. Ctrl-C or
the menu's Quit removes it; nothing is installed and the system wallpaper is never changed.

## Toolchain floors

- **git ≥ 2.30** (modern security baseline; all needed plumbing predates it).
- **macOS 14 (Sonoma)** (SwiftUI + Observation).
