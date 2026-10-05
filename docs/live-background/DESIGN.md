# Gitrasil as a live desktop background — design note

Status: spike (`spike/live-background`). The spike is the `GitrasilWallpaper` target, run with
`scripts/run-wallpaper.sh /path/to/repo`.

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

## Build note

Plain `swift build` / `swift test` fail on this machine (Xcode 27) for a reason unrelated to this
branch, which doesn't touch SwiftTerm or `Package.resolved`. SwiftTerm 1.20's `Shaders.metal` needs
the Metal Toolchain, which isn't installed (`xcodebuild
-downloadComponent MetalToolchain` would fix it, but that's a system-wide install). The old build
system skips Metal: `swift build --build-system native` and `swift test --build-system native`
both pass. The wallpaper product doesn't depend on SwiftTerm, so `swift build --product
GitrasilWallpaper` works with the default build system.

## Open questions for Daniel

- Which visual direction: night transit, ink on cream, or constellation?
- Which repos: automatic (the most active in `~/repos`) or a pinned list?
- Is it OK to also set a still image as the real wallpaper, for Mission Control and the lock
  screen? That one changes his wallpaper setting.
- Should it launch at login (`SMAppService`) once it's real?
- Should the worktree GUI code (SwiftTerm, mutations, explorer) be stripped from this repo, or
  should the wallpaper live alongside it?
