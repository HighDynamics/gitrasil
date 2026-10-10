import SwiftUI
import GitrasilCore

// The forest as layers (docs/forest/PLAN.md): each tree of the forest is a view of its own, sized to
// its crown, that SwiftUI draws once and keeps until the tree itself changes. While trees grow in or a
// limb grows, only those are redrawn each frame, not the sixty others standing still.

/// One tree of the forest, planted: where it stands and the rectangle its view covers.
struct ForestStand: Identifiable {
    let planted: Landscape.Planted
    /// The pane's id (its path): what the live pane is found by.
    let id: String
    let rect: CGRect
}

/// The forest's trees and ground lines for a scene, planned once for as long as its trees, the screen
/// and the ranking stay as they are (`ForestCache`), not on every frame.
final class ForestStands {
    let stands: [ForestStand]
    let grounds: ForestPlan
    /// Changes whenever the forest is planned again, so a layer knows its tree stands somewhere new.
    let generation: Int

    init(stands: [ForestStand], grounds: ForestPlan, generation: Int) {
        self.stands = stands
        self.grounds = grounds
        self.generation = generation
    }
}

/// Keeps the forest planned while nothing that decides it changes.
final class ForestCache {
    private var key: PlanCache.Key?
    private var stands: ForestStands?
    /// Counts the times the scene has been planned again: anything drawn from it is stale once it moves on.
    private(set) var generation = 0

    func stands(for key: PlanCache.Key, make: () -> (stands: [ForestStand], grounds: ForestPlan)?) -> ForestStands? {
        if key != self.key {
            generation += 1
            stands = make().map { ForestStands(stands: $0.stands, grounds: $0.grounds, generation: generation) }
            self.key = key
        }
        return stands
    }
}

extension Landscape {

    /// The forest's trees as layers, back to front; nil when the scene has no forest (a plain orchard,
    /// or a tree that holds everything).
    func forestStands(_ panes: [Pane], arrangement: Arrangement) -> (stands: [ForestStand], grounds: ForestPlan)? {
        let scene = scene(panes, arrangement: arrangement)
        guard !scene.forest.isEmpty else { return nil }
        var crown: CGFloat?
        if isSingleTree(panes, arrangement: arrangement) {
            let (full, frame) = singleTree(scene.tree, narrowed: true)
            crown = CGFloat(full.bounds.width) * frame.scale
        }
        let forest = forestScene(scene.forest, crown: crown)
        let back = forest.planted.sorted { a, b in
            let (x, y) = (a.forest?.line ?? 0, b.forest?.line ?? 0)
            return x != y ? x > y : a.frame.origin.x < b.frame.origin.x
        }
        return (back.map { ForestStand(planted: $0, id: scene.forest[$0.index].id, rect: standRect($0)) }, forest.plan)
    }

    /// The part of the screen a planted tree's drawing can reach: its crown and the leaves around it, its
    /// roots, shadow and name below the ground.
    func standRect(_ planted: Planted) -> CGRect {
        let frame = planted.frame, bounds = planted.full.bounds
        let pad = max(36, style.leafSize * frame.detail * 3)
        let slot = planted.forest?.slot ?? 0
        let left = frame.origin.x + min(CGFloat(bounds.minX) * frame.scale, -slot / 2) - pad
        let right = frame.origin.x + max(CGFloat(bounds.maxX) * frame.scale, slot / 2) + pad
        let top = frame.origin.y - CGFloat(bounds.maxY) * frame.scale - pad
        return CGRect(x: left, y: top, width: right - left, height: frame.origin.y + 80 + pad / 2 - top)
    }
}

/// A forest tree's view: its drawing in a canvas of its own, redrawn only when `pane` (its tree, how far
/// it has grown) or where it stands changes.
struct ForestTreeLayer: View, Equatable {
    let landscape: Landscape
    let stand: ForestStand
    let pane: Pane
    let generation: Int

    static func == (a: ForestTreeLayer, b: ForestTreeLayer) -> Bool {
        a.generation == b.generation && a.stand.id == b.stand.id && a.pane == b.pane
    }

    var body: some View {
        let rect = stand.rect
        Canvas { context, size in
            MainActor.assumeIsolated {
                FrameStats.shared.measure("forest") {
                    Textures.grained(landscape.style, in: &context, size: size) { layer in
                        layer.translateBy(x: -rect.minX, y: -rect.minY)
                        landscape.drawStand(stand.planted, pane: pane, in: &layer)
                    }
                }
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }
}

/// The ground lines behind the front line of the forest: drawn once, as long as the forest is as planned.
struct ForestGroundsLayer: View, Equatable {
    let landscape: Landscape
    let plan: ForestPlan
    let generation: Int

    static func == (a: ForestGroundsLayer, b: ForestGroundsLayer) -> Bool { a.generation == b.generation }

    var body: some View {
        Canvas { context, _ in
            Textures.grained(landscape.style, in: &context, size: landscape.size) { layer in
                landscape.drawForestGrounds(plan, in: &layer)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The main tree (or the orchard) as a layer: redrawn when its own trees or the trunk change, not for
/// every forest tree that grows behind it.
struct MainTreeLayer: View, Equatable {
    let landscape: Landscape
    let panes: [Pane]
    let arrangement: Arrangement
    /// The forest's trees (by id), whose growth this layer doesn't draw.
    let forestIDs: Set<String>
    /// `ForestCache.generation`: the scene it was planned for (its trees, screen, medium and settings).
    let generation: Int

    static func == (a: MainTreeLayer, b: MainTreeLayer) -> Bool {
        a.generation == b.generation && a.landscape.trunkGrowIn == b.landscape.trunkGrowIn && a.panes.count == b.panes.count
            && zip(a.panes, b.panes).allSatisfy { x, y in x == y || a.forestIDs.contains(x.id) && x.id == y.id }
    }

    var body: some View {
        Canvas { context, size in
            MainActor.assumeIsolated {
                FrameStats.shared.measure("trees") {
                    Landscape(style: landscape.style, now: landscape.now, size: size, shuffle: landscape.shuffle,
                              trunkGrowIn: landscape.trunkGrowIn, forest: landscape.forest, policy: landscape.policy, ranking: landscape.ranking,
                              layered: true)
                        .draw(panes, arrangement: arrangement, in: &context)
                }
            }
        }
    }
}
