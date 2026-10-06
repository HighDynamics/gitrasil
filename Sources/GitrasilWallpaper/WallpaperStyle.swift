import SwiftUI

/// Everything about how the wallpaper looks, as one value: the drawing code reads only this, so a
/// new look is a new `WallpaperStyle`, not a new view.
struct WallpaperStyle {

    // MARK: Paper

    /// The background, top-left to bottom-right.
    var paper: [Color]
    /// A soft wash behind the graph (clear for none).
    var wash: Color
    /// Faint fibres scattered over the paper (clear for none): a seeded, fixed texture.
    var fibre: Color

    // MARK: Ink

    /// The trunk's ink, and the colour for text that belongs to no branch.
    var ink: Color
    /// Branch inks; a branch keeps one for life, picked by a stable hash of its name.
    var branchInks: [Color]
    /// Subject captions.
    var captionInk: Color

    // MARK: Strokes

    var lineWidth: CGFloat
    /// A wider, fainter stroke under each line (0 for none): a glow on dark paper, ink bleed on light.
    var bleedWidth: CGFloat
    var bleedOpacity: Double
    /// How far a hand-drawn line strays from straight, in points (0 for ruled lines).
    var wobble: CGFloat
    var dotRadius: CGFloat
    /// Older commits fade: opacity halves every `fadeHalfLife` days, down to `fadeFloor`.
    var fadeHalfLife: Double
    var fadeFloor: Double

    // MARK: Type

    var labelFont: Font
    var captionFont: Font
    var watermarkFont: Font
    var watermarkOpacity: Double

    /// A branch's ink, from its name alone: the same branch name is the same ink in every repository,
    /// on every redraw and launch (FNV-1a with a final mix, not Swift's seeded hash). Two branches
    /// can share an ink when their names hash alike.
    func ink(forBranch branch: String) -> Color {
        guard !branchInks.isEmpty else { return ink }
        return branchInks[Self.inkSlot(forBranch: branch, count: branchInks.count)]
    }

    static func inkSlot(forBranch branch: String, count: Int) -> Int {
        var hash = branch.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        hash ^= hash >> 33; hash &*= 0xff51afd7ed558ccd; hash ^= hash >> 33
        return Int(hash % UInt64(count))
    }

    /// How strongly a commit made `ageDays` ago is drawn.
    func opacity(ageDays: Double) -> Double {
        guard fadeHalfLife > 0 else { return 1 }
        return max(fadeFloor, pow(0.5, max(ageDays, 0) / fadeHalfLife))
    }
}

extension WallpaperStyle {

    /// Ink on cream: thin, slightly wandering pen lines on warm paper, each branch in its own ink,
    /// older commits fading. In dark mode the paper turns to a warm charcoal and the inks lighten.
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
            captionInk: dark ? rgb(222, 212, 192).opacity(0.55) : rgb(52, 44, 38).opacity(0.6),
            lineWidth: 1.4,
            bleedWidth: 3.2,
            bleedOpacity: dark ? 0.10 : 0.08,
            wobble: 1.3,
            dotRadius: 3.6,
            fadeHalfLife: 14,
            fadeFloor: 0.28,
            labelFont: .custom("Bradley Hand", size: 14),
            captionFont: .custom("Baskerville", size: 12).italic(),
            watermarkFont: .custom("Snell Roundhand", size: 84),
            watermarkOpacity: dark ? 0.10 : 0.12)
    }

    /// The first placeholder: glowing lanes on a night gradient. Kept to show a look is one value.
    static let nightTransit = WallpaperStyle(
        paper: [Color(red: 0.03, green: 0.04, blue: 0.10), Color(red: 0.07, green: 0.06, blue: 0.18),
                Color(red: 0.12, green: 0.07, blue: 0.20)],
        wash: Color(red: 0.25, green: 0.20, blue: 0.45).opacity(0.35),
        fibre: .clear,
        ink: Color(red: 0.55, green: 0.60, blue: 0.75),
        branchInks: [Color(red: 0.40, green: 0.85, blue: 0.85), Color(red: 0.66, green: 0.56, blue: 1.00),
                     Color(red: 1.00, green: 0.50, blue: 0.62), Color(red: 0.45, green: 0.70, blue: 1.00),
                     Color(red: 0.62, green: 0.90, blue: 0.48), Color(red: 1.00, green: 0.62, blue: 0.40)],
        captionInk: .white.opacity(0.32),
        lineWidth: 2.5,
        bleedWidth: 10,
        bleedOpacity: 0.14,
        wobble: 0,
        dotRadius: 5,
        fadeHalfLife: 0,
        fadeFloor: 1,
        labelFont: .system(size: 12, weight: .semibold, design: .rounded),
        captionFont: .system(size: 12, weight: .light),
        watermarkFont: .system(size: 96, weight: .ultraLight, design: .rounded),
        watermarkOpacity: 0.10)
}
