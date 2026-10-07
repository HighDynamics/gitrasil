import AppKit
import SwiftUI
import GitrasilCore

/// Everything about how the wallpaper looks, as one value: the drawing code reads only this, so a
/// new look is a new `WallpaperStyle`, not a new view.
struct WallpaperStyle {

    /// What it's drawn in, for the textures (`Textures`).
    var medium: Medium

    // MARK: Paper

    /// The background, top-left to bottom-right.
    var paper: [Color]
    /// A soft wash behind the trees (clear for none).
    var wash: Color
    /// Faint fibres scattered over the paper (clear for none): a seeded, fixed texture.
    var fibre: Color
    /// How strongly the medium's surface shows over the paper: charcoal paper's tooth, a chalk
    /// board's dust (0 for none).
    var surface: Double
    /// Old erasing on a chalk board: broad faint smears (clear for none).
    var smear: Color

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
    /// How far the ground line strays from straight, in points (0 for ruled lines).
    var wobble: CGFloat
    /// How much every other line strays and swells as a hand draws it: 1 for the ink's, more for a
    /// looser hand, 0 for true lines (GITRASIL_BACKGROUND_WOBBLE=off).
    var hand: CGFloat
    /// How many times an outline is gone over: a sketch's second pass.
    var passes: Int
    /// How much of every stroke the grain takes away (0 for none): the medium caught only on the
    /// paper's tooth.
    var grain: Double
    /// How solid the wood is drawn.
    var woodOpacity: Double
    /// The wood laid down stroke by stroke, so it's stronger where strokes overlap, rather than as one
    /// even layer.
    var layeredWood: Bool
    /// How much the wood's strength rises and falls along a stem, like a hand's pressure (0 for even).
    var pressure: Double
    /// The wood's edges drawn as lines: their opacity (0 for none) and width.
    var contour: Double
    var contourWidth: CGFloat
    /// Streaks through the wood, like a dry brush (0 for none): light, in the paper's colour, or in
    /// the medium itself.
    var barkOpacity: Double
    var streaksInInk: Bool
    /// A soft smudge of the medium beside the wood: charcoal rubbed, chalk dust (0 for none).
    var smudge: Double

    // MARK: Foliage

    /// A fresh leaf's fill, and its outline (drawn stronger).
    var leafOpacity: Double
    var leafLine: Double
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

    /// What a banner's drawing depends on, beyond its name: so a new medium or mode redraws it.
    var bannerKey: [AnyHashable] { [medium, paper, ink, hand] }
}

extension WallpaperStyle {

    /// The look for `medium`, in light or dark mode. GITRASIL_BACKGROUND_WOBBLE=off draws every line
    /// true; the ink is then exactly the ink from before the hand-drawn wobble.
    static func make(_ medium: Medium, dark: Bool) -> WallpaperStyle {
        var style: WallpaperStyle
        switch medium {
        case .ink: style = inkOnCream(dark: dark)
        case .charcoal: style = charcoal(dark: dark)
        case .chalk: style = chalk(dark: dark)
        }
        if !handDrawn { style.hand = 0 }
        return style
    }

    static let handDrawn = ProcessInfo.processInfo.environment["GITRASIL_BACKGROUND_WOBBLE"] != "off"

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    /// Ink on cream: a brush-ink tree on warm paper, each branch's tip, leaves and name in its own
    /// ink, older commits fading. In dark mode the paper turns to a warm charcoal and the inks lighten.
    static func inkOnCream(dark: Bool) -> WallpaperStyle {
        WallpaperStyle(
            medium: .ink,
            paper: dark ? [rgb(34, 31, 28), rgb(28, 26, 24), rgb(23, 21, 20)]
                        : [rgb(248, 242, 228), rgb(243, 235, 217), rgb(236, 226, 205)],
            wash: dark ? rgb(70, 60, 48).opacity(0.25) : rgb(255, 250, 238).opacity(0.7),
            fibre: dark ? rgb(120, 110, 95).opacity(0.10) : rgb(150, 125, 90).opacity(0.10),
            surface: 0,
            smear: .clear,
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
            hand: 1,
            passes: 1,
            grain: 0,
            woodOpacity: dark ? 0.62 : 0.9,
            layeredWood: false,
            pressure: 0,
            contour: 0,
            contourWidth: 0,
            barkOpacity: dark ? 0.22 : 0.30,
            streaksInInk: false,
            smudge: 0,
            leafOpacity: dark ? 0.55 : 0.5,
            leafLine: 0.85,
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

    /// Charcoal on warm paper with a tooth: the wood laid down in grainy, soft-edged strokes, darker
    /// where they overlap, its pressure rising and falling along each stem, a little smudged; the
    /// branches in coloured charcoal and pastel, muted from the inks. In dark mode, white charcoal and
    /// pastel on a dark toned paper.
    static func charcoal(dark: Bool) -> WallpaperStyle {
        var style = inkOnCream(dark: dark)
        style.medium = .charcoal
        style.paper = dark ? [rgb(60, 51, 44), rgb(50, 43, 37), rgb(41, 35, 30)]
                           : [rgb(240, 234, 222), rgb(233, 226, 212), rgb(224, 216, 200)]
        style.wash = dark ? rgb(92, 78, 64).opacity(0.22) : rgb(250, 246, 236).opacity(0.55)
        style.fibre = dark ? rgb(120, 112, 100).opacity(0.06) : rgb(140, 120, 95).opacity(0.06)
        style.surface = dark ? 0.55 : 0.5
        style.ink = dark ? rgb(226, 218, 204) : rgb(38, 36, 35)
        style.branchInks = dark
            ? [rgb(142, 172, 202), rgb(212, 146, 126), rgb(150, 188, 152), rgb(182, 160, 204),
               rgb(214, 186, 128), rgb(132, 186, 184), rgb(210, 152, 172), rgb(182, 182, 132)]
            : [rgb(68, 98, 138), rgb(158, 82, 66), rgb(76, 116, 86), rgb(112, 88, 134),
               rgb(168, 124, 62), rgb(58, 114, 118), rgb(148, 80, 108), rgb(108, 110, 64)]
        style.leafInk = dark ? rgb(160, 176, 136) : rgb(98, 110, 76)
        style.captionInk = style.ink.opacity(dark ? 0.55 : 0.6)
        style.lineWidth = 1.3
        style.hand = 1.25
        style.passes = 2
        style.grain = dark ? 0.55 : 0.62
        style.woodOpacity = dark ? 0.56 : 0.8
        style.layeredWood = true
        style.pressure = 0.35
        style.contour = dark ? 0.55 : 0.7
        style.contourWidth = 1.6
        style.barkOpacity = dark ? 0.3 : 0.4
        style.streaksInInk = true
        style.smudge = dark ? 0.05 : 0.07
        style.leafOpacity = dark ? 0.5 : 0.45
        style.leafLine = 0.6
        style.canopyOpacity = dark ? 0.12 : 0.11
        return style
    }

    /// Chalk on a board: white chalk for the wood, laid on lightly with strong edges and dry streaks,
    /// coloured chalks for the branches, every stroke broken by the board's grain and leaving a little
    /// dust. Always on a board, since chalk on a light ground reads as a smudge: a green-grey
    /// classroom slate in light mode, a near-black slate in dark mode.
    static func chalk(dark: Bool) -> WallpaperStyle {
        var style = inkOnCream(dark: dark)
        style.medium = .chalk
        style.paper = dark ? [rgb(38, 42, 43), rgb(31, 35, 36), rgb(25, 28, 29)]
                           : [rgb(58, 74, 66), rgb(50, 65, 58), rgb(43, 57, 51)]
        style.wash = dark ? rgb(80, 88, 88).opacity(0.18) : rgb(96, 116, 104).opacity(0.35)
        style.fibre = .clear
        style.surface = dark ? 0.5 : 0.6
        style.smear = rgb(225, 228, 220).opacity(dark ? 0.014 : 0.018)
        style.ink = rgb(236, 234, 226)
        style.branchInks = [rgb(140, 192, 236), rgb(240, 152, 132), rgb(162, 216, 150), rgb(202, 172, 236),
                            rgb(246, 212, 122), rgb(132, 216, 210), rgb(242, 162, 196), rgb(206, 216, 140)]
        style.leafInk = rgb(176, 206, 146)
        style.captionInk = rgb(236, 234, 226).opacity(0.6)
        style.lineWidth = 1.4
        style.hand = 1.35
        style.passes = 2
        style.grain = 0.8
        style.woodOpacity = dark ? 0.34 : 0.4
        style.layeredWood = true
        style.pressure = 0.4
        style.contour = 0.85
        style.contourWidth = 1.7
        style.barkOpacity = 0.45
        style.streaksInInk = true
        style.smudge = 0.05
        style.leafOpacity = 0.4
        style.leafLine = 0.9
        style.canopyOpacity = 0.08
        style.labelFont = { .custom("ChalkboardSE-Regular", size: $0) }
        style.labelMetricsFont = { NSFont(name: "ChalkboardSE-Regular", size: $0) ?? .systemFont(ofSize: $0) }
        style.labelSize = 14
        style.ribbonFont = { .custom("Chalkduster", size: $0) }
        style.ribbonMetricsFont = { NSFont(name: "Chalkduster", size: $0) ?? .systemFont(ofSize: $0) }
        style.ribbonSize = 22
        style.captionFont = .custom("ChalkboardSE-Regular", size: 12)
        style.plateFont = .custom("Chalkduster", size: 28)
        style.plateOpacity = 0.5
        return style
    }
}
