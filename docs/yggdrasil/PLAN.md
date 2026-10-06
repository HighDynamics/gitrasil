# Yggdrasil — plan

Task (from Arbor): turn the live background from a branch graph into a tree. Main is the trunk;
branches and worktrees grow off it as curving, tapering limbs, with sub-branches where history
forks again, foliage at the tips, and only branch names as text. Keep the ink-on-paper feel,
per-branch inks, light and dark, displays, pins, ref-only watching and 0% idle.

Branch `spike/yggdrasil`, cut from `spike/live-background` (ce20fcb).

## What stays

Everything below the drawing: `RepoGraphStore` (ref-only watching, settle, fingerprint gate),
`Derivations.repoGraph`, pins, the menu, one desktop window per display, occlusion pause. The
store keeps publishing a `HistoryGraph`; the tree is derived from it, so the git side doesn't change
apart from the options (more trunk history, more branches, a longer age limit).

## History as a tree

A new pure value in Core, `RepoTree`, built from the repo-wide `HistoryGraph`:

- **Trunk**: the spine, the default branch's recent first-parent commits (up to 200).
- **Limb**: a branch lane, its own commits only (the ones not on the trunk or on another limb),
  oldest first. Its **parent** is whatever holds its fork commit: the trunk, or another limb (so a
  branch off a branch is a sub-branch). A fork older than the drawn trunk joins at the trunk's base.
- **Bud**: a branch with no commits of its own (just created, or merged and left behind). It sits on
  the commit its tip points at, as a tiny twig with a leaf or two and its name.

Then `TreeLayout` (also Core, unit-free, testable) turns the tree into geometry in abstract units,
where a full-grown trunk is 1 tall:

- **Fork height on the trunk.** A limb leaves the trunk at a height set by how far back its fork
  commit is, on a log scale from the tip (depth 0 is the top, the oldest drawn commit is the bottom),
  lifted so the lowest stretch of trunk stays bare. Recent forks spread through the crown; old ones
  leave low.
- **Trunk height** grows with trunk history: a repo with a dozen commits is a sapling, one with
  hundreds is a full tree (log scale, capped).
- **Limbs grow a step per commit.** Each commit is one segment of the limb. Step lengths shrink
  geometrically (the first is longest), so a long-lived branch is long but bounded. The limb's
  heading starts at an angle off its parent and turns a little at every step, then bends gently
  upward (toward the light). Limbs off the trunk lean more sideways the lower they leave; higher
  ones rise more steeply, and the upper ones are shorter, giving a crown.
- **Side** balances the crown: limbs off the trunk, taken bottom to top, each go to the side that is
  lighter so far, weighted by how many branches each carries (itself plus its sub-branches). Branch
  counts, never commit counts, so a new commit can't flip a limb. **Angle** and the turn at every
  step are seeded from the branch name and the step's index from the limb's base.
- **Sub-branches** leave their parent limb at the node of their fork commit, angled off the parent's
  heading, at a smaller scale, mostly toward the outside (seven in ten).
- **Thickness** follows the pipe model (da Vinci's rule): a limb's width at a node goes with the
  square root of the commits still to come beyond it, including its sub-branches; the trunk's width
  at a height goes with everything above it. So the trunk is thickest at the ground and every limb
  tapers to its tip.

## Foliage

Leaves are commits. Each commit on a limb puts two or three leaves at its node, on alternating
sides, plus a small twig spray (a twig with a fan of three leaves), and the tip gets a cluster. The
trunk's last 30 commits leaf out the top of the trunk.

- A leaf's size, angle and side are seeded from the branch name and the commit's index.
- Leaves fade with the commit's age (the same 14-day half-life as before), and old commits drop
  some of their leaves, so a stale branch reads as a thinning or bare limb and an active one is lush.
- Leaves are in the branch's ink; the trunk's are in a muted leaf ink. A faint wash of the branch's
  ink sits behind each tip's cluster, for volume.
- A branch checked out in a worktree gets a small blossom at its tip.

Wood is the plain ink; a limb's stroke shades from the wood ink at its base to its branch ink at the
tip. The only text is each branch's name at its tip, in the hand font and its ink, placed beyond the
tip and nudged off any label already placed; a name with no free spot is left out rather than
overlapping another. The repo name moves to a plate caption under the
ground.

## Stability between redraws

- No randomness outside seeded generators. Seeds come from the repo name (trunk sway, roots) and
  the branch name plus a step index (everything about a limb and its leaves).
- A limb's shape depends only on its name, its fork height and its commit count. A new commit adds
  one step and a leaf at the tip; nothing before it moves. An amend or rebase that keeps the count
  keeps the shape.
- A new trunk commit slides fork heights down a hair (log scale) and grows the trunk slightly.
- Scale: each pane fits a nominal tree 1.45 units tall (and the tree's actual width), so a new
  commit doesn't rescale the picture unless the crown outgrows the pane. Leaf, label and stroke sizes
  follow the pane's scale, within limits, so a narrow pane doesn't get giant leaves.

## Growth animation

When the graph changes, the model compares each limb's commit count with the previous tree's. Limbs
that grew animate from the old count to the new (the tip extends, new leaves unfurl), new limbs grow
from their fork point. It runs 1.8 s (eased) at ≤30 fps in the existing paused-clock `TimelineView`, then
stops. Anything else (a limb shrinking, a fork moving) snaps.

## Multiple pins: a grove

The panes stay side by side, but they share one ground line drawn across the whole screen, so the
pinned repos read as a grove of trees on one horizon rather than separate tiles. Each tree's size
comes from its own history (sapling vs full tree). The repo name is a plate caption under each tree.

## Checks

- Unit tests for `RepoTree` (parents, fork points, buds, sub-branches) and `TreeLayout` (determinism,
  a new commit leaves existing nodes where they were, a new branch doesn't move the others).
- Run against throwaway repos with many branches and merges, and read-only against a couple of
  Daniel's repos in `~/repos`, pinned in a throwaway defaults suite. Screenshots of the app's own
  windows only, saved here.
- `swift build` and `swift test` on the final commit.

## What the runs showed

Screenshots (the app's own windows only, captured by window id):

- `ash-light.jpg` — the throwaway repo `ash` (144 trunk commits, 13 branches with sub-branches,
  merges, two worktrees) on the 1440×900 display, light mode.
- `grove-dark.jpg` — `ash`, the sapling `rowan` and Daniel's `gitrasil` (read-only) as a grove on
  the 3440×1440 display, dark mode.
- `growing.jpg` — mid-growth: three commits on `spike/physics` and a new four-commit
  `feature/sprout`, a fraction of a second after the refs settled.

Findings:

- **Updates**: a burst of three commits plus a new branch was one derive and one redraw; the two
  grown limbs animated and every other limb stayed pixel-identical.
- **Energy**: idle afterwards was 0.0% CPU (0.01 s of CPU over 20 s), ~64 MB resident.
- **Real repos** (pinned read-only in a throwaway suite): `dnd-app` (200 trunk commits, 14 limbs)
  is a full tree; `gitrasil` and `love-scribe-journal` (6 trunk commits each, 7–8 limbs) are
  saplings with a crown at the top. Repos with many similarly named branches (`worktree-review-*`)
  crowd their labels; some names are left out.
- `dnd-app`'s trunk resolves to `origin/master` (its `origin/HEAD`), so local `main` is drawn as a
  limb. That's the existing trunk detection, unchanged here.
- `GraphLayout` is no longer used by the background; it stays in Core (with its tests) for now.
