# Gitrasil as a live desktop background — design note

> Kept as the record of the research and the first spike. The background has since moved on
> (it draws trees, not a branch graph); `docs/yggdrasil/PLAN.md` describes what is built.

Status: phase 2 on `spike/live-background`. The background is the `GitrasilWallpaper` target, run
with `scripts/run-wallpaper.sh`; repos are pinned from its menu-bar item. Sections 1–5 are the
phase 1 research; "Phase 2" near the end records what was decided and built since.

## Recommendation in brief

Draw the graph in a **borderless window at the desktop window level** (`kCGDesktopWindowLevel`),
one per screen. It sits in front of the system wallpaper and behind Finder's desktop icons, and it
shows on every Space. Ship it as a menu-bar-only agent app (no Dock icon). The app watches only the
repos' git dirs, derives with the existing core, and redraws only when the graph changes. A short
transition plays on each change and then rendering goes fully idle. Treat `setDesktopImageURL`
stills as a possible opt-in extra for Mission Control and the lock screen, not as the main
mechanism.

The spike shows that the window sits at the right level, that the core layout carries over, and
that updates arrive live (see "What the spike showed" at the end).

## 1. How to show it

macOS has no public live-wallpaper API. There are three realistic options:

| | Desktop-level window (Plash-style) | Screen saver (`.saver`) | Periodic still via `NSWorkspace.setDesktopImageURL` |
|---|---|---|---|
| Live animation | Yes | Yes, but only while the saver runs | No (the system crossfades between stills) |
| Visible during normal work | Yes, wherever the desktop shows | No: only when idle or locked | Yes |
| Multiple displays | One window per `NSScreen` | One view per screen (handled by the host) | One call per screen |
| Spaces | `.canJoinAllSpaces`: one window covers every Space on its display | n/a | Sets **only the active Space** on each screen; other Spaces keep the old picture (a long-standing limitation) |
| Full-screen apps | Hidden behind them; occlusion notifications let it pause | n/a | n/a |
| Mission Control / Spaces bar | Mission Control's backdrop and Space thumbnails show the *system* wallpaper, not our window | n/a | Correct everywhere, including the lock screen |
| Touches user settings | No | Installing a saver, and selecting it | **Yes**: it overwrites the user's wallpaper and must restore it on quit |
| Cost | Our own rendering. Zero when idle if done right | Runs in `legacyScreenSaver`, a host with known bugs on Sonoma+ (instances that never stop) | A PNG write per change, plus the system's own wallpaper work |

**Recommended: the desktop-level window.** It is the only option that is live while you work, and
it leaves the user's settings alone. Plash and similar apps have relied on this behaviour for
years. Details, as the spike sets them (`Sources/GitrasilWallpaper/DesktopWindow.swift`):

- `level = CGWindowLevelForKey(.desktopWindow)`. Finder's icon window sits at `.desktopIconWindow`
  (desktop + 20), so we stay behind the icons. Verified with `CGWindowListCopyWindowInfo` while the
  spike ran: our window was at layer −2147483623, Dock's `Wallpaper-` window at −2147483624 behind
  it, and Finder's icon window at −2147483603 in front of it.
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]`. It
  appears on every Space, stays put through Mission Control/Exposé and Show Desktop, never appears
  in window cycling, and never becomes a full-screen Space.
- `ignoresMouseEvents = true`, and the window can't become key or main. Clicks, drag-selection and
  the right-click menu still reach the Finder desktop.
- `NSApp.setActivationPolicy(.accessory)`: no Dock icon or menu bar. The real app would add a
  status item for choosing repos, pausing and quitting.

The rest of the window behaviour, still to verify in the real app:

- **Multiple displays:** one window per `NSScreen`, rebuilt on
  `NSApplication.didChangeScreenParametersNotification`. Each screen can show a different repo, or
  one graph can span all of them. The spike covers the primary display only.
- **"Displays have separate Spaces"** on or off: `.canJoinAllSpaces` works per display either way.
- **Full-screen apps:** a full-screen Space has no desktop, so our window is fully covered. The
  window gets `didChangeOcclusionStateNotification` and pauses (wired up in the spike, not yet
  exercised).
- **Mission Control:** our window stays in place behind the zoomed-out windows, but the Spaces bar
  thumbnails show the system wallpaper. If that mismatch bothers Daniel, the hybrid fix is to also
  set a still snapshot through `setDesktopImageURL` on a slow cadence (say, after a change settles).
  That one is opt-in because it changes his wallpaper setting.
- **Sonoma's "click wallpaper to reveal desktop":** clicks fall through to Finder, which triggers
  the reveal. Normal windows slide away and ours is `.stationary`, so it should stay. Needs a
  manual check.
- **Desktop widgets, the menu bar and the Dock** are all drawn above us. The translucent menu bar
  picks up our colours.
- **Screen sharing and screenshots** capture the window the same way they capture a wallpaper.

A **screen saver** is worth keeping as a later bonus: the same renderer in a `ScreenSaverView`.
It is not the product, though.

## 2. What it draws

### Which repos

- **Default:** the most recently active repos under `~/repos`, ranked by the newest ref or reflog
  mtime in each git dir. Show one to three of them, and swap gently when another repo becomes the
  most active.
- **Override:** a menu-bar picker that pins specific repos.
- Drawing *all* of `~/repos` at once would be noise. The watcher can still cover every repo
  cheaply (one FSEvents stream accepts many paths) so the ranking stays live.

### Which history

The current derivation is **worktree-relative**. It draws the meeting commit, the current
worktree's spine, a trunk-ahead fork, and any revealed lanes. On a repo that sits on trunk, that
is a single dot. A wallpaper wants a **repo-centric** view:

- the trunk as the spine, showing its last N commits (about 20–40, sized to the screen);
- each local branch with recent activity (`for-each-ref --sort=-committerdate`, last K days, capped
  at about 6–8) as a lane that forks off at its merge-base with trunk;
- worktrees marked, with the checked-out branch highlighted in the identity colour;
- no SHAs or authors: subjects as quiet captions at most, plus branch names at lane tips.

The spike approximates this with no new derivation. It reveals the repo's other branches through
`WorktreeStore.reveal`, which the existing `historyGraph` turns into lanes. A proper
`Derivations.repoGraph` should emit the same `HistoryGraph` shape so that `GraphLayout` keeps
working unchanged.

### Visual directions

1. **Night transit** (what the spike draws): a deep indigo gradient with a soft bloom. Lanes are
   glowing lines, like a transit map at night, and forks ease in on curves. The checked-out branch
   is warm amber and other branches take cool tones (teal, violet, sky). Commit subjects are faint
   captions and the repo name is a huge ultralight watermark. When nothing is happening it reads as
   a calm abstract picture, and a change shows up as a small flare.
2. **Ink on cream** (ties to the planned cream theme mockups): a warm paper ground with fine
   ink-brown lines in the style of a botanical plate. Trunk is the stem and branches grow as limbs
   with tapering strokes. Commits are small seed-like marks that age from dark ink to faded sepia,
   and labels are set in a serif. It would follow the light/dark appearance, using a charcoal paper
   at night.
3. **Constellation:** commits are stars on near-black. A star's size comes from the commit's diff
   size and its brightness from recency, so old history fades into the background. Branches are
   faint constellation lines. A new commit flares and settles, and an idle repo dims slowly over
   days instead of minutes, so nothing animates per frame.

Whichever direction wins, a few rules apply: there's no fixed per-frame motion; the picture follows
the system appearance; content stays clear of the menu bar, the Dock and where desktop icons
usually sit; and recency, not raw topology, decides what is bright.

## 3. Live updates

What exists today (`Sources/GitrasilCore/Reactive/`):

- `FSEventsWatcher` watches paths recursively with 0.15 s latency.
- `WorktreeStore` watches the worktree directory **and** its git dirs. Each event sends a re-derive
  through `WorktreeExecutor`, which coalesces bursts so the newest one wins. The store then
  publishes a fresh `WorktreeSnapshot` through Observation.

What the spike does with it (`WallpaperModel`): it re-arms `withObservationTracking` on
`store.snapshot` and compares the new `HistoryGraph` (which is `Equatable`) with the one it has.
It republishes, and so redraws, only when the graph actually changed.

What the real app should change:

- **Watch git dirs only:** the common dir's `refs/`, `packed-refs`, `HEAD`, `logs/` and
  `worktrees/*/HEAD`, never the working trees. Today an editor save or a build writing `.build/`
  triggers a full re-derive. The spike shows this: an untracked file caused a redraw, because the
  graph tracks dirtiness. A wallpaper can drop dirtiness, or poll it once a minute.
- **Settle before deriving.** Use 1–2 s of FSEvents latency plus a short quiet-period debounce,
  so a rebase or a scripted `checkout; commit; checkout` lands as **one** redraw. In the spike that
  sequence produced three redraws within a second (#4–#6), each with an intermediate state.
- **Gate on a cheap fingerprint.** Hash `git for-each-ref` and `HEAD` (one process) and skip the
  full derive, which takes about 10–20 git spawns, when the hash hasn't changed.
- **Use one stream for many repos.** A single `FSEventStream` can carry every watched git dir. The
  event paths say which repo changed.

What animates (each transition runs ≤ 1.5 s at a 30 fps cap, then rendering stops):

- **A commit lands:** the lane extends upward, the new dot grows in and HEAD pulses once. The
  spike implements the pulse ring.
- **A branch is created:** a new lane draws itself from its fork point up to its tip.
- **A branch moves** (reset, rebase, amend): replaced commits fade out, the new ones draw in, and
  lanes slide to their new columns.
- **A branch is deleted or merged:** its lane fades out. A merged lane first curves into trunk.
- **A checkout:** the amber highlight glides to the newly checked-out lane.

All of this needs **tweening between two `GraphLayout` row sets keyed by SHA**: old position to new
position, with fades for rows that appear or disappear. The layout is pure, so this is
straightforward to build and to test.

## 4. Energy

The goal is to cost about as much as a static wallpaper when nothing changes.

- **Draw only on change.** The `Canvas` sits in a `TimelineView` whose clock is **paused** unless a
  transition is running, so there are no timers and no display link while idle. SwiftUI re-renders
  only when the model publishes a different graph.
- **Cap the frame rate.** Transitions run at 30 fps (`TimelineView(.animation(minimumInterval:
  1/30))`). On ProMotion displays, use `CADisplayLink` with `preferredFrameRateRange` capped at 30.
- **Pause when hidden.** Pause on window occlusion (full-screen apps, covered desktop), screen
  sleep (`NSWorkspace.screensDidSleepNotification`), and session switch-out
  (`sessionDidResignActiveNotification`). While paused, coalesce changes and skip derives. On
  resume, run one derive and snap to the new state with no animation.
- **Throttle on battery.** On battery or in Low Power Mode (`IOPSNotificationCreateRunLoopSource`,
  `ProcessInfo.isLowPowerModeEnabled` with `NSProcessInfoPowerStateDidChange`), or under serious
  thermal state, skip animations, snap to the new state, and stretch the watcher latency to
  5–10 s.
- **Git costs more than drawing.** A derive spawns many short `git` processes. Watching refs only,
  gating on a fingerprint and debouncing (section 3) cut this the most.
- **Render cheaply.** Make glows from layered strokes and gradients, not full-screen blur filters.
  Rasterize the static scene once and composite only the animating parts on top.

**Measured on the spike** (debug build, 11-row graph, 1440×900 @2x):

- Idle: 0.0 % CPU and **2 idle wakeups in 20 s** (`top -stats cpu,idlew,power`), with 0.01 s of
  CPU over that window.
- Total CPU over the first ~70 s, including launch, 7 redraws and one pulse: 0.69 s.
- About 46–50 MB RSS.

**What to measure for real:**

- Activity Monitor's Energy Impact and 12-hour average.
- `top -stats pid,cpu,idlew,power` sampled over an idle hour.
- `sudo powermetrics --samplers tasks,gpu_power`, which needs Daniel's OK because it runs as root.
- Instruments' Time Profiler and Power Profiler.
- Count `git` spawns per hour, logged from the watcher.

Run three scenarios: an idle hour; a typical dev hour (commits plus builds in working trees); and a
30-commit rebase. Targets: under 0.1 % average CPU when idle, no GPU work when idle, and one
derive per settled change.

## 5. Reuse

**Carries over as is:**

- `Git/GitRunner`, the `GitRunning` protocol and `GitRunner.appEnvironment`
  (`GIT_OPTIONAL_LOCKS=0` matters even more for a resident process).
- `Execution/WorktreeExecutor` and its read coalescing.
- `Model/HistoryGraph`, `GraphSegment` and `CommitNode`.
- `Derive/GraphDerivation`, including lineage, trunk resolution and the revealed-lane machinery.
- `Reactive/DirectoryWatcher` (`FSEventsWatcher`).
- `GitrasilTestSupport` fixtures.
- **`Layout/GraphLayout`.** It was private to the app's `HistoryGraphView`. The spike moves it
  into Core (first commit) as `GraphLayout.rows(for:expanded:)`, which both the app and the
  wallpaper now use. The fork-target nudge became a sliver index instead of a pixel offset, so
  Core carries no view units. Two layout tests were added.

**Needs changes:**

- **A repo-centric derivation** (`repoGraph`): a trunk tail, branches picked by recency, worktree
  markers, and a per-lane commit cap. It should emit `HistoryGraph` so `GraphLayout` still applies.
- **The watch scope:** git dirs only, configurable latency, a settle debounce and a fingerprint
  gate. That means either parameterising `WorktreeStore` or adding a slim `RepoGraphStore` that
  skips status, mutations and the explorer.
- **`GraphRow`**, which mixes layout with app interaction fields (`isDropSource`,
  `isCherrySource`, `rebaseBranch`). Split it once the app's future is decided.
- **The `HistoryGraphView` canvas routines** (connectors, forks, dots, overlap slivers). They are
  the reference for the wallpaper renderer, but the look differs, so the wallpaper has its own
  renderer (`WallpaperView`).

**To drop** (if the worktree GUI goes away):

- SwiftTerm and the terminal. This also removes the dependency that currently breaks `swift build`
  on this machine (see below).
- `MutationsEngine` (rebase, drop, cherry-pick, undo) and `WorktreeLifecycle` (create/remove).
- `DiffDerivation`, `CommitDetailDerivation` and `WorkingTreeStatusDerivation`.
- The file tree and file viewer, the commit detail panel, the operation bar, the add-worktree
  sheet, the tabs, and the hover actions and selection in `HistoryGraphView`.

## What the spike showed

Test setup: run against a throwaway repo in the job's tmp dir, with `main` ahead, an intermediate
`feature/lanes`, the checked-out `feature/glow`, and `spike/pulse` off `feature/lanes`. The spike
ran for 150 s with `--quit-after`. Screenshots were taken of the spike's own window only
(`screencapture -l <id>`).

1. **Window level:** stacking matches section 1, between the wallpaper and the desktop icons, on
   the primary display.
2. **Reuse:** the graph came from `WorktreeStore` → `historyGraph` → `GraphLayout` with no
   changes to core logic. It drew main as a fork lane, the intermediate, the checked-out branch in
   amber and the revealed branch.
3. **Live updates:**
   - A commit on the checked-out branch redrew within about 0.2 s, and the HEAD pulse ring was
     visible mid-animation.
   - A new branch `exp/ripple` was auto-revealed and fanned out as a new lane.
   - An untracked file turned the tip into an open (dirty) circle.

Known gaps in the spike:

- It covers the main display only.
- The occlusion pause is wired up but untested, since opening full-screen apps on Daniel's machine
  was out of bounds.
- Hash-picked lane colours can collide: `feature/lanes` and `exp/ripple` both came out violet.
- The checked-out branch's name isn't labelled.
- There's no settle debounce, so transient states redraw.
- It still watches the working tree.

## Phase 2

### Decisions

- The worktree GUI is removed from the repo, along with SwiftTerm; it stays in git history.
- Repos are a list the user pins from a menu-bar item, saved between launches. There's no automatic
  ranking.
- The look is **ink on cream**, keeping a distinct colour per branch rather than all-sepia.
- Launch at login and setting a still image as the real wallpaper are still undecided. Neither is
  built.

### What was built

- **Repo-wide graph** (`Derivations.repoGraph`). The spine is the trunk's last 24 first-parent
  commits, using the local branch rather than `origin/…`. Lanes are up to 6 local branches: those
  checked out in a worktree first, then those committed in the last 30 days, newest first.
  - Lanes claim commits fewest-first, so a branch off a branch stacks onto it instead of drawing a
    second copy of the shared commits.
  - A branch with no commits of its own is a pill on its tip, if the tip is drawn.
  - It emits `HistoryGraph` (a `.trunk` spine segment and `checkedOutBranches`), so `GraphLayout` is
    unchanged apart from not treating a trunk spine as the current worktree.
  - It's read-only: unlike `historyGraph`, it never backfills lineage refs.
- **`RepoGraphStore`.**
  - It watches only the repo's common git dir, and only ref paths in it: `HEAD`, `packed-refs`,
    `refs/…` and worktree `HEAD`s (a path filter on `FSEventsWatcher`). Edits, builds, index writes
    and objects never wake it.
  - Every ref event restarts a 1 s settle timer, so a checkout, commit, checkout burst is one derive.
  - A one-spawn ref fingerprint (`for-each-ref`) skips the derive when nothing moved, and the graph
    only publishes when it changed.
  - It pauses while the window is covered and catches up once on resume.
- **Pinned repositories** (`PinnedRepositories`, in Core).
  - Adding a folder validates it with git and pins the top of its working tree.
  - A second folder of an already-pinned repository is refused: a subfolder, a symlinked path, or
    another worktree all count, matched by the common git dir.
  - The list is saved in the `com.gitrasil.background` defaults. `GITRASIL_BACKGROUND_DEFAULTS_SUITE`
    names another suite for test runs.
- **Menu-bar item** (`arrow.triangle.branch`).
  - It lists the pins, each with Reveal in Finder and Remove. A pin is badged *missing* if its
    folder is gone, and *not shown* past the fourth.
  - "Add Repository…" opens a panel and alerts when a folder can't be pinned. Quit is the last item.
- **Side-by-side panes.** The first four pins share the screen, and their stores start and stop as
  pins change. With nothing pinned, the background shows a one-line hint.
- **The look is a value** (`WallpaperStyle`). The drawing code reads only the style: paper, inks,
  stroke widths, wobble, dot size, fade and fonts. Ink on cream is the style in use:
  - Thin pen lines that wander slightly. The wander is seeded from position, so a redraw draws the
    same line.
  - Warm paper with faint fibres, which turns to charcoal in dark mode.
  - The trunk is in plain ink, and each branch has its own ink. (Round 3 changed this from
    distinct within a repo to one ink per branch name everywhere; see below.)
  - Commits fade with age, halving every 14 days down to a floor.
  - Branch names are in a hand (Bradley Hand), subjects in Baskerville italic, and the repo name is
    a Snell Roundhand watermark.
  - A checked-out branch's tip gets a ring.
  - The tips that moved get a pulse ring after a change.

  Night transit is kept as a second `WallpaperStyle`, to show that a look is one value.
  `GITRASIL_BACKGROUND_APPEARANCE=light|dark` previews either mode without touching the system
  setting.
- **Removed.** The worktree-relative store layer is gone: `WorktreeStore`, the worktree snapshot,
  `StatusBadge` and `isBehind`. `historyGraph` and lineage stay, because `GraphLayout` still lays out
  worktree-relative graphs and its tests derive them.

### What the phase 2 run showed

The test setup:
- Two throwaway repos in the job's tmp dir: the phase 1 demo repo, and `atlas`, whose commits span
  60 days.
- They were pinned in a throwaway defaults suite, which was deleted afterwards.
- Screenshots were of the background's own window only.

Results:
- **Stacking.** The window is at the desktop level, above the Dock's wallpaper window and below
  Finder's icon window.
- **Status item.** It exists and is visible: AppKit put it on the external display's menu bar. On
  this macOS its window isn't in `CGWindowList`.
- **Idle.** Over 60 s with no changes: 0.0% CPU in `top`, 0.01 s of CPU time in total, about 57 MB
  RSS.
- **Working tree.** An untracked file and a `git add` caused no derive and no redraw.
- **Burst.** A checkout, commit, checkout burst gave exactly one derive and one redraw, about 1 s
  after the burst ended. The moved tip pulsed.
- **The look.** Branch inks were distinct in both repos, atlas's older commits faded toward the
  floor, and checked-out tips were ringed. Dark mode was previewed with the env override.

Not covered:
- **Menu.** It hasn't been click-tested (no UI automation here). Adding, removing and saving pins
  are covered by unit tests, and the panes follow `pins.urls`.
- **Displays.** The background covered the main display only (fixed in round 3).
- **Occlusion.** The pause is unit-tested in the store but wasn't observed with a real full-screen
  app.

## Round 3

### The pinning bug: an inherited `GIT_DIR`

Daniel pinned a repo in `~/repos` and saw `gitrasil-sandbox`. A second pin was then refused as
"already pinned, as ~/gitrasil-sandbox".

- **Cause.** Daniel's running background had inherited `GIT_DIR=~/gitrasil-sandbox/.git` and
  `GIT_WORK_TREE=~/gitrasil-sandbox`, along with `GIT_EXTERNAL_DIFF=git-difftool--helper`,
  `GIT_PREFIX` and `GIT_DIFF_PATH_COUNTER`. That's the environment `git difftool` gives the tool it
  launches.
- **Where they came from.** The variables sit in the VS Code app process itself (running since
  2026-09-13), so VS Code was first launched *by* `git difftool` in the sandbox, with `code` as the
  diff tool. Every integrated terminal it has opened since inherits them. git obeys
  `GIT_DIR`/`GIT_WORK_TREE` over the working directory, so every git call resolved to the sandbox.
  It wasn't the shell profile, git config, launchd or `run-wallpaper.sh`.
- **Fix on the machine (not applied).** Quit VS Code completely (⌘Q) and reopen it from the Dock or
  Spotlight. Or run `unset GIT_DIR GIT_WORK_TREE GIT_PREFIX GIT_EXTERNAL_DIFF` in a terminal before
  launching. Until then, *any* git command in those terminals acts on the sandbox. Remove the stray
  `gitrasil-sandbox` pin from the menu.
- **Fix in the app.** `GitRunner` now drops git's repository-selecting variables
  (`git rev-parse --local-env-vars`) before every git launch, so the working directory always
  decides. A regression test sets `GIT_DIR`/`GIT_WORK_TREE` to another repo and pins two repos.

### Displays and inks

- **Displays.** Every display gets its own window (`DesktopWindows`), all showing the same pins.
  Windows follow displays being added, removed or resized, and the stores pause only when every
  window is covered. Verified on two displays (built-in and a 3440×1440 external). Hot-plugging
  wasn't exercised.
- **Inks.** A branch's ink now comes from a stable hash of its name alone, so the same name has the
  same ink in every repo, and the trunk stays plain ink. The trade-off: with 8 inks, two branches in
  one repo can share one (in the test repos, `exp/ripple` and `spike/pulse` did).

## Open questions for Daniel

- Is it OK to also set a still image as the real wallpaper, for Mission Control and the lock
  screen? That one changes his wallpaper setting. (Later.)
- Should it launch at login (`SMAppService`) once it's real? That also needs a bundled `.app`.
  (Later.)
- Should the worktree-relative `historyGraph` and the layout cases only it uses go too? (Later.)
