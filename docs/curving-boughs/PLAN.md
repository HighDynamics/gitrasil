# Curving boughs

Brief (Daniel, Oct 10, through Arbor): boughs and limbs bend gently as they grow, seeded by name so the curve is
stable across redraws. Banners and twigs follow the curve. Front boughs still grow out of the trunk. Keep the
droop's ground clearance and the layout cache working. Branch `feat/curving-boughs`, stacked on `feat/banners`.

Round 2 (Daniel, live, through Arbor): "More bend, and multiple directions, especially for the longer ones." And:
"Tree branches can bend and have 'elbows' and 'joints' and end up moving in different directions than just
curving to give it more visual interest." A joint should read as wood, a slight knuckle, never a kink; the number
of elbows grows with length, so short boughs stay simple; everything that held still holds.

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
  face. The curl is 8–20° by the tip, the bow 4–11° (round 1: 4–12° and 2–7°).
- **Limbs.** Each limb gets a seeded curl, 2–4° a step (round 1: 1.2–3°), the same way all along it. Tropism
  pulls it back toward upright, so a long limb settles into a gentle arc rather than curling round.
- **Seeded by name.** The bough's bend from its repository's name (and the layout seed), the limb's from its
  branch's name, on random streams of their own, so the existing draws (sway, turns, sides) are unchanged.
  The bend depends on where along the stem it is, never on time: a new commit still grows a step at the tip
  and moves nothing else on a limb.
- **What follows.** Leaves, twigs, pennants and ribbons are all placed off the curve, so they follow it.

## Elbows

- **On a bough.** An elbow (`TreeLayout.Elbow`) is a turn of 18–34° made over a short stretch of the bough
  (6% of the tree's height, a smoothstep), so the bough changes direction fairly sharply and carries on in its
  new one, smooth on either side. Each elbow has its own place, a seeded distance from the bough's foot (in
  tree heights): the first 0.35–0.47 out, each next about 0.4 further (±30%), at most three. It's there once
  the bough reaches past it by enough that it falls within 85% of the bough's length, so short boughs have
  none and none turns right at a tip. The first heads down a little under half the time; each later one turns
  back the other way 70% of the time, so a bough droops and comes back up, or turns and carries on. A bough
  leaning left bends as the mirror of one leaning right (curl, bow and elbows).
- **A cap.** The bough's heading never turns more than 26° (`boughTurn`, the one place it's set) from its
  planting's heading, either way, anywhere along it: curl, bow and elbows together, as they actually add up at
  every point. Each elbow is checked as it's added against everything before it, sampled along the rest of the
  bough: its own way if that fits, else the other way, else 80%, 60% or 40% as big, else it's left out. Over
  3,000 names at lengths 0.4–2.2 on both sides, the worst is 25.97°, and 99.7% of elbows keep their seeded size.
  Looser (40°) let long side tiers climb steeply, out of the band they're meant to reach in.
- **Ground clearance.** Once a bough leans out (more than 0.5 rad), its heading is held on its own side,
  between straight up and level (or its planting's own lean, if that's lower), so an elbow heading down can't
  take it nearer the ground than its planting has it. `clearing` still eases drooping
  tiers as before.
- **Knuckles.** The wood thickens across an elbow, 10–22% by how sharp it turns, falling away within the elbow's
  stretch. The bough's outline gets extra points only inside each elbow (every 0.012 of the height rather than
  0.03), so a joint is drawn round, never as a kink.
- **On a limb.** From its third step, each step of a limb has a 14% seeded chance of an elbow of 16–30°, made
  over the two steps that follow, with a knuckle on them; each turns back from the last 70% of the time. It's
  seeded by the branch's name and the step, so a new commit still moves nothing behind the tip.
- **Seeded and stable.** Each bough elbow comes from the repository's name on a stream of its own, all its draws
  made every time, so nothing about it hangs on how many others there are. A commit that lengthens a trunk far
  enough adds the next elbow in its place, and the ones it had stay the same distance out from the foot; only
  a cap that binds differently on the longer bough can change one's size or way.
- **Banners.** A ribbon's stops are placed by distance along the bough, not by the curve's points, which crowd
  together through an elbow, so a ribbon doesn't slide when an elbow comes or goes.

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

## Results (round 2, elbows)

- **Renders** (as before, at 8, 20 and 32, plus hanging): elbows read as rounded joints with a slight knuckle;
  long boughs droop and come back up, or turn and carry on; short ones stay simple. Front boughs still come out
  of the trunk. Nothing trails near the ground.
- **Banners.** Pennants 43–46 of 52, 71–76 of 128, 67–78 of 202 (Round A: 44–47, 79–82, 82–84): a few fewer, as
  bent boughs crowd each other's tips. Ribbons 6–7/19–20/26–27. Hanging: 16/52, 22/128, 18/202.
- **Draw time** (chalk, 32, median of 5, back to back): trees 93.7–96.2 ms against Round A's 92.0–98.5 ms;
  earlier runs showed B 2–5 ms up. Within noise to slightly up (0–5%). A gust frame: 94 layers, 58 masked,
  1.79 Mpt² (hanging: 45, 23, 0.89).
- **Tests.** A longer bough has more elbows; an elbow turns smoothly and thickens the wood at its joint; an elbow
  heading down never takes a bough below its planting; a limb's elbows are seeded and come with its length. The
  golden in `testTheTaperLeavesTheLayoutAlone` is re-recorded again.
- **Review fixes.** No bough turns past the cap anywhere along it (600 names × 10 lengths × both sides, every
  0.002); a bough's elbows stay put as it grows longer (300 names, 0.3 to 2.2 in steps of 0.05). Draw time
  unchanged (trees 95.6 ms, grow-in 69.4 ms, against 95.6–95.9 and 69.1–70.3 before).

## Results (round 1)

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
