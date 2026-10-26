# Gitrasil

A live macOS desktop background that grows each pinned repository as a tree: the default branch is
the trunk, branches and worktrees are limbs (sub-branches where history forks again), commits are
leaves, and branch names hang on small banners from the tips. It sits behind the desktop icons and
grows as your repositories change. See `docs/yggdrasil/PLAN.md` for the design and how it got here
(`docs/live-background/` holds the earlier research and spike notes).

## Foreword

This started as a tool for keeping tabs on git worktrees, since AI agents are now doing a lot of
work in them at once. Turns out plenty of people had the same idea, and those tools are coming along
nicely. So I pivoted.

Gitrasil still grows from your data, but it isn't trying to inform you. It's trying to be nice to
look at. Your repos become a tree on your desktop, and it grows while you work. That's it. That's
the app.

And to be crystal clear: it only reads your local git. No fetch, no pull, no talking to remotes. The
only network request it can ever make is a check for a new version, and that's off unless you turn
it on.

The original worktree GUI is in git history, up to the `Drop the worktree GUI` commit.

## Install

Download `Gitrasil-<version>.dmg` (or the `.zip`) from the
[latest release](https://github.com/HighDynamics/gitrasil/releases/latest). Open the disk image and
drag Gitrasil onto Applications; from the zip, double-click it and move Gitrasil to Applications
yourself. It needs macOS 14 or later and runs on Apple silicon and Intel Macs. Then open it
from Spotlight: it lives in the menu bar (no Dock icon), and its menu has Quit.

Releases aren't notarized by Apple, so the first time you open Gitrasil, and again for each new
version, macOS says it can't verify the app. Click **Done**, open System Settings → Privacy &
Security, scroll down to *"Gitrasil" was blocked* and click **Open Anyway**, then confirm with your
password. Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Gitrasil.app`. Move it to
Applications first: an app run from Downloads or the disk image can't open at login. More in
`docs/distribution.md`.

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
  repositories they put on the background; `BackgroundSettings`, the arrangement, banner and medium
  choices.
- **`Updates/`** — `UpdateCheck`, the app's opt-in, at-most-daily look at GitHub Releases for a
  newer version.
- **`Layout/HandDrawn.swift`** — the seeded noise behind the hand-drawn wobble and the paper's
  textures: the same seed gives the same line on every redraw.

### `GitrasilWallpaper`

The desktop-level window, the menu-bar item, and the drawing. The look is a `WallpaperStyle` value,
one per medium (ink, charcoal, chalk) and mode; the drawing code reads only that, so restyling is a
new value. `Sketch` draws a line by hand (wobbling, its width varying along it), and `Textures`
makes the dry media's paper tooth, board dust and grain once and tiles them. The
menu-bar icon is `Resources/MenuBarIcon.pdf`, drawn by `scripts/draw-icon.swift` (see
`MenuBarIcon.swift` for the format). `AppServices` is what it does only when run as `Gitrasil.app`:
open at login (`SMAppService`) and schedule the update check.

## Build & test

```bash
swift build
swift test
```

Tests stand up real git repositories in temp dirs (`GitrasilTestSupport`) and assert on the
derived values — no mocking of git.

## Quality checks

```bash
scripts/check.sh          # everything CI runs: format, lint, build, test
scripts/check.sh format   # SwiftFormat, check only (`scripts/check.sh fix` rewrites the files)
scripts/check.sh lint     # SwiftLint --strict
scripts/check.sh build    # release build with warnings as errors
scripts/check.sh test     # swift test
```

SwiftFormat and SwiftLint are downloaded at pinned, checksummed versions into `.build/tools/` on
first use, so local and CI results match. CI (`.github/workflows/ci.yml`) runs the same four
checks, as the jobs **Format**, **Lint**, **Build** and **Test**, on every pull request and push to
main; a ruleset on `main` requires all four, and pull requests merge with merge commits only.
Which tools, and why: `docs/ci-quality.md`.

## Run the background

```bash
scripts/run-wallpaper.sh [--quit-after <seconds>]
```

It builds and runs the release build (`.build/out/Products/Release/GitrasilWallpaper`): placing
the banners over a dense crown is slow in a debug build.

The same binary has three offscreen aids, which draw the pinned repositories without a window and
quit:

- `--benchmark [runs]` prints the median time (ms) to draw the trees, a frame of them growing in,
  the paper and the banners, for each arrangement, medium, screen size and mode;
- `--snapshot <folder>` writes `<medium>-<arrangement>-<mode>.jpg` at 1440×900@2x;
- `--frames <folder>` grows the whole scene again, as Watch Gitrasil Grow does, and writes it as
  `frame-NNN.jpg`, 20 a second of its clock, at 1440×900@2x in the saved arrangement and medium.

Pin repositories from the menu-bar item (the small tree), or a folder of them: a pinned folder
stands for every repository in it (one or two folders down), as they come and go. Pins are a
checklist in the menu; untick several in one visit. The background grows the first twelve (a folder
with more shows its most recently active; the Forest setting below lifts this to sixty-four) in a
desktop-level window behind the icons on every display, and redraws as they change.

The same menu holds the settings:

- **Arrange As** — *Orchard*, a tree per repository with its name beneath, or *Single Tree*, one
  tree with a bough per repository.
- **Forest** — off by default. Off, the background shows at most twelve repositories. On, it shows
  up to sixty-four: the single tree keeps the most recently active (twelve on a laptop's height,
  twenty on a taller display) and the rest stand behind it in a forest of paler, smaller trees in
  rows on either side; an orchard of more than twelve goes into the same rows. Only the tree and the
  forest's front line carry names. Which repository stands where is decided at launch and again
  after midnight, not as commits arrive, and the trees grow again when that order changes.
- **Repos on the Tree** — how many repositories the single tree holds: *Automatic* (the default, as
  above), or 4, 8, 12, 16, 20 or 24. With the Forest on the rest stand behind it; with it off the
  background shows no more than the tree holds (and never more than twelve), the first ones pinned.
  Changing it grows the trees again.
- **Banners** — *Branch Names*, each branch's name on a pennant at its tip, and *Repository
  Names*, in the single tree each repository's name on a ribbon under its bough. Each can be
  turned off on its own.
- **Medium** — *Ink*, brush ink on cream paper; *Charcoal*, charcoal and coloured pastel on paper
  with a tooth; or *Chalk*, coloured chalk on a slate board (a green-grey board in light mode, a
  near-black one in dark), the default. Every medium draws by hand: lines wobble and vary in width.
- **Sway in Gusts** — now and then a gust sways the banners for a few seconds, on battery too but
  not in Low Power Mode, with a display awake and the background uncovered. Off by default: the banners
  hang still until it's turned on, and turning it on blows the first gust at once, even in Low Power
  Mode (or, with the background covered or the displays asleep, the moment they're back).
- **Watch Gitrasil Grow** — grows every tree again from the ground, just to watch. The scene also
  grows again on its own when a repository is dropped.
- **Reshuffle Branches** — grows every tree again with its branches leaning and curving a new way.
  The branching itself (which branch leaves where) still comes from the history, the hand-drawn
  wobble stays as it was, and the new shape is kept between launches. Until the first reshuffle the
  trees take the shape their names alone give.

Pins and settings are saved between launches in the `com.gitrasil.background` defaults. For a
test run or a preview:

- `GITRASIL_BACKGROUND_DEFAULTS_SUITE` names another defaults suite;
- `GITRASIL_BACKGROUND_APPEARANCE=light|dark` previews a mode (background and menu) without
  changing the system's;
- `GITRASIL_BACKGROUND_BREEZE=off` keeps the banners still whatever the setting;
- `GITRASIL_BACKGROUND_WOBBLE=off` draws every line straight, as before the hand-drawn look (ink
  is then exactly as it was).

Ctrl-C or the menu's Quit removes it; nothing is installed and the system wallpaper is never
changed.

## The app

```bash
scripts/build-app.sh [--native] [--install]   # dist/Gitrasil.app
scripts/package-app.sh                        # dist/Gitrasil-<version>.zip and .dmg, for a release
```

`build-app.sh` puts the release build in `Gitrasil.app` (universal, ad-hoc signed, the version from
`VERSION`), which opens from Finder or Spotlight like any app; `--install` also copies it to
`/Applications`. The app's menu has three more items: **Open at Login** (off until ticked), **Check
for Updates Daily** (off until ticked; once a day it asks GitHub whether a newer release is out and
sends nothing else) and **Check for Updates Now**. A newer release puts *Gitrasil X.Y.Z Is
Available* at the top of the menu, which opens its page. To try the app on a throwaway suite:
`open -n --env GITRASIL_BACKGROUND_DEFAULTS_SUITE=<suite> dist/Gitrasil.app`;
`GITRASIL_RELEASES_REPOSITORY=<owner/name>` points the update check at another repository's
releases.

Pushing a tag `v` + `VERSION` runs `.github/workflows/release.yml`, which builds, packages and
attaches both to a draft release. Signing, notarization, launch at login and the update choices are
in `docs/distribution.md`.

## Toolchain floors

- **git ≥ 2.30** (modern security baseline; all needed plumbing predates it).
- **macOS 14 (Sonoma)** (SwiftUI + Observation).

## Licence

Gitrasil is released under the [MIT licence](LICENSE).
