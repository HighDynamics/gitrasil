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
8. [ ] SendMessage to Arbor with summary.

## Status log

- 2026-10-05: branch created, reading done, plan written.
- 2026-10-05: steps 3–7 done. Layout extracted to Core (61ec996). Spike built and run against a
  temp repo: the window stacks between the wallpaper and the icons; a commit, a new branch and a
  dirty tree each redrew live; idle cost 0.0% CPU and 2 wakeups in 20 s. DESIGN.md written. Plain
  `swift build` fails on the missing Metal Toolchain (SwiftTerm); with `--build-system native`,
  build and tests pass.
