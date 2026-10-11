# Curving boughs

Brief (Daniel, Oct 10, through Arbor): boughs and limbs bend gently as they grow, seeded by name so the curve is
stable across redraws. Banners and twigs follow the curve. Front boughs still grow out of the trunk. Keep the
droop's ground clearance and the layout cache working. Branch `feat/curving-boughs`, stacked on `feat/banners`.

## Where things stand

- A **bough** (a repository's trunk leaning out of the shared trunk) is walked out along a centreline
  (`TreeLayout.bough`): it leaves at its planting's heading and straightens steadily toward its tip, so every
  bough is the same smooth arc, only longer or shorter, steeper or flatter.
- A **limb** is walked out a step per commit (`TreeLayout.grow`): each step turns by a seeded ±11° and bends
  toward upright (tropism). It wiggles, but has no curve of its own.
- Everything else hangs off those curves: leaves and twigs from the nodes and the outline drawn through the
  curve, pennants from the tips, ribbons from points along the bough's curve. Clearance (`clearing`) lays the
  whole bough out to test it, and its answer is kept (`Clearings`).

## The bend

- **Boughs.** On top of its straightening, a bough's heading at `t` (0 at its foot, 1 at its tip) is turned
  by a seeded `curl·t² + wave·sin(πt)·t`: a curl that gathers toward the tip (more often up than down, as
  boughs reach for the light) and a gentle bow along the middle. Both are zero, and level, at the foot, so a
  bough still leaves the trunk at its planting's heading, and a front bough still grows out of the trunk's
  face. Gentle: the curl is 4–12° by the tip, the bow 2–7°.
- **Limbs.** Each limb gets a seeded curl, a couple of degrees a step, the same way all along it. Tropism
  pulls it back toward upright, so a long limb settles into a gentle arc rather than curling round.
- **Seeded by name.** The bough's bend from its repository's name (and the layout seed), the limb's from its
  branch's name, on random streams of their own, so the existing draws (sway, turns, sides) are unchanged.
  The bend depends on where along the stem it is, never on time: a new commit still grows a step at the tip
  and moves nothing else on a limb.
- **What follows.** Leaves, twigs, pennants and ribbons are all placed off the curve, so they follow it.

## Keeping what works

- **Clearance.** `clearing` lays out the bent bough, so a curl that drops a tier's tip is eased like any other
  droop. Its kept answers are keyed by everything it reads; the bend is a function of those, so they stay
  right.
- **Determinism.** Same names, same seed, same curves.

## Checks

Tests: a bent bough's foot leaves at its planting's heading; the bend is seeded (the same twice, different
between names) and gentle; a limb curls the same way along its length and a new commit still moves nothing
else; front boughs still start inside the trunk; drooping tiers still clear the ground. Renders in every
palette, light and dark, at 8, 20 and 32; draw time against Round A with `--benchmark`. `scripts/check.sh`.

## Results

- **Renders** (`--forest`, 1440×900@2x, ink, charcoal and chalk, light and dark, at 8, 20 and 32; hanging at
  20): boughs bow and curl gently, limbs arc, and leaves, twigs, pennants and ribbons sit on the curves. Front
  boughs still come out of the trunk's face. No bough trails near the ground.
- **Banners.** About as many fit as before: ribbons 6/19/24–25 at 8/20/32 (Round A: 7/19/25–26), pennants
  43–45 of 52, 79–83 of 128, 82–86 of 202. At 8, one low bough's ribbon (balsa) no longer finds a spot above
  the floor, so its name goes on its trunk's pennant, as for any ribbon without room.
- **Draw time** (`--benchmark`, chalk, 32, median of 5, Rounds A and B back to back): trees 92.2–93.6 ms
  against 92.3–92.4 ms, banners 97.0–99.5 ms against 97.6–97.9 ms. No change beyond noise. Planning is the same
  (~37 ms at 32).
- **Tests.** One golden test (`testTheTaperLeavesTheLayoutAlone`) records each limb's last node. It's there to
  show the taper doesn't move the layout, so its reference is re-recorded with the curl.
