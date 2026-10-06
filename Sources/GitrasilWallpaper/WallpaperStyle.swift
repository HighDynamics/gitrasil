import AppKit
import SwiftUI
import GitrasilCore

/// Everything about how the wallpaper looks, as one value: the drawing code reads only this, so a
/// new look is a new `WallpaperStyle`, not a new view.
struct WallpaperStyle {

    // MARK: Paper

    /// The background, top-left to bottom-right.
    var paper: [Color]
    /// A soft wash behind the trees (clear for none).
    var wash: Color
    /// Faint fibres scattered over the paper (clear for none): a seeded, fixed texture.
    var fibre: Color

    // MARK: Ink

    /// The wood (trunk and the base of every limb), the ground, and text that belongs to no branch.
    var ink: Color
    /// Branch inks, for a limb's tip, its leaves and its name; a branch keeps one for life, picked by
    /// a stable hash of its name.
    var branchInks: [Color]
    /// The trunk's own leaves.
    var leafInk: Color
    /// Quiet text: the hint, a pane's problem.
    var captionInk: Color

    // MARK: Strokes

    /// A pen line: the ground, leaf outlines and veins.
    var lineWidth: CGFloat
    /// How far a hand-drawn line strays from straight, in points (0 for ruled lines).
    var wobble: CGFloat
    /// How solid the wood is drawn.
    var woodOpacity: Double
    /// Light streaks through the wood, like a dry brush (0 for none).
    var barkOpacity: Double

    // MARK: Foliage

    /// A fresh leaf's fill; its outline is drawn stronger.
    var leafOpacity: Double
    /// A leaf's length in points, before its seeded variation.
    var leafSize: CGFloat
    /// The soft wash of a branch's ink behind its tip's leaves (0 for none).
    var canopyOpacity: Double
    /// Older commits fade: opacity halves every `fadeHalfLife` days, down to `fadeFloor`.
    var fadeHalfLife: Double
    var fadeFloor: Double

    // MARK: Type

    /// Branch names at the tips, at a given point size (scaled with the tree).
    var labelFont: (CGFloat) -> Font
    /// The same face for measuring a name before it's drawn (to size its banner).
    var labelMetricsFont: (CGFloat) -> NSFont
    var labelSize: CGFloat
    /// A repository's name on its ribbon in the single tree: larger and more formal than a branch's.
    var ribbonFont: (CGFloat) -> Font
    var ribbonMetricsFont: (CGFloat) -> NSFont
    var ribbonSize: CGFloat
    var captionFont: Font
    /// The repository's name under its tree.
    var plateFont: Font
    var plateOpacity: Double

    /// A branch's ink, from its name alone: the same branch name is the same ink in every repository,
    /// on every redraw and launch (FNV-1a with a final mix, not Swift's seeded hash). Two branches
    /// can share an ink when their names hash alike.
    func ink(forBranch branch: String) -> Color {
        guard !branchInks.isEmpty else { return ink }
        return branchInks[Self.inkSlot(forBranch: branch, count: branchInks.count)]
    }

    static func inkSlot(forBranch branch: String, count: Int) -> Int {
        Int(SeededRandom.hash(branch) % UInt64(count))
    }

    /// How strongly a commit made `ageDays` ago is drawn.
    func opacity(ageDays: Double) -> Double {
        guard fadeHalfLife > 0 else { return 1 }
        return max(fadeFloor, pow(0.5, max(ageDays, 0) / fadeHalfLife))
    }
}

extension WallpaperStyle {

    /// Ink on cream: a brush-ink tree on warm paper, each branch's tip, leaves and name in its own
    /// ink, older commits fading. In dark mode the paper turns to a warm charcoal and the inks lighten.
    static func inkOnCream(dark: Bool) -> WallpaperStyle {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
        return WallpaperStyle(
            paper: dark ? [rgb(34, 31, 28), rgb(28, 26, 24), rgb(23, 21, 20)]
                        : [rgb(248, 242, 228), rgb(243, 235, 217), rgb(236, 226, 205)],
            wash: dark ? rgb(70, 60, 48).opacity(0.25) : rgb(255, 250, 238).opacity(0.7),
            fibre: dark ? rgb(120, 110, 95).opacity(0.10) : rgb(150, 125, 90).opacity(0.10),
            ink: dark ? rgb(222, 212, 192) : rgb(52, 44, 38),
            branchInks: dark
                ? [rgb(110, 170, 220), rgb(220, 120, 100), rgb(120, 190, 140), rgb(200, 150, 220),
                   rgb(225, 180, 90), rgb(100, 190, 190), rgb(230, 140, 170), rgb(170, 180, 110)]
                : [rgb(40, 90, 150), rgb(170, 60, 45), rgb(50, 120, 75), rgb(120, 70, 150),
                   rgb(175, 115, 25), rgb(30, 120, 125), rgb(165, 55, 105), rgb(105, 110, 40)],
            leafInk: dark ? rgb(150, 170, 120) : rgb(95, 110, 60),
            captionInk: dark ? rgb(222, 212, 192).opacity(0.55) : rgb(52, 44, 38).opacity(0.6),
            lineWidth: 1.1,
            wobble: 1.3,
            woodOpacity: dark ? 0.62 : 0.9,
            barkOpacity: dark ? 0.22 : 0.30,
            leafOpacity: dark ? 0.55 : 0.5,
            leafSize: 15,
            canopyOpacity: dark ? 0.11 : 0.10,
            fadeHalfLife: 14,
            fadeFloor: 0.22,
            labelFont: { .custom("Bradley Hand", size: $0) },
            labelMetricsFont: { NSFont(name: "Bradley Hand", size: $0) ?? .systemFont(ofSize: $0) },
            labelSize: 15,
            ribbonFont: { .custom("SnellRoundhand-Bold", size: $0) },
            ribbonMetricsFont: { NSFont(name: "SnellRoundhand-Bold", size: $0) ?? .systemFont(ofSize: $0) },
            ribbonSize: 27,
            captionFont: .custom("Baskerville", size: 12).italic(),
            plateFont: .custom("Snell Roundhand", size: 34),
            plateOpacity: dark ? 0.35 : 0.42)
    }
}
