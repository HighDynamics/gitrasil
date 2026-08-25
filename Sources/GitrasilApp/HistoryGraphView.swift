import SwiftUI
import GitrasilCore

/// Draws the simplified history graph: the current-worktree spine (identity color) with its
/// intermediate branch segments and the meeting commit at the base, plus trunk's ahead-commits as
/// a separate grey fork lane. Truncated segments collapse to a "N hidden" row. A first, legible
/// rendering — the topology doc's structure made visible; the AppKit-canvas polish comes later.
struct HistoryGraphView: View {
    let graph: HistoryGraph
    let expandTruncated: Bool
    var selectedSHA: String? = nil
    var onSelect: (CommitNode) -> Void = { _ in }

    private let rowHeight: CGFloat = 46
    private let topPad: CGFloat = 14
    private let spineX: CGFloat = 22
    private let trunkX: CGFloat = 168
    private let dotRadius: CGFloat = 6

    private var spine: [Row] { Row.spine(of: graph, expanded: expandTruncated) }
    private var trunk: [Row] { Row.trunkAhead(of: graph, expanded: expandTruncated) }

    var body: some View {
        let rows = max(spine.count, trunk.count)
        let height = topPad * 2 + CGFloat(max(rows, 1)) * rowHeight

        Canvas { context, _ in
            drawLane(spine, x: spineX, in: &context)
            if !trunk.isEmpty {
                drawLane(trunk, x: trunkX, in: &context)
                connectTrunkToMeeting(&context)
            }
            drawNodes(spine, x: spineX, textX: spineX + 16, in: &context)
            drawNodes(trunk, x: trunkX, textX: trunkX + 16, in: &context)
        }
        .frame(width: 620, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in
            if let commit = commit(at: value.location) { onSelect(commit) }
        })
    }

    /// Map a tap location to the commit under it, if any.
    private func commit(at location: CGPoint) -> CommitNode? {
        let index = Int((location.y - topPad) / rowHeight)
        let onTrunk = !trunk.isEmpty && location.x > (spineX + trunkX) / 2
        let rows = onTrunk ? trunk : spine
        guard index >= 0, index < rows.count else { return nil }
        switch rows[index].content {
        case .commit(let c, _), .meeting(let c, _): return c
        case .hidden: return nil
        }
    }

    private func y(_ index: Int) -> CGFloat { topPad + CGFloat(index) * rowHeight + rowHeight / 2 }

    // MARK: Drawing

    private func drawLane(_ rows: [Row], x: CGFloat, in context: inout GraphicsContext) {
        guard rows.count > 1 else { return }
        for i in 0..<(rows.count - 1) {
            var path = Path()
            path.move(to: CGPoint(x: x, y: y(i)))
            path.addLine(to: CGPoint(x: x, y: y(i + 1)))
            let color = rows[i].isIdentity ? Palette.identity : Color.gray.opacity(0.55)
            context.stroke(path, with: .color(color), lineWidth: 2)
        }
    }

    private func connectTrunkToMeeting(_ context: inout GraphicsContext) {
        guard let last = trunk.indices.last, let meetingIndex = spine.indices.last else { return }
        var path = Path()
        path.move(to: CGPoint(x: trunkX, y: y(last)))
        path.addLine(to: CGPoint(x: spineX, y: y(meetingIndex)))
        context.stroke(path, with: .color(Color.gray.opacity(0.55)), lineWidth: 2)
    }

    private func drawNodes(_ rows: [Row], x: CGFloat, textX: CGFloat, in context: inout GraphicsContext) {
        for (i, row) in rows.enumerated() {
            let center = CGPoint(x: x, y: y(i))
            switch row.content {
            case .commit(let commit, let open), .meeting(let commit, let open):
                if let selectedSHA, commit.sha == selectedSHA {
                    let halo = CGRect(x: center.x - dotRadius - 4, y: center.y - dotRadius - 4,
                                      width: (dotRadius + 4) * 2, height: (dotRadius + 4) * 2)
                    context.fill(Path(ellipseIn: halo), with: .color(Palette.identity.opacity(0.25)))
                }
                drawDot(at: center, identity: row.isIdentity, open: open, ring: row.isMeeting, in: &context)
                drawText(row.label, sha: commit.shortSHA, subject: commit.subject,
                         at: CGPoint(x: textX, y: y(i)), in: &context)
            case .hidden(let count):
                drawHidden(count, at: center, textX: textX, in: &context)
            }
        }
    }

    private func drawDot(at center: CGPoint, identity: Bool, open: Bool, ring: Bool, in context: inout GraphicsContext) {
        let color = identity ? Palette.identity : Color.gray
        let rect = CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
        if open {
            context.fill(Path(ellipseIn: rect), with: .color(Color(nsColor: .windowBackgroundColor)))
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 2)
        } else if ring {
            context.stroke(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)), with: .color(color), lineWidth: 2)
        } else {
            context.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }

    private func drawText(_ label: String?, sha: String, subject: String, at point: CGPoint, in context: inout GraphicsContext) {
        var x = point.x
        if let label {
            let pill = context.resolve(Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary))
            let size = pill.measure(in: CGSize(width: 400, height: 20))
            let bg = CGRect(x: x, y: point.y - size.height / 2 - 1, width: size.width + 10, height: size.height + 2)
            context.fill(Path(roundedRect: bg, cornerRadius: 4), with: .color(Color.gray.opacity(0.18)))
            context.draw(pill, at: CGPoint(x: x + 5, y: point.y), anchor: .leading)
            x += size.width + 16
        }
        let shaText = context.resolve(Text(sha + "  ")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary))
        let shaSize = shaText.measure(in: CGSize(width: 200, height: 20))
        context.draw(shaText, at: CGPoint(x: x, y: point.y), anchor: .leading)

        let subjectText = context.resolve(Text(truncate(subject, 52))
            .font(.system(size: 12)))
        context.draw(subjectText, at: CGPoint(x: x + shaSize.width, y: point.y), anchor: .leading)
    }

    private func drawHidden(_ count: Int, at center: CGPoint, textX: CGFloat, in context: inout GraphicsContext) {
        let dots = context.resolve(Text("⋮").font(.system(size: 15, weight: .bold)).foregroundColor(.secondary))
        context.draw(dots, at: center, anchor: .center)
        let text = context.resolve(Text("\(count) commit\(count == 1 ? "" : "s") hidden")
            .font(.system(size: 11).italic())
            .foregroundColor(.secondary))
        context.draw(text, at: CGPoint(x: textX, y: center.y), anchor: .leading)
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}

// MARK: - Row view model

/// A single rendered graph row, flattened from the topology structure for drawing.
private struct Row {
    enum Content {
        case commit(CommitNode, open: Bool)
        case meeting(CommitNode, open: Bool)
        case hidden(Int)
    }

    let content: Content
    let isIdentity: Bool
    let label: String?

    var isMeeting: Bool { if case .meeting = content { return true } else { return false } }

    /// The worktree spine: cw's commits (identity), then each intermediate segment, then meeting.
    static func spine(of graph: HistoryGraph, expanded: Bool) -> [Row] {
        var rows: [Row] = []
        for segment in graph.segments {
            let isIdentity = segment.kind == .currentWorktree
            let commits = expanded ? segment.commits : segment.collapsedCommits
            for (i, commit) in commits.enumerated() {
                let open = isIdentity && i == 0 && graph.hasUncommittedChanges
                rows.append(Row(content: .commit(commit, open: open),
                                isIdentity: isIdentity,
                                label: i == 0 ? segment.branchLabel : nil))
            }
            if segment.isTruncatable && !expanded {
                rows.append(Row(content: .hidden(segment.hiddenCount), isIdentity: false, label: nil))
            }
        }
        if let meeting = graph.meetingCommit {
            rows.append(Row(content: .meeting(meeting, open: false), isIdentity: false, label: nil))
        }
        return rows
    }

    /// The trunk-ahead fork lane (grey), when trunk is ahead.
    static func trunkAhead(of graph: HistoryGraph, expanded: Bool) -> [Row] {
        guard let segment = graph.trunkAhead else { return [] }
        var rows: [Row] = []
        let commits = expanded ? segment.commits : segment.collapsedCommits
        for (i, commit) in commits.enumerated() {
            rows.append(Row(content: .commit(commit, open: false),
                            isIdentity: false,
                            label: i == 0 ? segment.branchLabel : nil))
        }
        if segment.isTruncatable && !expanded {
            rows.append(Row(content: .hidden(segment.hiddenCount), isIdentity: false, label: nil))
        }
        return rows
    }
}
