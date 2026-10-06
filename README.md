# Gitrasil

A live macOS desktop background that grows each pinned repository as a tree: the default branch is
the trunk, branches and worktrees are limbs (sub-branches where history forks again), commits are
leaves, and branch names hang on small banners from the tips. It sits behind the desktop icons and
grows as your repositories change. See `docs/yggdrasil/PLAN.md` for the design and how it got here
(`docs/live-background/` holds the earlier research and spike notes).

Gitrasil started as a worktree GUI (one window per repository, one tab per worktree). That app was
removed; it remains in git history up to the `Drop the worktree GUI` commit.

## Architecture

The guiding principle: **all logic lives below the UI layer.** Parsing, topology, layout and
settings are plain, platform-agnostic Swift (`GitrasilCore`) with no UI dependency, so most of it
is unit-testable from the CLI. The background (`GitrasilWallpaper`) is a thin AppKit/SwiftUI render
layer on top.

### `GitrasilCore`

- **`Git/GitRunner`** — the only thing that shells out to `git` (via `/usr/bin/env`, honoring the
  user's PATH). A `GitRunning` protocol so tests inject a fake. Never uses libgit2; never runs a
  network command.
- **`Execution/WorktreeExecutor`** — a serial command executor whose reads coalesce by kind (newest
  wins), so a burst of filesystem events collapses to one re-derive.
- **`Derive/`** — pure, git-backed derivations: trunk detection and the repository-wide
  `RepoGraph` (trunk, branches, worktree buds), tested directly against real fixture repos.
- **`Model/`** — immutable domain values: `RepoGraph`, and `RepoTree`, the graph as a tree (trunk,
  limbs, sub-limbs, buds).
- **`Layout/`** — `TreeLayout` turns a `RepoTree` into seeded, stable tree geometry, independent of
  any renderer; `YggdrasilLayout` joins several into one tree with a bough per repository;
  `BannerLayout` places the names (pennants for branches, ribbons for repositories) so none
  overlaps another.
- **`Reactive/`** — FSEvents watching, `FolderWatcher` (a pinned folder's entries), and
  `RepoGraphStore`, which keeps one repository's graph live (ref changes only, settled,
  fingerprint-gated).
- **`Settings/`** — `PinnedRepositories`, the saved pins (repositories, or folders of them) and the
  repositories they put on the background; `BackgroundSettings`, the arrangement and banner choices.

### `GitrasilWallpaper`

The desktop-level window, the menu-bar item, and the drawing. The look is a `WallpaperStyle` value
(currently ink on cream); the drawing code reads only that, so restyling is a new value. The
menu-bar icon is `Resources/MenuBarIcon.pdf`, drawn by `scripts/draw-icon.swift` (see
`MenuBarIcon.swift` for the format).

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

Pin repositories from the menu-bar item (the small tree), or a folder of them: a pinned folder
stands for every repository in it (one or two folders down), as they come and go. Pins are a
checklist in the menu; untick several in one visit. The background grows the first four (a folder
with more shows its most recently active) in a desktop-level window behind the icons on every
display, and redraws as they change.

The same menu holds the settings:

- **Arrange As** — *Orchard*, a tree per repository with its name beneath, or *Single Tree*, one
  tree with a bough per repository.
- **Banners** — *Branch Names*, each branch's name on a pennant at its tip, and *Repository
  Names*, in the single tree each repository's name on a ribbon under its bough. Each can be
  turned off on its own.
- **Sway in Gusts** — now and then a gust sways the banners for a few seconds, only on mains power
  with the display awake and the background uncovered.

Pins and settings are saved between launches in the `com.gitrasil.background` defaults. For a
test run or a preview:

- `GITRASIL_BACKGROUND_DEFAULTS_SUITE` names another defaults suite;
- `GITRASIL_BACKGROUND_APPEARANCE=light|dark` previews a mode (background and menu) without
  changing the system's;
- `GITRASIL_BACKGROUND_BREEZE=off` keeps the banners still whatever the setting.

Ctrl-C or the menu's Quit removes it; nothing is installed and the system wallpaper is never
changed.

## Toolchain floors

- **git ≥ 2.30** (modern security baseline; all needed plumbing predates it).
- **macOS 14 (Sonoma)** (SwiftUI + Observation).
