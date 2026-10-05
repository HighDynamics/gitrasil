# Live background spike — plan

Task (from Arbor): research how to turn Gitrasil's branch-graph work into a live macOS desktop
background, write a design note, and prove the core with a spike. Report back to Arbor via
SendMessage (`to: "Arbor"`).

Branch `spike/live-background`, cut from `origin/main` (a35509c). Local `main` is stale (6737293);
`origin/main` is the merged PR #5. Not based on `feature/external-diff-handoff`.

## Constraints

- No push, no PR, no force-push. Commit with the `/commit` skill.
- Don't touch other worktrees/branches or the main checkout.
- Nothing system-wide: no login item, no launch agent, no wallpaper or settings change. Running the
  spike briefly (a window at desktop level, then killed) is fine; test against a throwaway repo in
  the job tmp dir, not `~/gitrasil-sandbox`.

## Findings so far

- The lane layout (`Row.build`) is `private` inside `Sources/GitrasilApp/HistoryGraphView.swift`.
  A separate executable can't reach it, so reuse means moving it into `GitrasilCore`.
- The graph is **cw-relative** (meeting commit, cw spine, trunk-ahead fork, revealed lanes). On a
  repo sitting on trunk the graph is just the meeting commit — a wallpaper needs revealed branches
  (or a new repo-centric derivation) to have anything to draw.
- `WorktreeStore` is `@Observable`, watches the worktree dir + git dirs via FSEvents, and re-derives
  through the coalescing executor. It republishes on every FSEvents tick even when nothing changed,
  and it watches the working tree (noisy: build output, editor saves).

## Steps

1. [x] Read README, HistoryGraphView, Core (Derive/, Reactive/), roadmap memory.
2. [x] Write this plan.
3. [x] Extract the row/lane layout into `GitrasilCore/Layout/GraphLayout.swift` as public
       `GraphRow` / `GraphLayout.rows(for:expanded:)`; `HistoryGraphView` uses it unchanged in
       behaviour. The pixel fork nudge becomes a sliver index. Add a small layout test. Commit.
4. [x] Spike: new executable target `GitrasilWallpaper`.
   - Borderless `NSWindow` at desktop level (`CGWindowLevelForKey(.desktopWindow)`), below the
     icons, `.canJoinAllSpaces` + `.stationary` + `.ignoresCycle`, ignores mouse, main display only.
   - `.accessory` activation policy (no Dock icon).
   - A `WorktreeStore` on one repo (CLI arg). Auto-reveal the repo's other local branches (cap) so
     there's something to draw; new branches get revealed on the next snapshot.
   - Publish to the view only when `snapshot.graph` actually changes (log each redraw to stdout).
   - Canvas drawing from `GraphLayout` rows: dark gradient, soft lanes, a pulse ring on HEAD when
     it moves (animated via a paused-when-idle TimelineView, 30 fps cap).
   - Pause when the window is occluded (`occlusionState`).
   - `scripts/run-wallpaper.sh` builds and runs it as a bare executable (no bundle needed).
5. [x] Run it against a temp repo; commit/branch in that repo and confirm redraws (stdout log +
       CGWindowList check of level/onscreen; screenshot if permitted). Measure idle CPU. Kill it.
6. [x] Write `docs/live-background/DESIGN.md` (display options, visuals, live updates, energy, reuse).
7. [x] `swift build` + `swift test` on final commit. Commit spike + docs.
8. [x] SendMessage to Arbor with summary (sent 2026-10-05).

## Status log

- 2026-10-05: branch created, reading done, plan written.
- 2026-10-05: steps 3–7 done. Layout extracted to Core (61ec996). Spike built and run against a
  temp repo: the window stacks between the wallpaper and the icons; a commit, a new branch and a
  dirty tree each redrew live; idle cost 0.0% CPU and 2 wakeups in 20 s. DESIGN.md written. Plain
  `swift build` fails on the missing Metal Toolchain (SwiftTerm); with `--build-system native`,
  build and tests pass.

## Phase 2: from spike to a usable background (Arbor, 2026-10-05)

Daniel's decisions:

- Remove the worktree GUI; it stays in git history. Drop SwiftTerm.
- Repos are a list the user pins from a menu-bar UI, saved between launches.
- The look is still undecided. Night transit stays as a placeholder, and the drawing must be easy
  to restyle. *Later the same day:* Daniel picked **ink on cream**, keeping a distinct colour per
  branch/worktree, so that replaced night transit within this phase.
- Don't build launch at login or setting a still image as the wallpaper.

Reply to Arbor at `uds:/tmp/cc-socks/18016.sock` with SendMessage. Same constraints as phase 1: no
push or PR, no login item, no changes to the wallpaper or system settings.

### Steps

1. [x] Update this plan.
2. [x] **Remove the GUI** (its own commit). This covers:
       - the `GitrasilApp` target and its sources;
       - SwiftTerm and `Package.resolved`;
       - `scripts/run.sh` and the README's GUI sections;
       - Core code only the GUI used, with its tests: `RepositoryStore`, worktree add/remove,
         rebase/drop/cherry-pick/undo, commit detail, diffs, working-tree status and the explorer,
         `WorktreeStore`'s GUI-only methods, and `GraphRow`'s interaction fields.

       Lineage is still used by the worktree-relative graph, so it moves out of `Mutations` into
       `Derive/Lineage.swift`. With SwiftTerm gone there are no Metal shaders, so plain
       `swift build` and `swift test` should pass.
3. [x] **Repo-wide graph** (`Derivations.repoGraph`):
       - The spine is the trunk, preferring the local branch over `origin/…`, with its last N
         first-parent commits.
       - Lanes are recently active local branches (`for-each-ref --sort=-committerdate`, with a max
         age and a cap). Lanes claim commits fewest-first, so a branch off a branch stacks onto
         it. (Built that way rather than oldest tip first, which misorders a base that got a later
         commit.)
       - A branch with no unique commits becomes a ref pill, but only if its tip is drawn.
       - Branches checked out in any worktree are flagged (`%(worktreepath)`).
       - It emits `HistoryGraph` (a new `.trunk` segment kind plus `checkedOutBranches`), so
         `GraphLayout` still applies.
       - It is read-only: no lineage backfill, because that writes refs.
       - Tests run on fixture repos.
4. [x] **`RepoGraphStore`**:
       - Watch only the repo's common git dir, filtered to ref paths (`HEAD`, `packed-refs`,
         `refs/…`, `worktrees/*/HEAD`).
       - Wait for changes to settle (default 1 s of quiet) before deriving.
       - Skip the derive when a cheap ref fingerprint hasn't changed.
       - Publish only when the graph changed, and allow pausing.
       - Test that a checkout/commit/checkout burst produces one derive.

       Switch the background to the new store. Then, in their own commit, drop the worktree-relative
       code that is no longer used: `WorktreeStore`, the snapshot, `historyGraph` and lineage.
       (Built: `WorktreeStore`, the snapshot, `StatusBadge` and `isBehind` were dropped.
       `historyGraph` and lineage stay, because `GraphLayout`'s worktree-relative cases and its
       tests still use them. That's an open question for Daniel in DESIGN.md.)
5. [x] **Pinned repos**:
       - `PinnedRepositories` lives in Core. It validates with `git rev-parse --show-toplevel`,
         removes duplicates, and persists to `UserDefaults`. Tests use a throwaway suite.
       - A menu-bar status item lists the pinned repos (each with Reveal in Finder and Remove), plus
         "Add Repository…" (an open panel) and Quit.
       - The background shows the pinned repos side by side (up to 4) and reconciles its stores as
         the list changes. It shows a hint when nothing is pinned.
       - The repo path argument goes away.
       - Colours, strokes and fonts live in a `WallpaperStyle` value, so restyling is easy.

       (Built. The tests use an in-memory `PinStorage` rather than a throwaway suite, because real
       suites left empty plists in `~/Library/Preferences`. The style in use is ink on cream, and
       night transit is kept as a second value.)
6. [x] **Checks**:
       - Plain `swift build` and `swift test` on the final commit.
       - Run against a throwaway repo, using a throwaway defaults suite (an env override). Check the
         window level, the status item, that a burst gives one redraw, and the idle cost. Delete
         the throwaway suite afterwards.
       - Update DESIGN.md and the README. Commit.
7. [ ] SendMessage results to Arbor.
