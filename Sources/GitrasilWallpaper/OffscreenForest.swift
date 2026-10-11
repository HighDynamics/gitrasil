import AppKit
import SwiftUI
import GitrasilCore

/// The forest study (docs/forest/PLAN.md): `--forest <folder>` draws N of the pinned repositories as the
/// background would, on each display, and writes the numbers (`forest.csv`) and, as asked, a picture each.
/// Test aid like the others: offscreen, nothing saved. Chosen by environment:
///
/// - GITRASIL_FOREST_COUNTS (`4,8,16`), GITRASIL_OFFSCREEN_SCREENS (`0,1,2`, default all three)
/// - GITRASIL_FOREST_ARRANGEMENT: `tree` (the default: a single tree, a forest behind it for the
///   rest) or `orchard`
/// - GITRASIL_FOREST_OUTPUT: `single` for a picture each (default none: the numbers only)
/// - GITRASIL_FOREST_PLAIN, GITRASIL_TREE_CAPACITY, GITRASIL_FOREST_BESIDE, GITRASIL_FOREST_HEIGHT: the
///   policy's numbers (`ForestPolicy`, `Landscape.besideHeight`)
@MainActor
extension Offscreen {

    static func forest(_ background: BackgroundModel, to folder: URL) async {
        let environment = ProcessInfo.processInfo.environment
        let counts = (environment["GITRASIL_FOREST_COUNTS"] ?? "4,8,12,16,20,24,32,48,64").split(separator: ",").compactMap { Int($0) }
        let displays = environment["GITRASIL_OFFSCREEN_SCREENS"].map { list in
            list.split(separator: ",").compactMap { Int($0) }.filter { allScreens.indices.contains($0) }.map { allScreens[$0] }
        } ?? allScreens
        let arrangement: Arrangement = environment["GITRASIL_FOREST_ARRANGEMENT"] == "orchard" ? .orchard : .singleTree
        let output = environment["GITRASIL_FOREST_OUTPUT"] ?? ""
        let dark = NSApp.appearance?.name == .darkAqua
        await settle(background)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let everyone = panes(background)
        let style = WallpaperStyle.make(background.settings.medium, dark: dark)
        var csv = "n,screen,arrangement,onTree,inForest,treeScale,crownPx,forestScale,forestLines,ribbons,"
            + "pennantsWanted,pennantsPlaced,planMs,drawMs\n"
        for screen in displays {
            for count in counts where count <= everyone.count {
                let chosen = sample(everyone, count)
                let landscape = Landscape(style: style, now: background.now, size: screen.size, shuffle: background.settings.layoutSeed,
                                          trunkGrowIn: nil, forest: background.settings.forest, policy: background.policy)
                let scene = landscape.scene(chosen, arrangement: arrangement)
                var treeScale: CGFloat = 0, crown: CGFloat = 0, wanted = 0
                if landscape.isSingleTree(chosen, arrangement: arrangement) {
                    let (full, frame) = landscape.singleTree(scene.tree, narrowed: !scene.forest.isEmpty)
                    treeScale = frame.scale
                    crown = CGFloat(full.bounds.width) * frame.scale
                    wanted = full.boughs.reduce(0) { $0 + $1.layout.stems.filter { $0.name != nil && $0.tip != nil }.count }
                }
                var forestScale: CGFloat = 0, forestLines = 0
                if !scene.forest.isEmpty {
                    let plan = landscape.forestScene(scene.forest, crown: crown > 0 ? crown : nil).plan
                    forestScale = plan.scale
                    forestLines = plan.lines
                }
                let start = DispatchTime.now().uptimeNanoseconds
                let banners = landscape.plan(chosen, arrangement: arrangement, branchNames: true, repoNames: true,
                                             hanging: background.settings.hangsBanners,
                                             occluded: !background.settings.drawsAllBannersInView)
                let planMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                let canvas = Canvas { context, _ in landscape.draw(chosen, arrangement: arrangement, in: &context) }
                let drawMs = median(3) { render(canvas, screen: screen, dark: dark) }
                let row = [String(count), screen.name, arrangement.rawValue, String(scene.tree.count), String(scene.forest.count),
                           f1(treeScale), f1(crown), f1(forestScale), String(forestLines), String(banners.ribbons.count), String(wanted),
                           String(banners.banners.count), f1(planMs), f1(drawMs)].joined(separator: ",")
                csv += row + "\n"
                let named = Set(banners.ribbons.map(\.pane))
                let unnamed = scene.tree.filter { !named.contains($0.id) }.map(\.name)
                if !unnamed.isEmpty { print("    no ribbon: \(unnamed.joined(separator: ", "))") }
                let hidden = banners.ribbons.filter { $0.hiddenFrom != nil }.count + banners.banners.filter { $0.hiddenFrom != nil }.count
                print("  N=\(count) \(screen.name) tree \(scene.tree.count) forest \(scene.forest.count) · tree \(f1(treeScale)) px/unit "
                      + "crown \(f1(crown)) · forest \(f1(forestScale)) px/unit \(forestLines) lines · ribbons \(banners.ribbons.count) "
                      + "pennants \(banners.banners.count)/\(wanted) · hidden \(hidden) · plan \(f1(planMs)) ms draw \(f1(drawMs)) ms")
                if output.contains("single") {
                    let view = ZStack {
                        paperCanvas(background, style: style)
                        canvas
                        BannerLayer(plan: banners, shown: [:], style: style, breeze: background.breeze)
                    }
                    if let image = render(view, screen: screen, dark: dark) {
                        write(image, to: folder.appendingPathComponent("forest-n\(count)-\(slug(screen)).jpg"))
                    }
                }
            }
        }
        try? csv.write(to: folder.appendingPathComponent("forest.csv"), atomically: true, encoding: .utf8)
        print("wrote \(folder.path)")
    }

    /// `count` of `panes`, spread evenly through them, so every folder keeps its share.
    static func sample(_ panes: [Pane], _ count: Int) -> [Pane] {
        guard count < panes.count else { return panes }
        return (0..<count).map { panes[Int(Double($0) * Double(panes.count) / Double(count))] }
    }

    static func slug(_ screen: Screen) -> String { screen.name.replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: "@", with: "-") }
    static func f1(_ v: some BinaryFloatingPoint) -> String { String(format: "%.1f", Double(v)) }
}

/// How a repository's name fits the room its neighbours leave under its tree.
enum PlateFit {
    case across(CGFloat)
    case down(CGFloat)
    case none

    /// Whole (scaled down to half its size at most) when it fits across; down the ground at a small
    /// fixed size when the room is narrow; left out when even that would be too small to read.
    static func of(width: CGFloat, height: CGFloat, slot: CGFloat) -> PlateFit {
        guard width > 0 else { return .none }
        let across = slot * 0.94 / width
        if across >= 0.5 { return .across(min(across, 1)) }
        let k = min(0.4, slot * 0.8 / height)
        return height * k >= 7.5 ? .down(k) : .none
    }
}
