# Wide crown: a single tree that spreads like an oak

Brief (from Arbor, for Daniel): as the single tree takes more repositories, it should grow like a big oak,
its crown spreading sideways more than it climbs: a short thick trunk, big limbs leaving low and reaching far
out, a broad domed crown much wider than tall. Overlap is fine; "this isn't meant to be used as information,
it's meant to be beautiful". The data stays the seed (which boughs exist, roughly how big), but no layout rule
should exist only to keep every branch separate. Small trees (a handful of boughs) look as they do today, or
better. Every bough stays attached at every size (the round 3/4 floating-bough bug must not come back), the tree
stays on screen, and the Forest still works. Branch `feat/wide-crown` from `origin/main` (b070dea).

## Why it goes vertical now

Measured on `main` with 64 synthetic repositories (`scripts/forest-fixtures.py`), all on the tree
(`GITRASIL_TREE_CAPACITY=64`), 1440×900@2x: the crown is 549 px wide at 4 boughs, 693 at 12, 711 at 32, 755 at 48,
while the tree is the full height of the screen every time. Adding boughs makes the crown denser, not wider. Why:

1. **The fan is capped.** `YggdrasilLayout.Fit` fans the boughs `base + perBough × count` degrees either side,
   capped at 74° (`Fit.wide`); from 7 boughs on the fan is as wide as it gets, and every bough added lands between
   the others.
2. **Every bough bends back up.** `TreeLayout.bough` straightens each bough to 35% of its lean along its length,
   so even the outermost (74°) ends up near 26° off vertical: a fan of near-vertical rods, the brush in the render.
3. **Every bough is a whole tree's height.** A bough's length is its repository's trunk height (0.5…1 unit, by
   commits), whatever the count and wherever it stands, so the middle boughs climb as high as a lone tree would and
   the outline is a tall shield, not a dome.
4. **The frame fits the height.** `Landscape.singleTree` scales the tree to the screen's height (nominal
   `crotchHeight + 1.45 × 0.82`), and only shrinks for width when the crown is wider than the screen, which it
   never was.

## The change

A crowd factor, `Fit.oak` (0…1, `Fit.oak(count:)`): 0 up to 5 boughs (today's tree, untouched), easing out to 1
by 28 (0.24 at 8, 0.51 at 12, 0.88 at 20). `Fit.fitting(count:)` sets it. Everything below scales with it, so
a small tree is today's shape and a big one an oak:

- **Wider fan.** The fan's cap opens from 74° toward 88° (`Fit.fanCap`), so the outermost boughs leave nearly
  level.
- **Boughs keep their lean.** `TreeLayout.Planting.straighten` (how much of its lean a bough gives up by its tip,
  0.65 as before by default) eases off for the outer boughs, by up to 30% (`Fit.straighten(away:)`), so they reach
  out sideways and turn up toward their tips.
- **Dome.** `TreeLayout.Planting.reach` scales a bough's whole tree, trunk and limbs (not widths): up to ×1.55 at
  the edge of the fan and down to ×0.58 in the middle (`Fit.reach(away:)`), so the tips trace a broad dome
  rather than a tall shield.
- **Limbs leave lower.** The outermost feet stand further down the shared trunk (`Fit.footDrop`, 0.16 → 0.20
  below the crotch), still inside its wood (the existing foot placement). The crotch itself stays at 0.34:
  lowering it (tried, 0.24) hid the trunk behind the boughs' plates and made a bush, not an oak.
- **Trunk.** Unchanged: the pipe model already thickens it with every bough (width² adds up), so a big tree's
  trunk is short against its crown and thick.
- **No separation rules.** Nothing keeps boughs apart; they overlap.
- **Not done: root flare.** I tried more, finer roots under a wide trunk; they merge into the same wedge outline,
  so it looked no different. A real oak-root flare needs its own drawing pass (see the decisions below).

## Results

Width ÷ height of the layout (foot to crown) with the test fixture's repositories (`YggdrasilLayoutTests.repos`):

| boughs | 4 | 8 | 12 | 20 | 32 | 48 |
|---|---|---|---|---|---|---|
| before | 0.76 | 0.77 | 0.93 | 1.03 | 1.07 | 1.13 |
| after | 0.76 | 0.97 | 1.43 | 1.97 | 2.03 | 2.23 |

On screen (forest study, 64 synthetic repositories, all on the tree), crown width in points:

| boughs | 4 | 8 | 12 | 20 | 32 |
|---|---|---|---|---|---|
| 1440×900, before | 549 | 606 | 693 | 764 | 711 |
| 1440×900, after | 549 | 658 | 874 | 1106 | 1000 |
| 5K, before | 918 | 1014 | 1159 | 1278 | 1189 |
| 5K, after | 918 | 1100 | 1462 | 1850 | 1672 |

At 32 and over the tree is limited by its height again: a long limb on a middle bough sets the top, and the frame
fits the height, so the crown is ~1000 of the 1360 points it could use on a laptop. With the Forest on (tree
capacity as shipped, 12 and 20), the tree stands between the forest's halves as before, its widest boughs over the
nearest forest trees.

Tests: the ratio grows with the bough count and is over 1.6 at 20; at 12–48 the oak is wider and lower than the
same tree without it; a big tree's outer boughs leave lower, nearly level, reach further and straighten less
than the middle ones; up to 5 boughs nothing changes; the trunk thickens with the count; the layout is the same
every time. The attachment tests run to 64 boughs (every base inside the shared trunk, every limb inside its
parent, boughs on their side, bases still while growing in).

## Checks

- Renders before/after with the forest study (`--forest`, `GITRASIL_FOREST_OUTPUT=single`) at 4–48 boughs on
  1440×900@2x and 5K, and the Forest at 64. Renders and fixtures stayed in the job's temp folder, never committed;
  a throwaway defaults suite, deleted after.
- `scripts/check.sh` on the final commit.

## Decisions for Daniel

1. **How far it spreads.** Full oak by 28 boughs, half by 12. Earlier (by 20) or later (by 40) is one number
   (`Fit.oak(count:by:)`).
2. **The middle.** Middle boughs are cut to 0.58 of their size for the dome. Shorter gives a flatter, wider dome
   (and a bigger tree on screen, since the height binds); longer keeps more of the brush in the middle.
3. **Tree capacity.** The single tree still holds 12 (laptop) / 20 (1440 pt and up) before the Forest takes the
   rest. The wider crown has room for more; raising it is a policy change I left alone.
4. **Root flare.** Optional in the brief; not done (above). Worth its own pass if wanted.
