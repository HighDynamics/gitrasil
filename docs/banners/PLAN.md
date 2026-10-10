# Banners: hidden by what's in front, hung from the boughs, kept off the ground

Brief (Daniel, Oct 10, through Arbor): banners should be occluded like everything else by default, with an option
like "Draw all banners in view" to keep today's behaviour. Another option hangs the banners from the boughs: gusts
lift them as now, and they fall back to dangling. Also: a front bough is short, so its banner can hang very low on
the trunk; at 32 repositories one sat just above the ground. Branch `feat/banners` from `origin/main` (55579c8).

## Where things stand

- The tree is one canvas (`MainTreeLayer`). A tall tree is painted a bough at a time over an opaque underlay
  (`TreeDrawing.draw`'s `groups`): the crown at the back, the side tiers from the top down, then the front boughs.
- Every banner is its own small view in `BannerLayer`, over the whole canvas. A gust only turns those views'
  layers (≤12 fps), so a gust never redraws the tree. That's what keeps gusts cheap, and it has to stay that way.
- Placement (`BannerLayout.place` for pennants, `hang` for ribbons) is pure and seeded, run once per change of
  trees, screen or settings (`PlanCache`).

## Occlusion (the new default)

A banner can't simply be painted into the tree canvas at its bough's depth: then every gust frame would redraw
the whole tree (80–105 ms at 32 boughs). Instead each banner keeps its own layer and is **masked** by what's
painted in front of it:

1. **Depth.** The plan records each banner's depth: its place in the tree's paint order, just after its own
   bough (wood, then its twigs and leaves). `Landscape.paintOrder` is the one place that order is decided, so
   the drawing and the banners can't disagree. With up to 4 boughs (one piece of wood, no groups), a bough's
   banners sit behind the later boughs' leaves and twigs, which is what the paint order says too. In an
   orchard each tree is its own depth, left to right.
2. **Occluders.** `Occlusion` holds, for one plan, every stem's wood shape (the same tapered outline the drawing
   makes), its rounded top and its bounds with room for its leaves, in paint order. It's made once per plan.
3. **The mask.** For each banner, a small canvas the size of its view draws everything painted after its depth
   that reaches into that box: the wood filled and its outline stroked, then the twigs, leaves and blossoms with
   the drawing's own code. Every mark is taken to full strength (an alpha threshold), and the result is cut out
   of the banner. Where the banner is cut away, the tree canvas under it shows, and there the bough in front is
   already drawn. A banner with nothing in front of it in its box gets no mask at all. The drawing skips leaves
   and twigs wholly outside the box (`TreeDrawing.only`), using up its random numbers all the same, so the ones
   inside come out exactly as the tree draws them.
4. **Gusts.** The mask is fixed on the screen and the banner turns under it, so a bough in front stays put while
   the banner sways behind it. The mask is drawn once per plan (an equatable view), never per frame.
5. **Mostly hidden names come forward.** At 32 boughs the front boughs' leaves cover the middle of the crown,
   and true occlusion lost whole repository names there (tamarack, yucca, olive, mahogany in the fixtures). So:
   - Ribbons are placed to keep out from behind the crown painted after their own bough: covering it costs twice
     what covering the crown behind does (`BannerLayout.frontWeight`). That alone moved few, as there's often
     no clear spot.
   - A banner whose name would be half or more under the crown in front of its bough (`Landscape.mostlyHidden`,
     estimated from boxes around that crown's wood, leaves and twigs) is drawn in front of everything instead.
   Partly hidden pennants and ribbons still sit behind the leaves in front of them; no name is lost entirely.
   In an orchard or a packed forest, the trees in the rows in front count as the crown in front: a pennant
   that couldn't keep off them comes forward the same way.
6. **Growing in.** The masks are made from the full-grown trees, so a hidden banner on a tree growing in waits
   for every tree growing in to finish before it fades in, rather than show holes for a second where leaves
   in front are still to come. Banners nothing hides fade in with their wood as before.
7. **The setting.** *Draw All Banners in View* (off by default) skips the masks, as today. Placement is the same
   either way, so turning it on or off never moves a banner.

The forest behind the single tree is painted before it, so it never hides the tree's banners.

## Hanging banners (an option, off by default)

*Hang Banners from Boughs*: a branch's pennant hangs from its bough instead of streaming out on a long thread.

- **Placement.** Its hook is just under its tip (a short thread, 6–56 pt), and it dangles from its hoist, a
  seeded 66–80° below level, toward its outward side. Placement keeps the dangling pennant off the other banners
  and the crown, as it does today for streaming ones. A box around a slanting pennant would overstate it by half
  again, so collisions and cover use five boxes along it (`Banner.pieces`); the bounds check uses the whole box.
- **Fewer fit.** A pennant has to hang near its tip, and tips cluster, so far fewer find room than stream out:
  in the fixtures 19–24 of 52 at 8 boughs, 34–42 of 128 at 20, 29–34 of 202 at 32 (streaming: 44–47, 79–82,
  82–84). The rest are rejected for overlapping. Accepted: it's an option, and the ones it shows are the most
  important (the order is the same).
- **Gusts.** The same gust strength (rising and falling over 7 s) lifts it: from dangling to about 12° below
  level at the height of the gust, flapping a little more than today's sway, and it falls back to dangling as
  the gust passes. Still one rotation per banner per frame; only its view is bigger, to hold every pose.
- **Ribbons** already hang from their boughs on cords, so they're unchanged.

## Low banners

In the single tree, no banner (ribbon or pennant) may hang lower than its **floor**: `max(48 pt, 8%)` of the
tree's height above the ground. A banner that would go lower takes another spot (a shorter drop, another anchor
further out along its bough, or the other side); one with no spot at all is left out as before, and a ribbon's
name goes on its bough's trunk pennant. Ribbons get anchors further out along the bough as last resorts, so a
short front bough's ribbon can still find a spot.

## Determinism

Depth, the masks, the dangling angle and the floor are all derived from the layout and seeded names, never time
or order of arrival: the same repositories give the same banners on every redraw.

## Costs

Measured with `--benchmark` (chalk, 32 boughs, 1440×900@2x, median of 3, `ImageRenderer`, so on the CPU and an
overestimate of the screen's cost). The trees take 96–106 ms either way.

- Banners, rendered once: 62 ms all in view; 104 ms with masks (65 of the 107 banners masked); hanging 98 ms
  (34 of 54 masked). Most of a mask's cost is the extra layer; drawing what's in front, culled to the box, is
  about 1 ms. Only when the plan changes.
- A gust frame turns the same layers either way, and redraws neither the tree nor a mask: all in view, 107
  layers and 1.28 Mpt² composited; masked, 107 layers (65 masked) and 2.07 Mpt²; hanging, 54 layers (34
  masked) and 1.17 Mpt². The extra per frame is compositing the masks: about 1.6× the area.

## Tests

- `BannerLayout`: turning a rect; a dangling pennant's footprint and pieces, mirrored to the left; each pennant's
  seeded dangle; hanging pennants hook near their tips, never overlap, stay in bounds; the floor keeps pennants
  above it; the sampled share of a rect under others; a ribbon keeps out from behind what's in front.
- `BackgroundSettings`: both settings default off, persist, and read back.
- Wallpaper: the paint order (crown first, front boughs last); a mask cuts out the wood in front and nothing
  when nothing's in front (rendered); the hanging sway dangles when still and lifts toward level at the height of
  a gust.

## Checks

Renders with the forest study (`--forest`, `GITRASIL_FOREST_OUTPUT=single`) at 8, 20 and 32 boughs, in ink,
charcoal and chalk, light and dark, with each setting. Renders and fixtures stay in the job's temp folder, never
committed; a throwaway defaults suite. `scripts/check.sh` on the final commit.
