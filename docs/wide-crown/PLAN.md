# Wide crown: a tall trunk with its boughs laid out across the screen

Brief (from Arbor, for Daniel): as the single tree takes more repositories, it should spread across the screen
rather than climb. Overlap is fine; "this isn't meant to be used as information, it's meant to be beautiful".
The data stays the seed (which boughs exist, roughly how big), but no layout rule should exist only to keep every
branch separate. Small trees look as they do today, or better. Every bough stays attached at every size (the
round 3/4 floating-bough bug must not come back), the tree stays on screen, and the Forest still works. Branch
`feat/wide-crown` from `origin/main` (b070dea).

The design is Daniel's sketch, a tall, slim trunk with tiers of boughs and a small crown, which replaced the
first round's oak.

## Why it went vertical

Measured on `main` with 64 synthetic repositories (`scripts/forest-fixtures.py`), all on the tree
(`GITRASIL_TREE_CAPACITY=64`), 1440×900@2x: the crown is 549 pt wide at 4 boughs, 693 at 12, 711 at 32, 755 at 48,
while the tree is the full height of the screen every time. Adding boughs makes the crown denser, not wider:

1. **The fan is capped.** `YggdrasilLayout.Fit` fans the boughs `base + perBough × count` degrees either side,
   capped at 74° (`Fit.wide`); from 7 boughs on, every bough added lands between the others.
2. **Every bough bends back up.** `TreeLayout.bough` straightens each bough to 35% of its lean along its length,
   so even the outermost ends up near 26° off vertical: a fan of near-vertical rods.
3. **Every bough is a whole tree's height.** A bough's length is its repository's trunk height, whatever the count,
   so the middle boughs climb as high as a lone tree would.
4. **The frame fits the height.** `Landscape.singleTree` scales the tree to the screen's height and only shrinks
   for width when the crown is wider than the screen, which it never was.

## The change

`YggdrasilLayout.Shape(count:)` shares the boughs out:

- **Crown.** The last `crown` boughs in pin order fan out of the trunk's top exactly as the single tree always
  has (the same fan, `Fit`, foot spread and seeds). Up to 4 boughs that's all of them; then `2 + count / 6`, at
  most 6. Over tiers the crown boughs are drawn at 0.8 of their size (`crownReach`), so it stays a small crown.
- **Tiers.** The rest leave the trunk at evenly spaced heights from 0.36 to 0.86 of its height, in pin order from
  the bottom, alternately left and right, a seeded hair higher or lower. Each leans 78–94° (nearly level, a touch
  up or down), gives up only −4…20% of that lean by its tip (`Planting.straighten`; the crown's is 65%), and
  reaches 1.55 × (1.15 − 0.3 × height) times its tree's own size, ±15% (`Planting.reach`), so the low tiers reach
  furthest.
- **Limbs off a tier** (`Planting.splay`, new): they leave it the way limbs leave a limb, 26–46° to either side
  of it, at their own size (the tier's `reach` doesn't stretch them), and bend toward upright less (tropism 0.07
  instead of 0.18). Without this they climbed straight up off every tier and the middle became a thicket. They
  favour the tier's upper side.
- **Trunk.** Its height is 0.34 + 0.042 per tier, up to 26 tiers (1.43, from 32 boughs). The pipe model
  (width² adds up) now counts only the boughs leaving above each height, plus a tier's wood a little past its
  foot (`carriedPast`), so the trunk tapers from the ground to the crown as the tiers leave it, with a 30% flare at
  the foot fading upward. A node every 0.025 at least.
- **Attachment.** Every foot stands inside the trunk's wood at its own height, toward its own side, its whole base
  within the trunk's width (the existing `limit`), and the two trunk nodes around it carry its wood.
- **No separation rules.** Nothing keeps boughs apart; they overlap.

### Small trees

1–4 boughs are the tree as it was, unchanged to the pixel (crown only, trunk 0.34, the same nodes and seeds;
548.7 pt at 4 on a laptop, as on `main`). Tiers start at 5: three tiers and a crown of two. I tried tiers from 4
(two tiers and two in the crown); it came out lopsided, one low bough each side and a bare pair on top, so 4
stays a fan. 4 is also where `Fit.standard` ends.

## Results

On screen (forest study, 64 synthetic repositories, all on the tree), crown width in points:

| boughs | 4 | 5 | 8 | 12 | 20 | 32 |
|---|---|---|---|---|---|---|
| 1440×900, `main` | 549 | | 606 | 693 | 764 | 711 |
| 1440×900, tiers | 549 | 1216 | 1360 | 1336 | 1264 | 1164 |
| 5K, `main` | 918 | | 1014 | 1159 | 1278 | 1189 |
| 5K, tiers | 918 | 2033 | 2480 | 2233 | 2114 | 1947 |

At 8 the laptop tree is as wide as the frame allows (1360); from there the taller trunk shrinks it a little with
each tier, since the frame still fits the height. With the Forest on (64 repositories, tree capacity as shipped:
12 and 20), the tree stands between the forest's halves as before, its lowest tiers over the nearest forest trees.

Tests (`YggdrasilLayoutTests`): 1–4 boughs are all crown on a 0.34 trunk with the old planting; the trunk grows
taller from 4 to 32 boughs (more than 3×) and stops there; at 8–32 most boughs are tiers, their feet in pin order
from under 0.4 to over 0.8 of the trunk, alternating sides, and the crown (at most 6) leaves from the trunk's head;
tiers lean 75–95°, keep their lean, reach past their tree's size and run out more than twice as far as they rise;
a big tree is wider than tall; the trunk tapers as tiers leave it and thickens with the count; the layout is the
same every time. The attachment tests run to 64 boughs (every base inside the shared trunk at its own height,
every limb inside its parent, boughs on the side they lean to, bases still while growing in).

## Checks

- Renders with the forest study (`--forest`, `GITRASIL_FOREST_OUTPUT=single`) at 4–32 boughs on 1440×900@2x and
  5K, and the Forest at 64. Renders and fixtures stayed in the job's temp folder, never committed; a throwaway
  defaults suite, deleted after.
- `scripts/check.sh` on the final commit.

## Decisions for Daniel

1. **How tall.** 0.042 more trunk per tier, topping out at 26 tiers. Taller makes the tiers sparser and the tree
   smaller on screen (the frame fits the height); shorter crowds them.
2. **Where the tiers sit.** 0.36–0.86 of the trunk. Starting lower shows less bare trunk; ending higher tucks the
   crown into the top tiers.
3. **The crown.** 2–6 boughs at 0.8 size. Fewer or smaller makes it read more as a tip than a crown.
4. **Small trees.** Tiers from 5 (above); from 6 or later is one number (`Shape.fanUpTo`).
5. **Tree capacity.** Still 12 (laptop) / 20 (1440 pt and up) before the Forest takes the rest. A policy change I
   left alone.

## Round 3: leafy, slim, opaque

Daniel ran the tall tree live with 32 repositories. He liked the trunk and the colours, but it looked bare, the
wood was too thick, and the overlapping boughs showed through each other.

- **Leaves.** Each repository's main or default branch (its bough's trunk) puts out leafy twigs in the neutral
  leaf ink, so the real branches and worktrees stay the coloured part (`TreeDrawing.twigs`, in `Foliage.swift`).
  A bough gets 5 + 3·√commits twigs, capped by a budget of about 640 for the whole tree (10–36 per bough). Each
  twig has three leaves along it and a fan of four or five at its tip, sits mostly on the bough's upper side, and
  shows once the bough has grown past it. Twigs are seeded by repository and place, so a new commit doesn't move
  the others. At 32 boughs a frame takes about 80–105 ms to draw. It only redraws on changes and while the tree
  grows in.
- **Slim wood.** A tall tree's boughs (trunk and limbs) are drawn at 0.4 of their own trees' thickness
  (`Planting.girth`, `YggdrasilLayout.boughGirth`). The shared trunk adds up their widths cubed instead of squared
  (`tallExponent`), so 64 boughs make a trunk about as thick as four boughs' fan.
- **Opaque wood.** A tall tree's boughs are painted one at a time, each over a paper-coloured underlay (`draw`'s
  `groups`), with the crown at the back and the tiers from the top down. A bough in front hides the wood behind
  it.
- **Small trees.** The leaves suit them too, so every single tree gets them, from 2 boughs up. The wood of trees
  with up to 4 boughs is unchanged: full thickness, one piece, and the pipe-model trunk. Turning the leaves off
  for them takes one line (make `foliage` nil when `shape.tiers == 0`).

## Round 4: boughs toward the viewer, and droop

Daniel found round 3 much closer. The centre still looked bare, and he wanted even more variety in the bough
angles, since the crossings were what he liked.

- **Toward the viewer.** In a tree with at least 6 tiers, every third tier, but never the top one, comes
  toward the viewer instead of reaching out to a side (`Shape.isFront`). It leaves from the trunk's middle and
  can point anywhere from steeply up (35°) to drooping (125°). It's foreshortened to 0.2 of a side tier's reach
  (`frontReach`) but stays just as thick, so it reads as a bough pointing at you, and its twigs and leaves
  gather into a clump. Front boughs are painted after all the others, from the top down, so they hide the trunk
  and the side boughs' bases behind them. 32 repositories get 8 of them, and 12 get 2.
- **Droop.** Side tiers now lean between 72° and 100° from upright, plus up to 10° more for the lowest
  (`tierDroop`), so some rise a little and some droop as much as 20° below level. They still straighten a little
  toward the tip. Side and front tiers each alternate left and right among themselves.
- **Clear of the ground.** A drooping tier whose full-grown bough would come within half its foot's height of
  the ground is eased toward level, then past it if it needs to (`clearing`, `groundClearance`). This matters
  for the low tiers of a short tree, such as the 12 boughs in front of the Forest. The check uses the
  full-grown bough, so the angle doesn't change while the bough grows in.
- Banners are unchanged. A front bough's ribbon can end up hanging low on the trunk, since the bough is so
  short. That's left for the banner round.
