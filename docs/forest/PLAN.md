# Forest — how many trees can we fit on screen?

Task (from Arbor, for Daniel): "what it takes to put **far more trees** on the screen, and push the
limit of spacing to see what we can do". An exploration: measure the limits, prototype layouts, bring
back renders, numbers and a recommendation. **Nothing ships from this round**: every prototype is
opt-in, the defaults Daniel sees are untouched. Branch `spike/forest`, cut from `origin/main`
(5f8b515). Not pushed.

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
