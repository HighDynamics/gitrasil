import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import GitrasilCore

/// Test aids that draw the background offscreen, from the pinned repositories, with no window or
/// menu: `--benchmark` times redraws, `--snapshot <folder>` renders it to images. Both wait for the
/// trees to arrive and finish growing in first, and draw exactly what a window would. The settings
/// they change as they go are a copy (`MemorySettings`, made in `main.swift`): a run never writes the
/// saved ones.
@MainActor
enum Offscreen {

    /// A screen to draw for: its size in points and its scale.
    struct Screen {
        let name: String
        let size: CGSize
        let scale: CGFloat
    }

    static let screens = [
        Screen(name: "1440×900@2x", size: CGSize(width: 1440, height: 900), scale: 2),
        Screen(name: "3440×1440@1x", size: CGSize(width: 3440, height: 1440), scale: 1),
    ]

    /// Times each part of a redraw, rendered to a bitmap (`ImageRenderer`, so on the CPU), `runs`
    /// times after a warm-up, and prints the median: the tree canvas (what redraws when a tree
    /// changes), one frame of it growing in (every tree halfway, a shared trunk risen), the paper
    /// under it, and the banners (each drawn once into its own layer; a gust only turns them).
    static func benchmark(_ background: BackgroundModel, runs: Int) async {
        await settle(background)
        print("redraw, median of \(runs) (ms):")
        for arrangement in Arrangement.allCases {
            background.settings.arrangement = arrangement
            await settle(background)
            for medium in Medium.allCases {
                for screen in screens {
                    for dark in [false, true] {
                        let style = WallpaperStyle.make(medium, dark: dark)
                        let trees = median(runs) { render(treeCanvas(background, style: style), screen: screen, dark: dark) }
                        let frame = median(runs) { render(treeCanvas(background, style: style, growIn: 0.5), screen: screen, dark: dark) }
                        let paper = median(runs) { render(paperCanvas(background, style: style), screen: screen, dark: dark) }
                        let banners = median(runs) { render(bannerLayer(background, style: style, size: screen.size),
                                                            screen: screen, dark: dark) }
                        print(String(format: "  %@ %@ %@ %@: trees %.1f, grow-in frame %.1f, paper %.1f, banners %.1f",
                                     medium.rawValue, arrangement.rawValue, screen.name, dark ? "dark" : "light",
                                     trees, frame, paper, banners))
                    }
                }
            }
        }
    }

    /// Renders the whole background (paper, trees, banners) in each medium and arrangement, light and
    /// dark, as `<medium>-<arrangement>-<light|dark>.jpg` in `folder`, for the first screen.
    static func snapshot(_ background: BackgroundModel, to folder: URL) async {
        await settle(background)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let screen = screens[0]
        for arrangement in Arrangement.allCases {
            background.settings.arrangement = arrangement
            await settle(background)
            for medium in Medium.allCases {
                background.settings.medium = medium
                for dark in [false, true] {
                    let name = "\(medium.rawValue)-\(arrangement == .singleTree ? "single-tree" : "orchard")-\(dark ? "dark" : "light")"
                    let url = folder.appendingPathComponent("\(name).jpg")
                    guard let image = render(WallpaperView(background: background), screen: screen, dark: dark) else { continue }
                    write(image, to: url)
                    print("wrote \(url.path)")
                }
            }
        }
    }

    // MARK: Parts

    private static func panes(_ background: BackgroundModel) -> [Pane] {
        zip(background.panes, PinnedRepositories.seeds(background.panes.map(\.repoURL))).map { Pane($0, seed: $1) }
    }

    /// The trees, as they stand or `growIn` of the way through growing in.
    private static func treeCanvas(_ background: BackgroundModel, style: WallpaperStyle, growIn: Double? = nil) -> some View {
        let panes = zip(background.panes, PinnedRepositories.seeds(background.panes.map(\.repoURL))).map {
            Pane($0, seed: $1, growIn: growIn)
        }
        let arrangement = background.settings.arrangement, now = background.now
        return Canvas { context, size in
            Landscape(style: style, now: now, size: size, trunkGrowIn: growIn.map { _ in 1 })
                .draw(panes, arrangement: arrangement, in: &context)
        }
    }

    private static func paperCanvas(_ background: BackgroundModel, style: WallpaperStyle) -> some View {
        Canvas { context, size in
            WallpaperView.drawPaper(size: size, style: style, ground: true, in: &context)
        }
    }

    private static func bannerLayer(_ background: BackgroundModel, style: WallpaperStyle, size: CGSize) -> some View {
        let plan = Landscape(style: style, now: background.now, size: size, trunkGrowIn: nil)
            .plan(panes(background), arrangement: background.settings.arrangement,
                  branchNames: background.settings.showsBranchNames, repoNames: background.settings.showsRepoNames)
        return BannerLayer(plan: plan, shown: [:], style: style, breeze: background.breeze)
    }

    // MARK: Rendering

    private static func render(_ view: some View, screen: Screen, dark: Bool) -> CGImage? {
        let renderer = ImageRenderer(content: view
            .frame(width: screen.size.width, height: screen.size.height)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = screen.scale
        return renderer.cgImage
    }

    /// The median time of `make`, in milliseconds, after one warm-up.
    private static func median(_ runs: Int, _ make: () -> CGImage?) -> Double {
        _ = make()
        var times: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            // Reading a pixel makes sure the image is really drawn, not just described.
            _ = make().flatMap { $0.dataProvider?.data }.map(CFDataGetLength)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        return times.sorted()[times.count / 2]
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    /// Until every pane has its tree (or a problem) and nothing is growing in.
    private static func settle(_ background: BackgroundModel) async {
        // A change of arrangement starts its grow-in on the next turn.
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<600 {
            let ready = background.panes.allSatisfy { $0.tree != nil || $0.problem != nil }
            if ready, !background.isAwaitingTrees, !background.isGrowingIn,
               background.panes.allSatisfy({ $0.growthStart == nil }) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(200))
    }
}
