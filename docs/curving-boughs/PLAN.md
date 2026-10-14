# Curving boughs

Brief (Daniel, Oct 10, through Arbor): boughs and limbs bend gently as they grow, seeded by name so the curve is
stable across redraws. Banners and twigs follow the curve. Front boughs still grow out of the trunk. Keep the
droop's ground clearance and the layout cache working. Branch `feat/curving-boughs`, stacked on `feat/banners`.

Round 2 (Daniel, live, through Arbor): "More bend, and multiple directions, especially for the longer ones." And:
"Tree branches can bend and have 'elbows' and 'joints' and end up moving in different directions than just
curving to give it more visual interest." A joint should read as wood, a slight knuckle, never a kink; the number
of elbows grows with length, so short boughs stay simple; everything that held still holds.

Round 3 (Daniel, through Arbor; branch `feat/bough-joints`, stacked on this one): more joints, and sharper,
some of them knotted; boughs that grow out of the trunk rather than looking pasted onto it; a branch carrying
on from its parent's tip that doesn't start thin; and the lows from Arbor's review of the hidden names.

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

- **On a bough.** An elbow (`TreeLayout.Elbow`) is a turn of 24–44° (round 2: 18–34°) made over a short
  stretch of the bough (5% of the tree's height, a smoothstep), so the bough changes direction sharply and
  carries on in its new one, smooth on either side. Each elbow has its own place, a seeded distance from the
  bough's foot (in tree heights): the first 0.28–0.36 out, each next about 0.28 further (±30%), at most five
  (round 2: 0.35–0.47, 0.4, three). It's there once the bough reaches past it by enough that it falls within
  88% of the bough's length, so short boughs have none and none turns right at a tip. The first heads down a
  little under half the time; each later one turns back the other way 70% of the time, so a bough droops and comes back up, or turns and carries on. A bough
  leaning left bends as the mirror of one leaning right (curl, bow and elbows).
- **A cap.** The bough's heading never turns more than 36° (`boughTurn`, the one place it's set; round 2:
  26°) from its planting's heading, either way, anywhere along it: curl, bow and elbows together, as they
  actually add up at every point. Each elbow is checked as it's added against everything before it, sampled
  along the rest of the bough: its own way if that fits, else the other way, else 80%, 60% or 40% as big, else
  it's left out. Round 2 measured 26° as the bound over 3,000 names; 40° let long side tiers climb steeply, out
  of the band they're meant to reach in, so round 3 stops short of it, where the sharper elbows have room to
  zigzag. A test checks the cap over 150 names at ten lengths on both sides, every 0.0002 along.
- **Ground clearance.** Once a bough leans out (more than 0.5 rad), its heading is held on its own side,
  between straight up and level (or its planting's own lean, if that's lower), so an elbow heading down can't
  take it nearer the ground than its planting has it. `clearing` still eases drooping
  tiers as before.
- **Knuckles.** The wood thickens across an elbow, 18–38% (round 2: 10–22%) by how sharp it turns, falling
  away within the elbow's stretch. The bough's outline gets extra points only inside each elbow (every 0.012 of
  the height rather than 0.03), so a joint is drawn round, never as a kink.
- **On a limb.** From its third step, each step of a limb has a 24% seeded chance of an elbow of 22–40°
  (round 2: 14%, 16–30°), made over the two steps that follow, with a knuckle on them; each turns back from the
  last 70% of the time. It's seeded by the branch's name and the step, so a new commit still moves nothing
  behind the tip. A limb's elbows have no cap of their own: tropism pulls each back toward upright, and a limb's
  heading is held within ±1.75 rad of it.
- **Seeded and stable.** Each bough elbow comes from the repository's name on a stream of its own, all its draws
  made every time, so nothing about it hangs on how many others there are. A commit that lengthens a trunk far
  enough adds the next elbow in its place, and the ones it had stay the same distance out from the foot; only
  a cap that binds differently on the longer bough can change one's size or way.
- **Banners.** A ribbon's stops are placed by distance along the bough, not by the curve's points, which crowd
  together through an elbow, so a ribbon doesn't slide when an elbow comes or goes.

## Joints (round 3)

- **Knots.** Some elbows have a knot: 55% of a bough's, 40% of a limb's, sized 0.6–0.9 of the wood's width
  there (`TreeLayout.Knot`). A bough's are drawn from its bend's stream with its elbow, a limb's from a stream
  of its own seeded by its name and the step, so a knot stays put as the wood grows. The wood swells a further
  30% (`burl`) at a knotted joint. It's drawn (`Knots.swift`) a little to the outside of the turn as an oval
  half as long again along the wood as across it: a dark eye with a rim, the bark's streaks parting around it,
  in each medium's own bark marks (light on brush ink, dark on charcoal, chalk on chalk). None on wood too fine
  to show one.
- **Grafts.** A bough off the shared trunk is drawn in a later group than the trunk, so it lay on the trunk as
  a piece of its own: a cut end, a rim, a tone that wasn't the trunk's. It's now grafted (`Grafts.swift`):
  narrowed inside the trunk's wood (a third of its width at the foot, all of it where it leaves) and faded in
  from its foot over that wood only, so it grows out of it. Two things still gave it away: the fade's mask
  stopped hard at the trunk's edge, leaving an anti-aliased seam, so it eases off 6% of the bough's width in
  from the edge (`feather`); and a bough leaving at a slant bulged its collar out under itself past the trunk,
  so a grafted collar's flare is soft-capped at 35% of its own width (`graftFlare`).
- **Carrying on.** A limb leaving near or at its parent's tip grew from wood the tip taper had already
  narrowed, so it started thin, or from a point, and thickened again. Each stem now knows the limbs leaving it
  and how wide their bases are (`Stem.carries`), and its taper (`TipTaper`) never narrows it below one before
  that limb leaves: a limb leaving a step back still lets the parent end in a point past it, and one carrying on
  from the very tip leaves the parent ending as wide as itself.
- **Hidden names** (Arbor's review lows). A name hidden behind wood painted in front of its bough waits only for
  the trees painted in front of its own (`BannerPlan.places`), and among those only for the ones that began
  growing in with it or before, so it no longer waits for forest trees behind it, and a late tree doesn't hide
  a name that's already shown. Ribbons and hidden names go by one paint order: what's painted after a bough is
  in front of it, a tie broken by bough order.

## Review fixes (round 3, before the PR)

An internal review of `feat/bough-joints` found nothing blocking; three points are fixed before it goes public:

1. **Streams collide.** A limb's knot (`knot(of:)`, stream `-200 - step`) and elbow (`elbow(of:)`, `-100 - step`)
   share a key, so step `s`'s elbow draws are step `s - 100`'s knot draws. Knots get a base of their own, far
   from every other stream a name is keyed with in `TreeLayout.swift` (the tree's -1, a limb's -2, 0 and its
   steps, a repository's -3, a limb's curl -21, a bough's elbows -23…-27, a limb's elbows -100 - step). Free
   only before release: it moves where knots fall.
2. **`tipTaper` cost.** It searches the curve for the node nearest each carry (curve points × limbs), and
   `taperFactor` builds it once per limb at fork time, so a stem with many limbs costs limbs² × curve length,
   and layout reruns per frame while growing in. A limb's node lies on the curve, so the curve index is
   recorded when the node is appended, not searched for. Timed on a stem with ~150 limbs before and after.
3. **`fadeIn` per grafted stem.** Each builds a `Path.union` of the parent's wood, a blurred edge stroke and a
   masked layer on every draw. Check whether a single-tree draw is cached between frames; cache the parent's
   wood if it's redrawn each frame, leave it (and say so) if it isn't.
4. Nits, if trivial: a lazy filter in `Fronts.rects(before:near:)`; drop `draw`'s unused `emerging` parameter.

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

## Results (round 3, joints)

- **Renders** (at 8, 20 and 32, every palette, light and dark, plain and hanging): boughs zigzag at sharper,
  more frequent joints, knotted here and there; boughs grow out of the trunk with no seam or lobe; a limb
  carrying on from a tip carries on at its own width. Front boughs still come out of the trunk, and nothing
  trails near the ground.
- **Banners.** Pennants 38–42 of 52, 78–81 of 128, 67–76 of 202 (round 2: 43–46, 71–76, 67–78); ribbons
  8/18–20/25. Hanging: pennants 14–16/52, 24–25/128, 13–15/202.
- **Draw time** (`--benchmark`, chalk, 32, median of 11, round 2 back to back): trees 98.4 ms against 99.8 ms,
  grow-in 71.6 against 70.4, unchanged. Banners 125.7 ms against 117.4 (hanging: 91.4 against 81.4), up 7–12%,
  from the joints, not the hidden-name fixes (the commit before them: 124.3 and 90.6). That figure includes
  planning the banners against the bent wood, which is kept between redraws. A gust frame does less: 92 layers,
  55 masked, 1.66 Mpt² against 105, 67, 1.98 (hanging: 38, 24, 0.84 against 48, 28, 1.01).
- **Tests.** Some elbows have a knot seeded by their name, and a stem's knots swell its joints and stay put as
  it grows in; a limb carrying on from its parent's tip leaves wood as wide as itself; a bough's wave mirrors
  with its side; the cap holds ten times finer along each bough; a hidden name waits only for trees in front of
  its own that began with it or before; the plan keeps boughs and trees in the order they're painted.
- **Lint.** `WallpaperView.swift` grew past the file-length limit, so the graft and knot drawing moved to
  `Grafts.swift` and `Knots.swift`, and the banner fade-in (`shownBanners`) next to the banner plan in
  `Banners.swift`; the carrying-on code and its tests sit in extensions of `TreeLayout` and its tests.

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
