import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import GitrasilCore

/// Test aids that draw the background offscreen, from the pinned repositories, with no window or
/// menu: `--benchmark` times redraws, `--snapshot <folder>` renders it to images, `--frames <folder>`
/// renders the whole scene growing in, frame by frame. Each waits for the trees to arrive and finish
/// growing in first, and draws exactly what a window would. The settings
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

    /// Every display the aids know. A 5K panel is 2560×1440 points at 2x.
    static let allScreens = [
        Screen(name: "1440×900@2x", size: CGSize(width: 1440, height: 900), scale: 2),
        Screen(name: "3440×1440@1x", size: CGSize(width: 3440, height: 1440), scale: 1),
        Screen(name: "5120×2880@2x", size: CGSize(width: 2560, height: 1440), scale: 2)
    ]

    /// The displays `--benchmark`, `--snapshot` and `--frames` use: the first two, or the ones
    /// GITRASIL_OFFSCREEN_SCREENS lists by index (`0,2`).
    static let screens: [Screen] = {
        let chosen = ProcessInfo.processInfo.environment["GITRASIL_OFFSCREEN_SCREENS"]?
            .split(separator: ",").compactMap { Int($0) }.filter { allScreens.indices.contains($0) }
        return chosen.map { $0.map { allScreens[$0] } } ?? Array(allScreens.prefix(2))
    }()

    /// GITRASIL_OFFSCREEN_MEDIA (`chalk,ink`) and GITRASIL_OFFSCREEN_ARRANGEMENTS (`orchard`) narrow
    /// what `--benchmark` and `--snapshot` run; GITRASIL_OFFSCREEN_MODES (`light`) picks the mode.
    static func chosen<T: RawRepresentable & CaseIterable>(_ variable: String, _ all: T.Type) -> [T] where T.RawValue == String {
        guard let list = ProcessInfo.processInfo.environment[variable] else { return Array(T.allCases) }
        let names = Set(list.split(separator: ",").map(String.init))
        return T.allCases.filter { names.contains($0.rawValue) }
    }

    static var modes: [Bool] {
        switch ProcessInfo.processInfo.environment["GITRASIL_OFFSCREEN_MODES"] {
        case "light": return [false]
        case "dark": return [true]
        default: return [false, true]
        }
    }

    /// Times each part of a redraw, rendered to a bitmap (`ImageRenderer`, so on the CPU), `runs`
    /// times after a warm-up, and prints the median: the tree canvas (what redraws when a tree
    /// changes), one frame of it growing in (every tree halfway, a shared trunk risen), the paper
    /// under it, and the banners (each drawn once into its own layer; a gust only turns them).
    static func benchmark(_ background: BackgroundModel, runs: Int) async {
        await settle(background)
        print("redraw, median of \(runs) (ms):")
        for arrangement in chosen("GITRASIL_OFFSCREEN_ARRANGEMENTS", Arrangement.self) {
            background.settings.arrangement = arrangement
            await settle(background)
            for medium in chosen("GITRASIL_OFFSCREEN_MEDIA", Medium.self) {
                for screen in screens {
                    for dark in modes {
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
        for arrangement in chosen("GITRASIL_OFFSCREEN_ARRANGEMENTS", Arrangement.self) {
            background.settings.arrangement = arrangement
            await settle(background)
            for medium in chosen("GITRASIL_OFFSCREEN_MEDIA", Medium.self) {
                background.settings.medium = medium
                for dark in modes {
                    let name = "\(medium.rawValue)-\(arrangement == .singleTree ? "single-tree" : "orchard")-\(dark ? "dark" : "light")"
                    let url = folder.appendingPathComponent("\(name).jpg")
                    guard let image = render(WallpaperView(background: background), screen: screen, dark: dark) else { continue }
                    write(image, to: url)
                    print("wrote \(url.path)")
                }
            }
        }
    }

    /// Grows the whole scene again (as Watch Gitrasil Grow does) and renders it `fps` times a second
    /// of its clock, from the bare ground to a moment after the last name, as `frame-NNN.jpg` in
    /// `folder`, for the first screen, in the saved arrangement and medium. The frames are drawn at
    /// their own pace, so the clock is kept (`GrowInClock`) rather than read live.
    static func frames(_ background: BackgroundModel, to folder: URL, fps: Double = 20) async {
        await settle(background)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        background.regrow()
        let clock = background.growInClock
        guard let span = clock.span else { return print("nothing to grow") }
        let screen = screens[0], dark = NSApp.appearance?.name == .darkAqua
        let style = WallpaperStyle.make(background.settings.medium, dark: dark)
        let plan = Landscape(style: style, now: background.now, size: screen.size, shuffle: background.settings.layoutSeed,
                             trunkGrowIn: nil, forest: background.settings.forest, policy: background.policy)
            .plan(panes(background), arrangement: background.settings.arrangement,
                  branchNames: background.settings.showsBranchNames, repoNames: background.settings.showsRepoNames)
        let count = Int(ceil(span.upperBound.timeIntervalSince(span.lowerBound) * fps)) + Int(fps / 2)
        for index in 0...count {
            let date = span.lowerBound.addingTimeInterval(Double(index) / fps)
            let shown = WallpaperView.shownBanners(plan, panes: background.panes, at: date, growIn: clock.growIn)
            let view = ZStack {
                paperCanvas(background, style: style)
                treeCanvas(background, style: style, clock: clock, at: date)
                BannerLayer(plan: plan, shown: shown, style: style, breeze: background.breeze)
            }
            guard let image = render(view, screen: screen, dark: dark) else { continue }
            write(image, to: folder.appendingPathComponent(String(format: "frame-%03d.jpg", index)))
        }
        print("wrote \(count + 1) frames (\(Int(fps)) fps) to \(folder.path)")
    }

    // MARK: Parts

    static func panes(_ background: BackgroundModel) -> [Pane] {
        zip(background.panes, PinnedRepositories.seeds(background.panes.map(\.repoURL))).map { Pane($0, seed: $1) }
    }

    /// The trees, as they stand or `growIn` of the way through growing in.
    static func treeCanvas(_ background: BackgroundModel, style: WallpaperStyle, growIn: Double? = nil) -> some View {
        let panes = zip(background.panes, PinnedRepositories.seeds(background.panes.map(\.repoURL))).map {
            Pane($0, seed: $1, growIn: growIn)
        }
        let arrangement = background.settings.arrangement, now = background.now, shuffle = background.settings.layoutSeed
        return Canvas { context, size in
            Landscape(style: style, now: now, size: size, shuffle: shuffle, trunkGrowIn: growIn.map { _ in 1 },
                      forest: background.settings.forest, policy: background.policy)
                .draw(panes, arrangement: arrangement, in: &context)
        }
    }

    /// The trees at `date` of a grow-in.
    static func treeCanvas(_ background: BackgroundModel, style: WallpaperStyle, clock: BackgroundModel.GrowInClock,
                           at date: Date) -> some View {
        let panes = zip(background.panes, PinnedRepositories.seeds(background.panes.map(\.repoURL))).map {
            Pane($0, seed: $1, growIn: clock.growIn($0.repoURL, at: date))
        }
        let arrangement = background.settings.arrangement, now = background.now, shuffle = background.settings.layoutSeed
        let trunkGrowIn = clock.trunkGrowIn(at: date)
        return Canvas { context, size in
            Landscape(style: style, now: now, size: size, shuffle: shuffle, trunkGrowIn: trunkGrowIn,
                      forest: background.settings.forest, policy: background.policy)
                .draw(panes, arrangement: arrangement, in: &context)
        }
    }

    static func paperCanvas(_ background: BackgroundModel, style: WallpaperStyle) -> some View {
        Canvas { context, size in
            WallpaperView.drawPaper(size: size, style: style, ground: true, in: &context)
        }
    }

    static func bannerLayer(_ background: BackgroundModel, style: WallpaperStyle, size: CGSize) -> some View {
        let plan = Landscape(style: style, now: background.now, size: size, shuffle: background.settings.layoutSeed,
                             trunkGrowIn: nil, forest: background.settings.forest, policy: background.policy)
            .plan(panes(background), arrangement: background.settings.arrangement,
                  branchNames: background.settings.showsBranchNames, repoNames: background.settings.showsRepoNames)
        return BannerLayer(plan: plan, shown: [:], style: style, breeze: background.breeze)
    }

    // MARK: Rendering

    static func render(_ view: some View, screen: Screen, dark: Bool) -> CGImage? {
        let renderer = ImageRenderer(content: view
            .frame(width: screen.size.width, height: screen.size.height)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = screen.scale
        return renderer.cgImage
    }

    /// The median time of `make`, in milliseconds, after one warm-up.
    static func median(_ runs: Int, _ make: () -> CGImage?) -> Double {
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

    static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    /// Until every pane has its tree (or a problem) and nothing is growing in.
    static func settle(_ background: BackgroundModel) async {
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
