import SwiftUI
import GitrasilCore

/// The wallpaper: the repository's branch graph drawn from the shared `GraphLayout` rows — glowing
/// lanes on a deep night gradient, each branch in its own hue, commit subjects as quiet captions. A
/// Canvas inside a TimelineView whose clock is paused unless a tip pulse is running, so an idle
/// desktop costs no frames.
struct WallpaperView: View {
    let model: WallpaperModel

    var body: some View {
        // Read the graph here so Observation re-renders only when the model publishes a new one.
        let graph = model.graph
        let rows = graph.map { GraphLayout.rows(for: $0, expanded: false) } ?? []
        let pulseStart = model.pulseStart

        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: pulseStart == nil)) { timeline in
            Canvas { context, size in
                drawBackground(size: size, in: &context)
                drawRepoName(size: size, in: &context)
                guard !rows.isEmpty else { return }
                let geometry = Geometry(size: size, rowCount: rows.count)
                drawLanes(rows, geometry: geometry, in: &context)
                drawForks(rows, geometry: geometry, in: &context)
                drawDots(rows, geometry: geometry, in: &context)
                drawCaptions(rows, geometry: geometry, in: &context)
                if let pulseStart {
                    let t = timeline.date.timeIntervalSince(pulseStart) / WallpaperModel.pulseDuration
                    drawPulse(rows, geometry: geometry, progress: min(max(t, 0), 1), in: &context)
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Geometry

    /// Where rows and lanes land: the graph is centered vertically, its spine a little right of
    /// center so the lanes fan left and the captions have room on the right.
    private struct Geometry {
        let rowHeight: CGFloat
        let top: CGFloat
        let spineX: CGFloat
        let laneGap: CGFloat = 38

        init(size: CGSize, rowCount: Int) {
            rowHeight = min(64, max(18, size.height * 0.7 / CGFloat(rowCount)))
            top = (size.height - rowHeight * CGFloat(rowCount)) / 2
            spineX = size.width * 0.6
        }

        func y(_ index: Int) -> CGFloat { top + CGFloat(index) * rowHeight + rowHeight / 2 }
        func x(_ lane: Int) -> CGFloat { spineX - CGFloat(lane) * laneGap }
        func point(_ index: Int, lane: Int) -> CGPoint { CGPoint(x: x(lane), y: y(index)) }
    }

    // MARK: Colors

    private static let amber = Color(red: 1.00, green: 0.74, blue: 0.42)
    private static let quiet = Color(red: 0.55, green: 0.60, blue: 0.75)
    private static let lanePalette: [Color] = [
        Color(red: 0.40, green: 0.85, blue: 0.85),   // teal
        Color(red: 0.66, green: 0.56, blue: 1.00),   // violet
        Color(red: 1.00, green: 0.50, blue: 0.62),   // rose
        Color(red: 0.45, green: 0.70, blue: 1.00),   // sky
        Color(red: 0.62, green: 0.90, blue: 0.48),   // lime
        Color(red: 1.00, green: 0.62, blue: 0.40),   // coral
    ]

    /// A branch keeps its hue for life: derived from its name (a stable hash, not Swift's seeded one),
    /// so lanes don't recolor across redraws or launches.
    private func color(for row: GraphRow) -> Color {
        if row.isIdentity { return Self.amber }
        guard let branch = row.branch else { return Self.quiet }
        let hash = branch.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        return Self.lanePalette[Int(hash % UInt32(Self.lanePalette.count))]
    }

    // MARK: Drawing

    private func drawBackground(size: CGSize, in context: inout GraphicsContext) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [Color(red: 0.03, green: 0.04, blue: 0.10),
                              Color(red: 0.07, green: 0.06, blue: 0.18),
                              Color(red: 0.12, green: 0.07, blue: 0.20)]),
            startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
        // A soft bloom behind the graph.
        let bloom = CGRect(x: size.width * 0.35, y: size.height * 0.1, width: size.width * 0.5, height: size.height * 0.8)
        context.fill(Path(ellipseIn: bloom), with: .radialGradient(
            Gradient(colors: [Color(red: 0.25, green: 0.20, blue: 0.45).opacity(0.35), .clear]),
            center: CGPoint(x: bloom.midX, y: bloom.midY), startRadius: 0, endRadius: bloom.width / 2))
    }

    private func drawRepoName(size: CGSize, in context: inout GraphicsContext) {
        let name = Text(model.repoName)
            .font(.system(size: 96, weight: .ultraLight, design: .rounded))
            .foregroundColor(.white.opacity(0.10))
        context.draw(name, at: CGPoint(x: 64, y: size.height - 72), anchor: .bottomLeading)
    }

    /// A glowing stroke: a wide faint halo under a thin bright line.
    private func glow(_ path: Path, _ color: Color, in context: inout GraphicsContext) {
        context.stroke(path, with: .color(color.opacity(0.14)), style: StrokeStyle(lineWidth: 10, lineCap: .round))
        context.stroke(path, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }

    private func drawLanes(_ rows: [GraphRow], geometry g: Geometry, in context: inout GraphicsContext) {
        for lane in Set(rows.map(\.lane)) {
            let indices = rows.indices.filter { rows[$0].lane == lane }
            for (a, b) in zip(indices, indices.dropFirst()) {
                var path = Path()
                path.move(to: g.point(a, lane: lane))
                path.addLine(to: g.point(b, lane: lane))
                glow(path, color(for: rows[a]), in: &context)
            }
        }
    }

    /// A fork lane runs straight down its lane, then eases into the commit it branches from on a
    /// smooth curve (the app's view uses a hard diagonal; a wallpaper wants it softer).
    private func drawForks(_ rows: [GraphRow], geometry g: Geometry, in context: inout GraphicsContext) {
        let meeting = rows.lastIndex { $0.isMeeting }
        for (index, row) in rows.enumerated() {
            guard let forkBase = row.forkBaseSHA,
                  let target = (rows.firstIndex { $0.commit?.sha == forkBase } ?? meeting),
                  target > index else { continue }
            let source = g.point(index, lane: row.lane)
            let end = g.point(target, lane: rows[target].lane)
            let bend = CGPoint(x: source.x, y: g.y(target - 1))
            var path = Path()
            path.move(to: source)
            path.addLine(to: bend)
            path.addCurve(to: end,
                          control1: CGPoint(x: bend.x, y: bend.y + g.rowHeight * 0.6),
                          control2: CGPoint(x: end.x, y: end.y - g.rowHeight * 0.6))
            glow(path, color(for: row), in: &context)
        }
    }

    private func drawDots(_ rows: [GraphRow], geometry g: Geometry, in context: inout GraphicsContext) {
        for (index, row) in rows.enumerated() {
            let center = g.point(index, lane: row.lane)
            let color = color(for: row)
            if case .hidden = row.content {
                // A collapsed run: three small beads along the lane.
                for k in -1...1 {
                    let c = CGPoint(x: center.x, y: center.y + CGFloat(k) * 5)
                    context.fill(Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)),
                                 with: .color(color.opacity(0.7)))
                }
                continue
            }
            let r: CGFloat = row.isMeeting ? 7 : 5
            context.fill(Path(ellipseIn: CGRect(x: center.x - r * 2.6, y: center.y - r * 2.6, width: r * 5.2, height: r * 5.2)),
                         with: .radialGradient(Gradient(colors: [color.opacity(0.35), .clear]),
                                               center: center, startRadius: 0, endRadius: r * 2.6))
            let dot = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            if row.open || row.isMeeting {
                context.fill(dot, with: .color(Color(red: 0.05, green: 0.05, blue: 0.12)))
                context.stroke(dot, with: .color(color), lineWidth: 2)
            } else {
                context.fill(dot, with: .color(color))
            }
        }
    }

    /// Branch names at lane tips and commit subjects on the right, faint enough to read as texture.
    private func drawCaptions(_ rows: [GraphRow], geometry g: Geometry, in context: inout GraphicsContext) {
        let showSubjects = g.rowHeight >= 24
        let textX = g.spineX + 28
        for (index, row) in rows.enumerated() {
            guard let commit = row.commit else { continue }
            let y = g.y(index)
            let labels = [row.label].compactMap { $0 } + row.extraLabels
            var caption = Text("")
            for label in labels {
                caption = caption + Text(label + "  ")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(color(for: row).opacity(0.85))
            }
            if showSubjects {
                caption = caption + Text(commit.subject)
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(.white.opacity(row.isIdentity ? 0.55 : 0.32))
            }
            context.draw(caption, at: CGPoint(x: textX, y: y), anchor: .leading)
        }
    }

    /// An expanding, fading ring around each branch tip that just moved.
    private func drawPulse(_ rows: [GraphRow], geometry g: Geometry, progress: Double, in context: inout GraphicsContext) {
        let eased = 1 - pow(1 - progress, 3)
        let radius = 6 + 54 * eased
        for (index, row) in rows.enumerated() {
            guard let sha = row.commit?.sha, model.pulseTips.contains(sha) else { continue }
            let center = g.point(index, lane: row.lane)
            let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(color(for: row).opacity(0.8 * (1 - progress))), lineWidth: 2)
        }
    }
}
