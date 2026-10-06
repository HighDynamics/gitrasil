import SwiftUI
import GitrasilCore

/// The wallpaper: the pinned repositories' branch graphs side by side on one sheet of paper, drawn
/// from the shared `GraphLayout` rows in a `WallpaperStyle`. Each repository is a Canvas inside a
/// TimelineView whose clock is paused unless a tip pulse is running, so an idle desktop costs no
/// frames.
struct WallpaperView: View {
    let background: BackgroundModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = WallpaperStyle.inkOnCream(dark: colorScheme == .dark)
        let panes = background.panes
        ZStack {
            Canvas { context, size in drawPaper(size: size, style: style, in: &context) }
            if panes.isEmpty {
                Text("Pin a repository from the menu bar to draw its branches here.")
                    .font(style.captionFont.weight(.regular))
                    .foregroundStyle(style.captionInk)
            } else {
                HStack(spacing: 0) {
                    ForEach(panes, id: \.repoURL) { pane in
                        RepoPane(model: pane, style: style, now: background.now)
                    }
                }
                // Keep clear of the menu bar and the Dock's usual reach.
                .padding(.vertical, 48)
            }
        }
        .ignoresSafeArea()
    }

    private func drawPaper(size: CGSize, style: WallpaperStyle, in context: inout GraphicsContext) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: style.paper), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
        let wash = rect.insetBy(dx: size.width * 0.1, dy: size.height * 0.08)
        context.fill(Path(ellipseIn: wash), with: .radialGradient(
            Gradient(colors: [style.wash, .clear]),
            center: CGPoint(x: wash.midX, y: wash.midY), startRadius: 0, endRadius: wash.width / 2))
        // Fibres: short faint strokes at fixed, seeded places, so the paper never shimmers.
        var rng = SeededRandom(seed: 0x9E3779B9)
        var fibres = Path()
        for _ in 0..<Int(size.width * size.height / 9000) {
            let x = rng.next() * size.width, y = rng.next() * size.height
            let angle = rng.next() * .pi, length = 4 + rng.next() * 10
            fibres.move(to: CGPoint(x: x, y: y))
            fibres.addLine(to: CGPoint(x: x + cos(angle) * length, y: y + sin(angle) * length))
        }
        context.stroke(fibres, with: .color(style.fibre), lineWidth: 0.6)
    }
}

/// One repository's graph.
private struct RepoPane: View {
    let model: WallpaperModel
    let style: WallpaperStyle
    let now: Date

    var body: some View {
        // Read the graph here so Observation re-renders only when the model publishes a new one.
        let rows = model.graph.map { GraphLayout.rows(for: $0, expanded: false) } ?? []
        let pulseStart = model.pulseStart
        let pulseTips = model.pulseTips
        let ages = Self.ages(rows, now: now)
        let checkedOut = model.graph?.checkedOutBranches ?? []

        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: pulseStart == nil)) { timeline in
            Canvas { context, size in
                let drawing = Drawing(style: style, rows: rows, ages: ages, checkedOut: checkedOut,
                                      geometry: Geometry(size: size, rowCount: rows.count))
                drawing.watermark(model.repoName, problem: model.problem, size: size, in: &context)
                guard !rows.isEmpty else { return }
                drawing.lanes(in: &context)
                drawing.forks(in: &context)
                drawing.dots(in: &context)
                drawing.captions(in: &context)
                if let pulseStart {
                    let t = timeline.date.timeIntervalSince(pulseStart) / WallpaperModel.pulseDuration
                    drawing.pulse(tips: pulseTips, progress: min(max(t, 0), 1), in: &context)
                }
            }
        }
        .clipped()
    }

    /// Each row's age in days, from its commit date (rows without a commit take the row above's).
    private static func ages(_ rows: [GraphRow], now: Date) -> [Double] {
        let iso = ISO8601DateFormatter()
        var last = 0.0
        return rows.map { row in
            if let date = row.commit.flatMap({ iso.date(from: $0.date) }) {
                last = now.timeIntervalSince(date) / 86_400
            }
            return last
        }
    }
}

// MARK: - Geometry

/// Where rows and lanes land in a pane: the graph is centered vertically, its spine right of center
/// so the lanes fan left and the captions have room on the right.
private struct Geometry {
    let size: CGSize
    let rowHeight: CGFloat
    let top: CGFloat
    let spineX: CGFloat
    let laneGap: CGFloat

    init(size: CGSize, rowCount: Int) {
        self.size = size
        rowHeight = min(52, max(16, size.height * 0.82 / CGFloat(max(rowCount, 1))))
        top = (size.height - rowHeight * CGFloat(rowCount)) / 2
        spineX = size.width * (size.width < 700 ? 0.42 : 0.5)
        laneGap = min(34, size.width * 0.06)
    }

    /// Room for a caption on the right of the spine.
    var captionWidth: CGFloat { size.width - spineX - 40 }

    func y(_ index: Int) -> CGFloat { top + CGFloat(index) * rowHeight + rowHeight / 2 }
    func x(_ lane: Int) -> CGFloat { spineX - CGFloat(lane) * laneGap }
    func point(_ index: Int, lane: Int) -> CGPoint { CGPoint(x: x(lane), y: y(index)) }
}

// MARK: - Drawing

/// The pane's strokes, all styled from `style`. Hand-drawn wobble is seeded from what's drawn
/// (positions, never time), so a redraw draws the same line.
private struct Drawing {
    let style: WallpaperStyle
    let rows: [GraphRow]
    let ages: [Double]
    /// Branches checked out in some worktree: their tips get a second ring.
    let checkedOut: Set<String>
    let geometry: Geometry

    private var g: Geometry { geometry }

    /// Lane 0 is the trunk spine (and its anchor) in the repo-wide graph, drawn in plain ink; every
    /// other lane is a branch in its name's ink, the same in every repository.
    private func ink(_ row: GraphRow) -> Color {
        row.lane == 0 ? style.ink : ink(branch: row.branch)
    }

    private func ink(branch: String?) -> Color {
        branch.map(style.ink(forBranch:)) ?? style.ink
    }

    private func opacity(_ index: Int) -> Double { style.opacity(ageDays: ages[index]) }

    func watermark(_ name: String, problem: String?, size: CGSize, in context: inout GraphicsContext) {
        let text = Text(name).font(style.watermarkFont).foregroundColor(style.ink.opacity(style.watermarkOpacity))
        context.draw(text, at: CGPoint(x: 32, y: size.height - 8), anchor: .bottomLeading)
        if let problem {
            context.draw(Text(problem).font(style.captionFont).foregroundColor(style.captionInk),
                         at: CGPoint(x: size.width / 2, y: size.height / 2), anchor: .center)
        }
    }

    /// A pen line from `a` to `b`: a gentle seeded wander about the straight line, with a faint bleed
    /// under it.
    private func penPath(_ a: CGPoint, _ b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        guard style.wobble > 0 else { path.addLine(to: b); return path }
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(hypot(dx, dy), 1)
        let normal = CGPoint(x: -dy / length, y: dx / length)
        var rng = SeededRandom(seed: UInt64(abs(Int(a.x * 31 + a.y * 17 + b.x * 7 + b.y * 3))) &+ 1)
        let steps = max(2, Int(length / 24))
        let phase = rng.next() * .pi * 2, waves = 0.6 + rng.next() * 0.8
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            // Pinned at both ends, wandering most in the middle.
            let offset = sin(t * .pi * waves * 2 + phase) * sin(t * .pi) * style.wobble
            let point = CGPoint(x: a.x + dx * t + normal.x * offset, y: a.y + dy * t + normal.y * offset)
            if step == steps { path.addLine(to: b) } else { path.addLine(to: point) }
        }
        return path
    }

    private func stroke(_ path: Path, _ color: Color, opacity: Double, in context: inout GraphicsContext) {
        if style.bleedWidth > 0 {
            context.stroke(path, with: .color(color.opacity(style.bleedOpacity * opacity)),
                           style: StrokeStyle(lineWidth: style.bleedWidth, lineCap: .round, lineJoin: .round))
        }
        context.stroke(path, with: .color(color.opacity(0.92 * opacity)),
                       style: StrokeStyle(lineWidth: style.lineWidth, lineCap: .round, lineJoin: .round))
    }

    func lanes(in context: inout GraphicsContext) {
        for lane in Set(rows.map(\.lane)) {
            let indices = rows.indices.filter { rows[$0].lane == lane }
            for (a, b) in zip(indices, indices.dropFirst()) {
                stroke(penPath(g.point(a, lane: lane), g.point(b, lane: lane)), ink(rows[a]),
                       opacity: opacity(a), in: &context)
            }
        }
    }

    /// A fork lane runs straight down its lane, then eases into the commit it branches from.
    func forks(in context: inout GraphicsContext) {
        let meeting = rows.lastIndex { $0.isMeeting }
        for (index, row) in rows.enumerated() {
            guard let forkBase = row.forkBaseSHA,
                  let target = (rows.firstIndex { $0.commit?.sha == forkBase } ?? meeting),
                  target > index else { continue }
            let source = g.point(index, lane: row.lane)
            let end = g.point(target, lane: rows[target].lane)
            let bend = CGPoint(x: source.x, y: g.y(target - 1))
            var path = penPath(source, bend)
            path.addCurve(to: end,
                          control1: CGPoint(x: bend.x, y: bend.y + g.rowHeight * 0.6),
                          control2: CGPoint(x: end.x, y: end.y - g.rowHeight * 0.6))
            stroke(path, ink(row), opacity: opacity(index), in: &context)
        }
    }

    func dots(in context: inout GraphicsContext) {
        for (index, row) in rows.enumerated() {
            let center = g.point(index, lane: row.lane)
            let color = ink(row)
            let alpha = opacity(index)
            if case .hidden = row.content {
                // A collapsed run: three small beads along the lane.
                for k in -1...1 {
                    let c = CGPoint(x: center.x, y: center.y + CGFloat(k) * 4.5)
                    context.fill(Path(ellipseIn: CGRect(x: c.x - 1.3, y: c.y - 1.3, width: 2.6, height: 2.6)),
                                 with: .color(color.opacity(0.8 * alpha)))
                }
                continue
            }
            let r = style.dotRadius * (row.isMeeting ? 1.3 : 1)
            // A pen dot: slightly out of round, turned by its position so each is its own.
            var rng = SeededRandom(seed: UInt64(abs(Int(center.x * 13 + center.y * 29))) &+ 7)
            let dot = Path(ellipseIn: CGRect(x: -r * 1.06, y: -r * 0.94, width: r * 2.12, height: r * 1.88))
                .applying(CGAffineTransform(rotationAngle: rng.next() * .pi)
                    .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
            let names = [row.label].compactMap { $0 } + row.extraLabels
            if row.isMeeting || names.isEmpty {
                context.fill(dot, with: .color(style.paper[1]))
                context.stroke(dot, with: .color(color.opacity(alpha)), lineWidth: style.lineWidth)
            } else {
                context.fill(dot, with: .color(color.opacity(alpha)))
            }
            // A checked-out branch's tip: an open ring around the dot, like a worktree's mark.
            if let name = names.first(where: checkedOut.contains) {
                let ringInk = row.lane == 0 && name == row.label ? style.ink : ink(branch: name)
                let ring = Path(ellipseIn: CGRect(x: center.x - r * 2, y: center.y - r * 2, width: r * 4, height: r * 4))
                context.stroke(ring, with: .color(ringInk.opacity(0.8 * max(alpha, 0.75))), lineWidth: style.lineWidth * 0.8)
            }
        }
    }

    /// Branch names (in each branch's ink, trunk's in plain ink) and commit subjects in a column
    /// right of the spine, one line per row, the subject cut short to fit the pane.
    func captions(in context: inout GraphicsContext) {
        let showSubjects = g.rowHeight >= 20 && g.captionWidth > 120
        let textX = g.spineX + 22
        for (index, row) in rows.enumerated() {
            guard let commit = row.commit else { continue }
            let alpha = opacity(index)
            var labels = Text("")
            for label in [row.label].compactMap({ $0 }) + row.extraLabels {
                let color = row.lane == 0 && label == row.label ? style.ink : ink(branch: label)
                labels = labels + Text(label + "  ").font(style.labelFont).foregroundColor(color.opacity(max(alpha, 0.75)))
            }
            func line(_ subject: String) -> Text {
                showSubjects ? labels + Text(subject).font(style.captionFont).foregroundColor(style.captionInk.opacity(alpha)) : labels
            }
            var subject = commit.subject
            var resolved = context.resolve(line(subject))
            let width = resolved.measure(in: CGSize(width: CGFloat.infinity, height: g.rowHeight)).width
            if showSubjects, width > g.captionWidth, !subject.isEmpty {
                let keep = Int(Double(subject.count) * Double(g.captionWidth / width)) - 2
                subject = keep > 3 ? String(subject.prefix(keep)) + "…" : ""
                resolved = context.resolve(line(subject))
            }
            context.draw(resolved, at: CGPoint(x: textX, y: g.y(index)), anchor: .leading)
        }
    }

    /// An expanding, fading ring around each branch tip that just moved.
    func pulse(tips: Set<String>, progress: Double, in context: inout GraphicsContext) {
        let eased = 1 - pow(1 - progress, 3)
        let radius = 4 + 40 * eased
        for (index, row) in rows.enumerated() {
            guard let sha = row.commit?.sha, tips.contains(sha) else { continue }
            let center = g.point(index, lane: row.lane)
            let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(ink(row).opacity(0.7 * (1 - progress))), lineWidth: style.lineWidth)
        }
    }
}

/// A tiny deterministic generator (SplitMix64) for fixed textures and pen wobble.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    /// The next value in 0..<1.
    mutating func next() -> CGFloat {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return CGFloat(z >> 11) / CGFloat(1 << 53)
    }
}
