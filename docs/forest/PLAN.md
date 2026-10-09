# Forest — how many trees can we fit on screen?

Task (from Arbor, for Daniel): "what it takes to put **far more trees** on the screen, and push the
limit of spacing to see what we can do". An exploration: measure the limits, prototype layouts, bring
back renders, numbers and a recommendation. **Nothing ships from this round**: every prototype is
opt-in, the defaults Daniel sees are untouched. Branch `spike/forest`, cut from `origin/main`
(5f8b515). Round 1 is below; **round 2** (what shipped, on Daniel's answers) is at the end.

## Questions

1. Where are the limits now, and what breaks first as N grows?
2. How far does plain scaling (the orchard with the cap lifted) go, at N = 4…64 on three displays?
3. Which layouts pack more in, and what does each cost?
4. What would it take to ship the best one?

## Method

- **Fixtures.** `scripts/forest-fixtures.py` writes N synthetic repositories (varied histories: trunk
  4–600 commits, last commit an hour to a year old, 0–16 branches, sub-branches, buds, a few
  worktrees) into eight uneven group folders (`apps` 14 … `archive` 3), via `git fast-import`. A folder
  pin on the root finds them two levels down. A second fixture set is Daniel's real repos under
  `~/repos`, read-only (19 repos).
- **Pinned in a throwaway defaults suite** (`GITRASIL_BACKGROUND_DEFAULTS_SUITE=gitrasil-forest`), deleted
  afterwards. The app is only ever launched with `--quit-after` or as an offscreen aid; nothing is run
  from the main checkout, and `com.gitrasil.background` is never touched.
- **Displays.** 1440×900@2x, 3440×1440@1x (both already in `Offscreen`) and 5120×2880 which I take to
  be a 5K panel: 2560×1440 pt @2x.
- **Cap lifted** by `GITRASIL_BACKGROUND_MAX_PANES` (default 4, so nothing changes), the layout picked by
  `GITRASIL_BACKGROUND_FOREST` (default off, the current orchard).
- **Metrics** (new offscreen aid): per N, display and layout: tree scale in px, leaf and label sizes,
  banners asked for vs placed, crown overlap, clipping, planning time. **Perf**: `--benchmark` (redraw,
  grow-in frame, paper, banners), release build, two runs each, against a release build of
  `origin/main`; launch CPU time and git spawns for N repos; idle CPU with N repos watched; RSS; a gust
  with N×banners.
- **Renders** go to `renders/` (excluded in `.git/info/exclude`, never committed): a contact sheet per N and
  display with the layouts side by side, plus full-size hero shots.

## Prototype layouts (all opt-in, `GITRASIL_BACKGROUND_FOREST=…`)

| value | idea |
|---|---|
| `plain` | the current orchard with the cap lifted (the baseline for question 2) |
| `canopy` | spacing by each tree's actual crown width, not equal slots, crowns allowed to interleave |
| `rows` | depth rows: several ground lines, back rows smaller and paler, front rows the most recently active |
| `activity` | size by activity: busy repos tall, quiet ones saplings, packed by width on one ground |
| `groves` | clustered by folder: tight inside a folder, a gap between folders, the folder named under its grove |

Plus **name rules** shared by all of them: tiers by tree size (full pennants → only the trunk and
checked-out names → plate only → smaller plate → none), and plates fitted to their slot.

## Results

Everything below is measured on this branch with release builds, chalk, light, orchard, two runs each
(medians of 7 redraws per run, averaged over the two runs). Raw numbers: `renders/sweep/metrics.csv`
(layout), `renders/perf/` (timings, launches, gusts); neither is committed. `px/unit` is the front tree's
height (a full-grown trunk is 1 unit), so it is how big the tree is drawn.

### Q1. Limits today, and what breaks first

| limit | value | where |
|---|---|---|
| folder pin cap | 4 panes | `BackgroundModel.maxPanes` (now `GITRASIL_BACKGROUND_MAX_PANES`, default still 4) |
| orchard spacing | equal plots, `shared = min(tall/1.45, plot/1.3)` | `Landscape.orchard` |
| orchard plot width | 1.3 units, though real crowns are ~0.5–0.9 | the reason plain wastes room |
| plate | fixed-size font under each tree | `TreeDrawing` |
| banners | placed round every crown rect; a name with no free spot is dropped | `BannerLayout.place` |

What breaks first as N grows, plain orchard, 1440×900@2x:

1. **Tree size**, at once: 277 px/unit at N=4, 138 at 8, 69 at 16, 35 at 32, 17 at 64. Leaves are a fixed
   size, so past ~N=16 a tree is a stick with big leaves.
2. **Plates** (fixed font): overlapping from N=12 (2 of 12), 13 of 16, all of 32.
3. **Pennants**: dropped for lack of a free spot: 47/59 asked for at 8, 52/111 at 16, 49/189 at 32.
4. Layout and redraw cost follow later: nothing in layout is slow (plan 1–11 ms for plain), redraw is
   linear in trees.

Cost per tree, any layout: **~1.9 ms to redraw** (CPU, `ImageRenderer`), **~1.2 ms** per grow-in frame.

| N | redraw ms (plain, 1440) | grow-in frame ms | launch CPU s | RSS MB | git spawns |
|---|---|---|---|---|---|
| 4 (main) | 15 | 11 | 2.4 | 77 | 53 |
| 4 (this branch) | 13 | 9 | | | |
| 8 | 23 | 17 | | | |
| 16 | 40 | 26 | 7.2 | 113 | 207 |
| 32 | 75 | 44 | | | |
| 64 | 120 | 75 | 22.8 | 219 | 780 |

Startup is ~12 git processes per repository, with no global concurrency limit: all 64 trees were on screen
~4 s after launch (16: ~1.5 s), with a CPU cost of ~0.36 s a repo, spent once. **Idle CPU is zero for every N**:
the 20 s and 60 s runs differ by under 0.05 s of CPU at 16 and 64 repos (one FSEvents stream each, no polling).

### Q2. How far plain scaling goes (cap lifted, orchard unchanged)

Front tree px/unit; "noise" = plates overlap and/or fewer than a third of the pennants fit.

| N | 1440×900@2x | 3440×1440@1x | 5120×2880@2x (2560×1440 pt) |
|---|---|---|---|
| 4 | 277 | 662 | 492 |
| 8 | 138 | 331 | 246 |
| 12 | 92 | 220 | 164 |
| 16 | 69 | 165 | 123 |
| 24 | 46 | 110 | 82 |
| 32 | 35 | 83 | 62 |
| 48 | 23 | 55 | 41 |
| 64 | 17 | 41 | 31 |

It turns to noise at **N≈12 on 1440×900, ≈24 on 3440×1440 and 5K**: plates start to collide there (2 of 12,
2 of 24 and 9 of 24 respectively), then pennants vanish (over half dropped from 16 on the laptop, 32 on the
ultrawide), then the trees are < 70 px tall. At N=64 even the ultrawide has 41 px trees, with 61 overlapping plates.

### Q3. Layouts

Front tree px/unit (the smallest, at the back, in brackets), pennants placed/asked, 1440×900@2x:

| N | plain | canopy | rows | activity | groves |
|---|---|---|---|---|---|
| 8 | 138 | 368 | 368 (1 line) | 378 (295) | 214 |
| 16 | 69 | 207 | 381 (305), 2 lines | 216 (169) | 137 (118), 2 lines |
| 32 | 35 | 106 | 326 (209), 3 lines | 118 (49) | 114 (98) |
| 48 | 23 | | 307 (157), 4 lines | | |
| 64 | 17 | 53 | 339 (139), 5 lines | 50 (27) | 84 (62), 3 lines |

3440×1440@1x, rows: 4→806, 8→760 (1 line), 12→679, 16→512 (1), 24→661 (2), 32→472 (2), 48→548 (3), 64→594
(4 lines, min 304). 5120×2880@2x, rows: 4→806, 12→501, 16→695 (2 lines), 24→488 (2), 32→595 (3), 48→559 (4),
64→619 (5 lines, min 253).

- **canopy** (by crown width): 2.7× bigger than plain at N=8, but still shrinks ∝ 1/N: 53 px/unit at 64.
  Best "one line" answer, but one line caps out around N=16.
- **rows**: the winner. Depth is the one resource the screen has plenty of: a geometric stack of 5 lines costs
  only ~1.5 trunk heights, so the front line stays 310–620 px/unit all the way to N=64 on all three
  displays while 5 lines of fading trees stand behind it. Only the front line gets plates and pennants
  (back lines are for texture), which is why only 8–13 names show at N=64.
- **activity** (size by use): readable to N=16, but quiet repos become 27–50 px saplings by N=64 and the
  answer to "what is that tree?" is gone. A good *modifier* for rows (see below), a poor layout alone.
- **groves** (by folder): folder structure is legible (caption + bracket) but each grove packs tighter than
  the whole forest could: 84 px/unit at N=64. Worth keeping as an *ordering* for rows (neighbours = same
  folder) rather than as a layout.
- **name rules**: pennants by size (all ≥210 px/unit, three at ≥140, none below) keep the pennant count
  bounded (~100–170 on screen at N=64 vs 332 asked for) and drop all overlap; plates are fitted across,
  rotated down the ground, or dropped; none are dropped or overlapping in rows at any N.

Max comfortable N (front trees ≥ 300 px/unit, no plate or pennant collisions, back lines readable as forest):

| display | plain | canopy | rows | activity | groves |
|---|---|---|---|---|---|
| 1440×900@2x | 8 | 12 | **32** (48 busy, still legible as a forest) | 12 | 12 |
| 3440×1440@1x | 12 | 16 | **48** | 16 | 16 |
| 5120×2880@2x | 12 | 16 | **64** | 16 | 16 |

Cost per frame (CPU, `ImageRenderer`; the live app draws on the GPU-backed canvas, and these are the
ratios that matter): rows costs the same as plain per tree, 120–133 ms at N=64 across the three
displays (vs 15 ms for the 4-tree orchard today), and **banner layers 60–70 ms at N=64** (vs 22–40 for
plain) because the front-line pennants at larger scale cost more: they are drawn once into layers.
Layout is trivial, 1–5 ms, and the banner plan is the expensive part of planning (35 ms at N=64 rows, 12
at N=32; paid on a change, not per frame).

Real repos (18 of Daniel's under `~/repos`; many are one-commit starters, several carry a dozen linked
worktrees as branches): `renders/real/sheet-n18-*.jpg`. Plain at 18 is 62 px/unit with all plates colliding;
canopy and rows are one line at 343 px/unit; groves is 3 lines of 482.

### Idle and gusts

| | startup CPU | idle CPU | gust CPU (7 s) |
|---|---|---|---|
| N=4, main | 2.4 s | 0 | ~0.85 s per gust (12% of a core while blowing) |
| N=16 rows | 7.2 s | 0 | ~1.3 s per gust |
| N=64 rows | 22.8 s | 0 | ~0.7 s per gust (the back lines carry no pennants) |

A gust comes every ~45 s and only on mains power, so gusts average 1–3% of a core. They only turn the
banner layers: the trees are not redrawn. At N=64 the grow-in is 75 ms a frame in this measure, so it is
not a 30 fps animation unless trees are cached (below).

### Q4. What it takes to ship rows

**Code.** `ForestLayout.rows` (core; ~150 lines of the 440 here), tests (13 in `ForestLayoutTests`), the
`Landscape` branch (`orchardPlanted`) and the faded style, the pennant allowance in `BannerLayout`, the
ground lines and plate rule. Cleanup: drop the other modes (or keep `canopy` as the small-N path), remove the
study aid `OffscreenForest`, lift the pane cap by a setting, and give `heightShare` a default.

**Perf budget.** Idle stays at 0 (nothing polls). To keep grow-in smooth beyond ~N=16: draw each tree once
into its own image layer and move/scale it in the grow-in (the grow-in is per tree already), instead of
redrawing the whole scene per frame; stagger the trees' grow-in over the first few seconds; and limit how many
repos are read at once (a concurrency of ~4–6 git readers would hold the 22 s of startup CPU off the first
second of the machine's boot). Memory grows ~2.4 MB per repo (77 → 219 MB at 64): fine.

**Settings.** One: *Forest* off/on, or a pane limit, with the layout chosen by N (1 line to 12, then rows).
`Spacing` should not be a user-facing choice. Pin cap becomes a user setting (default 4 stays until then).

**Risks.**
- **Stability.** `rows` ranks by the day of each repo's last commit, so a commit moves its tree and every
  tree it passes, and re-packs every line it crosses (`testACommitInRowsRepacksOnlyTheLinesItCrosses`:
  in that test one commit moves 39 of 40 placements, by up to ~25 px for untouched lines because the scale
  is shared). That is acceptable at launch and re-rank-daily; it is not acceptable live. Ship it ranking once at
  launch (and at midnight), with the order held in between.
- **Names.** Only the front line is named, so at N=64 only ~8–13 repos show a name; the rest is atmosphere.
  Hover/click for a name is needed, or a search.
- **Grow-in** at N≥32 (above), **startup** CPU at N=64 (22 s, once).
- **Scale of the front line depends on the widest crowns**, so one wide tree can shrink the whole forest;
  spans are quantized to 0.05 units to limit it.

### Decisions for Daniel

1. **Ship `rows`?** Recommend yes, off by default, opt-in as "Forest", cap lifted to 32 (1440), 48 (ultrawide), 64 (5K).
2. **Rank rule.** Recommend: front = most recently active at launch and midnight, not live (no flicker).
3. **Names.** Recommend front line plates + pennants for the front 8–12 only, and a hover name for the rest.
4. **Groves as an order.** Recommend: sort within a line by folder, don't draw captions.
5. **Cap.** Recommend 12 by default for the plain orchard (where it still looks like today's), not the 4.

---

# Round 2 — shipping the Forest

Daniel's answers to the round-1 decisions: ship rows, opt-in as **Forest**; trees are sorted at launch and
at midnight, not live, and regrow when their place changes; names on the front line only (the main tree and the
forest's front line), no hover names; folders only order trees within a line, no captions; the plain layout's
cap goes from 4 to 12. The brief for this round added: the most repos on the single "Yggdrasil" tree, overflow
into a depth-rows forest behind it, idle CPU still 0, grow-in smooth at the new limits.

## What it does

- **Forest off (the default).** At most **12** repositories (`ForestPolicy.plainLimit`, was 4), in either
  arrangement: the orchard in equal plots, or one tree. Nothing else changes.
- **Forest on** (menu: Arrange As → Forest, saved as `forest`). Up to **64** repositories
  (`ForestPolicy.paneLimit`). Settings changes read the new repositories, then the whole scene grows again.
- **Single tree.** It keeps the most recently active repositories, **12** on a display 900 pt tall, **20** on
  1440 pt and taller (`ForestPolicy.treeCapacity`, clamped 8…24). The rest stand in a **depth-rows forest on
  both sides of the tree**: the tree is narrowed to 0.66 of the screen's width, the gap between the two halves
  is its crown width × 0.8, and the forest takes 0.58 of the screen's height, back lines smaller and paler (min fade 0.42).
  The tree's names stay clear of the forest; only the forest's front line has plates, the lines behind are
  texture. A bough with no ribbon room gets its name on the trunk pennant ("repo · main") instead of losing it.
- **Orchard.** Equal plots to 12; beyond that, the same rows as the forest across the whole width.
- **Order.** `ForestPolicy.rank`: last commit by UTC day (so a commit today doesn't outrank one an hour older),
  then the repository's id. Within a line, trees stand by folder, then name; the folder is never drawn.
- **When the order is taken.** At launch (every whole-scene grow-in: arrangement change, Forest toggle, Reshuffle,
  Watch Gitrasil Grow) and at the first hourly tick after local midnight. A commit in between grows its limb but
  moves no tree. A repository pinned later ranks on its own history until the next re-sort.
- **Regrow.** When the midnight re-sort changes the order, or the arrangement or Forest changes, **the whole
  scene grows again from the ground**, not only the trees that moved. Why: the ranking decides which tree is on the
  tree, which forest line a tree is on and each line's packing and shared scale, so a rank change moves nearly
  every tree (in the test, one commit moved 39 of 40 placements); regrowing a subset would still leave most of the
  scene moving, and a whole-scene grow-in is the one animation that already exists and is smooth. The midnight
  grow-in only happens when the order actually changed (compared as an order, not as dates), so most midnights are silent.
- **Menu.** The "N in the Forest" list from the first cut is gone (names on the front line only, no hover names:
  the wallpaper window takes no pointer).

Overrides for testing, never saved: `GITRASIL_BACKGROUND_FOREST=off|auto|rows`, `GITRASIL_BACKGROUND_MAX_PANES`,
`GITRASIL_FOREST_PLAIN`, `GITRASIL_TREE_CAPACITY`, `GITRASIL_FOREST_BESIDE`, `GITRASIL_FOREST_HEIGHT`,
`GITRASIL_GIT_READERS`, `GITRASIL_BACKGROUND_FRAMELOG=1` (draw tallies per second).

**Dropped modes:** `canopy`, `activity`, `groves` and the `plain` lift (code and the study aid's options), leaving
`ForestMode` = auto / off / rows (`rows` = forced, for the study aid).

## The limit, per display (single tree, Forest on)

Tree px/unit is the main tree's height (full-grown trunk = 1 unit); forest px/unit its front line. Chalk, light.

| display | on the tree | N=16 | N=32 | N=64 |
|---|---|---|---|---|
| 1440×900@2x | **12** | 12+4, tree 405, forest 280 (1 line) | 12+20, 405 / 187 (2) | 12+52, 446 / 200 (5) |
| 3440×1440@1x | **20** | all on the tree, 644 | 20+12, 653 / 468 (1) | 20+44, 653 / 452 (3) |
| 5120×2880@2x (2560×1440 pt) | **20** | all on the tree, 644 | 20+12, 653 / 392 (1) | 20+44, 653 / 383 (4) |

Why 12 and 20: they are where the ribbons start to run out of room (a bough without one names itself on the
trunk pennant): 1 of 12 on the laptop, 4 of 20 on the ultrawide and 5K. Below its limit the tree takes everything,
so a dozen repositories never see a forest.

## Performance (release, this machine)

**Launch** (real app, 60 s, two runs each, folder of 64 synthetic repositories):

| | CPU s (user+sys) | peak RSS MB | git processes |
|---|---|---|---|
| main, 4 repos | 1.8 | 69 | 53 |
| Forest off, 12 | 4.5 | 83 | 159 |
| Forest on, 16 | 5.8 | 90 | 207 |
| Forest on, 64 | 18.9 | 142 | 780 |

Round 1 measured 22.8 s and 219 MB for 64: `GitGate` now allows five `git` processes at a time
(`GITRASIL_GIT_READERS`), which spreads the same work out and holds memory down.

**Idle: 0.** At 64 repositories the process's CPU time did not move over 30 s after the grow-in (6.23 s at 25 s and
at 55 s). Nothing polls; the timeline is paused unless something grows.

**Grow-in at 64 (live, `GITRASIL_BACKGROUND_FRAMELOG=1`).** Before round 2's layers, one 64-repo grow-in was
69 ms a frame (10 fps). Now:

- Every forest tree is its own cached layer (`ForestTreeLayer`, Equatable), and the main tree is its own
  (`MainTreeLayer`): a frame redraws only what changed. A finished forest tree is never redrawn until the
  scene changes, and the main tree's canvas stops redrawing when its own boughs finish.
- A dozen trees grow in together; the rest follow in a wave from one second later, one every 0.12 s (at most
  4 s in all), in ranking order, so about 18 forest trees grow at once, not 52. The forest's layers advance at
  15 frames a second (invisible at that size), the tree at 30.
- Measured busy time per second of wall clock (main thread): peak 530 ms during the 2 s the tree grows
  (a 20-bough tree is ~20 ms a frame, which is also why it runs at ~20 fps then); the wave afterwards costs
  190–300 ms a second for ~4 s; before it was ~1,100 layer draws a second, now ~300–470.
  So the grow-in at 64 is about 6 s of 20–50% of one core, then 0.
- Redraw of the whole scene offscreen (`ImageRenderer`; slower than the live GPU canvas): 126 ms at 64 on the
  laptop, 29 ms at 12, 15 ms for today's 4-tree orchard. Plan (banners) 23 ms at 64, paid on a change only.
- Gusts only turn the banner layers, as before (round 1: 0.7–1.3 s CPU per 7 s gust, a gust every ~45 s on mains
  power). Not re-measured; the forest has no pennants behind the front line.

## Decisions for Daniel

1. **Limits and the cap of 64.** Recommend keeping 12 on the tree for 900 pt displays, 20 from 1440 pt, and 64 in
   all with Forest on. 64 costs ~19 s of CPU once at launch and ~130 MB.
2. **Midnight timing.** The re-sort happens on the first hourly tick after midnight, so up to an hour late, and
   only if the display is on. Recommend leaving it; an exact timer would add a wakeup to an app whose idle CPU is 0.
3. **Day-level ranking.** Two repositories committed to on the same UTC day are ordered by name, not time. Recommend it
   (it keeps a commit from moving trees all day); the other choice is ranking by the minute and re-sorting
   less often.
4. **Whole-scene regrow** on a changed order (above). Recommend it; the alternative (only the moved trees) leaves
   most trees moving anyway.
5. **Forest on turns the cap from 12 to 64 for everything** (folders too): a folder with 60 repositories shows all 60.
   Recommend; "Pinned" lists say "Forest shows more" when it is off.
6. **Not yet verified by eye on a real desktop**: the Forest toggle's regrow and the midnight regrow (I covered
   them with unit tests and the live launch, not by waiting for midnight). Worth watching once.

## Review fixes

The review of the first cut found these; fixed:

1. **The git gate could hang everything.** `GitGate.enter()` now throws if its task is cancelled (the waiter
   leaves the queue, holds no place), and `GitRunner` stops a process that outlives its timeout (60 s,
   `GITRASIL_GIT_TIMEOUT`; SIGTERM, SIGKILL after 2 s) and when its task is cancelled, handing its place back at
   once without waiting for the process's pipes to close. Dropping a pane cancels its start and its queued reads
   (`RepoGraphStore.stop`, `WorktreeExecutor.cancelReads`), so turning Forest off leaves nothing waiting.
   Tests: `GitGateTests` (order, cancelled waiter, cancelled before entering, timeout, cancelled read).
2. **Plain orchard names overlapped at 12.** Plates are now fitted to the plot (`PlateFit`, as in the
   forest): whole when they fit, smaller, written down the ground, or left out. Checked with a 12-repo render on a
   1440×900 display.
3. **Late trees restarted the whole grow-in.** The wait for trees to be read scales with the count (2.5 s plus
   0.15 s for each past four, so 11.5 s at 64; it ends as soon as every pane has read, which at 64 is ~4 s), and a
   tree that still arrives late waits unseen and grows with the others in one grow-in once arrivals pause for
   0.6 s (or 3 s after the first), instead of one per arrival.
4. **The wave.** It now starts after the trees on the tree (the largest `treeCapacity` over the connected
   displays; the orchard's 12), and ranks as the view does (by each pane's seed, not its path).
7. README documents the Forest and the cap of 12; the stale `maxPanes` reference is gone.

Not done: (6) the scene is still planned once for the layers, once for the banners and once for the canvas on a
change; each plan is 1-25 ms and happens only on a change. (8) At four repositories the single tree looks
slightly different from `main`'s (the bough fan is chosen by count, `Fit.fitting`): intended, left as is.
Ranking by UTC day is as built, pending Daniel's answer.

Numbers after the fixes: 64 repositories launch in 18.9 s of CPU, 142 MB, 780 git processes (two runs); idle CPU
is still zero (6.17 s at 25 s, 6.18 s at 55 s); the live grow-in peaks at 384 ms of busy time a second (was 530)
and the forest wave costs 150-310 ms a second for about 4 s.

