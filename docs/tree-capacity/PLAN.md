# Tree capacity — a setting for how many repositories the single tree holds

Task (Daniel, 10 Oct): the Single Tree gets a setting for the most repositories it shows. The main tree takes
that many; with the Forest view on, the rest stand behind it as the Forest. Until now the number was the
display's (`ForestPolicy.treeCapacity(for:)`: 12 on a 900 pt display, 20 from 1440 pt, clamped 8…24), changeable
only for a test run with `GITRASIL_TREE_CAPACITY`. Branch `feat/tree-capacity`, from `origin/main` (55579c8).
Daniel was away, so the calls below were made without him; each is listed in the report to be flipped easily.

## What is there today

- `ForestPolicy.treeCapacity(for:)` decides the tree's share; `fixedTreeCapacity` (the env var) beats it.
- `Landscape.scene` splits the panes: with the Forest on and more panes than the capacity, the tree takes the
  `capacity` highest in `ForestPolicy.rank` (last commit by local day, then the repository's seed/name) and the
  rest go to the forest. The ranking is frozen (`BackgroundModel.ranking`: at launch, every whole-scene grow-in
  and the first hourly tick after local midnight) so a commit never moves a tree.
- **Forest off:** `BackgroundModel.paneLimit` is `plainLimit` = 12, so the pins resolve to 12 repositories at most
  (`PinnedRepositories.resolve`: pin order; a folder fills the slots left, keeping its most recently active
  repositories, shown in name order). The tree then holds all of them; nothing is overflowed to anywhere, the
  rest are not read or drawn. With the Forest on the limit is `paneLimit` = 64 ("the 64 for folders with the
  Forest" of the Crown limits decision), so 12/20/20 + 64 is: tree 12 (900 pt) / 20 (1440 pt) / 20 (ultrawide
  1440 pt), the Forest filling up to 64 in all.
- Settings take effect live: `BackgroundModel.observeSettings` watches them and regrows the scene.

## What it does

1. **Setting** `BackgroundSettings.treeCapacity: Int?`, saved as `treeCapacity`. `nil` — *Automatic*, the default
   — is today's per-display number, so nothing changes for anyone who doesn't touch it. A number is the most
   repositories on the tree, on every display. A saved value outside the allowed range reads as Automatic.
2. **Menu.** A "Repos on the Tree" submenu under Arrange As, after Forest: Automatic, then the steps. Disabled in
   the orchard (the setting is the Single Tree's; it is kept).
3. **Steps and limits.** See *Steps* below, settled by rendering 64 fixtures.
4. **Overflow, Forest on.** Unchanged: the tree takes the first `capacity` in the ranking, the rest are the
   forest. At least as many as the repositories shown: all on the tree, no forest.
5. **Overflow, Forest off.** Today the pane limit (12) cuts the pins before the tree sees them, and the cut is
   by pin order. A chosen capacity under 12 moves that same cut down to it (`min(12, capacity)`), so the tree
   holds the first N by the pins' order, as it holds the first 12 today; more than 12 can't show without the
   Forest, as today. The Automatic setting is untouched (12).
6. **Which stay on the tree.** Forest on: the existing ranking (day of last commit, then name), frozen as
   today, taken again whenever the whole scene grows again, which a capacity change does. Forest off: pin order.
7. **Live.** A change goes through `BackgroundModel.observeSettings` like the Forest toggle: the pane limit
   follows (read more or fewer repositories) and the whole scene grows again.
8. **Env var** `GITRASIL_TREE_CAPACITY` still wins over the setting, for test runs.

## Steps

Automatic, 4, 8, 12, 16, 20, 24 (`ForestPolicy.treeCapacitySteps`; a saved number anywhere in 4…24 is kept).
24 is the ceiling because it is the largest number the display-based rule ever gave (clamped 8…24), so it is a
tree the layout already handled at the height it is tallest for. Rendered with 64 fixtures on 1440×900@2x
(chalk, light) at 4, 8, 12 (the default), 16, 20 and 24, and on 3440×1440 at 8, 16, 24 and the default: every
capacity keeps ribbons on every bough and the forest takes the rest; 24 on the laptop is the densest and still
reads, which is why the range stops there. The default's render matches the one from `origin/main`, and
`GITRASIL_TREE_CAPACITY=24` on `origin/main` matches the setting at 24. With the Forest off and 8 chosen, the
tree holds the first eight pinned and nothing stands behind it.

Below 12 the setting also lowers the Forest-off cut; above 12 without the Forest nothing changes (12 shown), so
16/20/24 do nothing until the Forest is on (the menu's tooltip says so).

## Checks

- Tests: the policy (default unchanged, the chosen number, the env var winning, the range); the settings (default,
  saved, unreadable); the scene split (Forest on: the first N by rank on the tree, the rest in the forest; Forest
  off or fewer panes: all on the tree); the pane limit for each setting.
- Renders: 64 fixtures (`scripts/forest-fixtures.py`), single tree, Forest on, at several settings, offscreen
  only (`--snapshot`), in a throwaway defaults suite.
- `scripts/check.sh` (format, lint, release build with warnings as errors, `swift test`) on the final commit.
