import SwiftUI
import GitrasilCore

/// Draws the simplified history graph as a railroad: a narrow multi-lane rail on the left (dots +
/// connectors, with trunk's ahead-commits forking into their own lane and rejoining at the meeting
/// commit) and a single commit-subject column to its right. Every commit is one row; the current
/// worktree's lane is its identity color, everything else grey. Truncated segments collapse to a
/// "N hidden" row.
struct HistoryGraphView: View {
    let graph: HistoryGraph
    let expandTruncated: Bool
    var selectedSHA: String? = nil
    var onSelect: (CommitNode) -> Void = { _ in }

    private let rowHeight: CGFloat = 44
    private let topPad: CGFloat = 12
    private let railLeft: CGFloat = 18
    private let laneGap: CGFloat = 22
    private let dotRadius: CGFloat = 6

    private var rows: [Row] { Row.build(from: graph, expanded: expandTruncated) }

    var body: some View {
        let rows = self.rows
        let height = topPad * 2 + CGFloat(max(rows.count, 1)) * rowHeight
        // Text column starts past the widest lane in use.
        let maxLane = rows.map(\.lane).max() ?? 0
        let textX = railLeft + laneGap * CGFloat(maxLane + 1) + 16

        Canvas { context, _ in
            drawConnectors(rows, in: &context)
            drawForkIntoMeeting(rows, in: &context)
            drawNodes(rows, textX: textX, in: &context)
        }
        .frame(width: max(640, textX + 380), height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in
            if let commit = commit(at: value.location, rows: rows) { onSelect(commit) }
        })
    }

    private func y(_ index: Int) -> CGFloat { topPad + CGFloat(index) * rowHeight + rowHeight / 2 }
    private func laneX(_ lane: Int) -> CGFloat { railLeft + CGFloat(lane) * laneGap }

    private func commit(at location: CGPoint, rows: [Row]) -> CommitNode? {
        let index = Int((location.y - topPad) / rowHeight)
        guard index >= 0, index < rows.count else { return nil }
        return rows[index].commit
    }

    // MARK: Drawing

    /// Connect consecutive rows within each lane. Lane rows need not be adjacent in the list (a
    /// trunk-ahead run sits between the last intermediate commit and the meeting), so we connect
    /// consecutive rows *of the same lane*, which draws the main lane straight past the fork.
    private func drawConnectors(_ rows: [Row], in context: inout GraphicsContext) {
        let lanes = Set(rows.map(\.lane))
        for lane in lanes {
            let indices = rows.indices.filter { rows[$0].lane == lane }
            for (a, b) in zip(indices, indices.dropFirst()) {
                var path = Path()
                path.move(to: CGPoint(x: laneX(lane), y: y(a)))
                path.addLine(to: CGPoint(x: laneX(lane), y: y(b)))
                let color = rows[b].isIdentity ? Palette.identity : Color.gray.opacity(0.55)
                context.stroke(path, with: .color(color), lineWidth: 2)
            }
        }
    }

    /// Every forked lane (trunk-ahead and each revealed branch) rejoins the main lane at the meeting
    /// commit — a diagonal from the lane's oldest row down to the meeting row.
    private func drawForkIntoMeeting(_ rows: [Row], in context: inout GraphicsContext) {
        guard let meeting = rows.lastIndex(where: { $0.isMeeting }) else { return }
        let forkLanes = Set(rows.map(\.lane)).filter { $0 > 0 }
        for lane in forkLanes {
            guard let lastFork = rows.indices.filter({ rows[$0].lane == lane }).last else { continue }
            var path = Path()
            path.move(to: CGPoint(x: laneX(lane), y: y(lastFork)))
            path.addLine(to: CGPoint(x: laneX(0), y: y(meeting)))
            context.stroke(path, with: .color(Color.gray.opacity(0.55)), lineWidth: 2)
        }
    }

    private func drawNodes(_ rows: [Row], textX: CGFloat, in context: inout GraphicsContext) {
        for (index, row) in rows.enumerated() {
            let center = CGPoint(x: laneX(row.lane), y: y(index))
            switch row.content {
            case .commit(let commit, let open), .meeting(let commit, let open):
                if commit.sha == selectedSHA {
                    let halo = CGRect(x: center.x - dotRadius - 4, y: center.y - dotRadius - 4,
                                      width: (dotRadius + 4) * 2, height: (dotRadius + 4) * 2)
                    context.fill(Path(ellipseIn: halo), with: .color(Palette.identity.opacity(0.25)))
                }
                drawDot(at: center, identity: row.isIdentity, open: open, ring: row.isMeeting, in: &context)
                drawText(row.label, sha: commit.shortSHA, subject: commit.subject,
                         at: CGPoint(x: textX, y: y(index)), in: &context)
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
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 2)
        } else {
            context.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }

    private func drawText(_ label: String?, sha: String, subject: String, at point: CGPoint, in context: inout GraphicsContext) {
        var x = point.x
        if let label {
            let pill = context.resolve(Text(label)
                .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary))
            let size = pill.measure(in: CGSize(width: 400, height: 20))
            let bg = CGRect(x: x, y: point.y - size.height / 2 - 1, width: size.width + 10, height: size.height + 2)
            context.fill(Path(roundedRect: bg, cornerRadius: 4), with: .color(Color.gray.opacity(0.18)))
            context.draw(pill, at: CGPoint(x: x + 5, y: point.y), anchor: .leading)
            x += size.width + 16
        }
        let shaText = context.resolve(Text(sha + "  ")
            .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary))
        let shaSize = shaText.measure(in: CGSize(width: 200, height: 20))
        context.draw(shaText, at: CGPoint(x: x, y: point.y), anchor: .leading)

        let subjectText = context.resolve(Text(truncate(subject, 60)).font(.system(size: 12)))
        context.draw(subjectText, at: CGPoint(x: x + shaSize.width, y: point.y), anchor: .leading)
    }

    private func drawHidden(_ count: Int, at center: CGPoint, textX: CGFloat, in context: inout GraphicsContext) {
        let dots = context.resolve(Text("⋮").font(.system(size: 15, weight: .bold)).foregroundColor(.secondary))
        context.draw(dots, at: center, anchor: .center)
        let text = context.resolve(Text("\(count) commit\(count == 1 ? "" : "s") hidden")
            .font(.system(size: 11).italic()).foregroundColor(.secondary))
        context.draw(text, at: CGPoint(x: textX, y: center.y), anchor: .leading)
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}

/// One rendered graph row: a commit (or meeting, or a "N hidden" marker) placed in a lane.
private struct Row {
    enum Content {
        case commit(CommitNode, open: Bool)
        case meeting(CommitNode, open: Bool)
        case hidden(Int)
    }

    let content: Content
    /// 0 = the current-worktree spine (with its intermediate branches and the meeting commit);
    /// 1 = trunk's ahead-commits forking off.
    let lane: Int
    let isIdentity: Bool
    let label: String?

    var isMeeting: Bool { if case .meeting = content { return true } else { return false } }

    var commit: CommitNode? {
        switch content {
        case .commit(let c, _), .meeting(let c, _): return c
        case .hidden: return nil
        }
    }

    /// Flatten the graph into a single ordered row list: the cw spine and intermediates (lane 0),
    /// then trunk's ahead-commits (lane 1), then the meeting commit (lane 0) at the base.
    static func build(from graph: HistoryGraph, expanded: Bool) -> [Row] {
        var rows: [Row] = []

        for segment in graph.segments {
            let isIdentity = segment.kind == .currentWorktree
            let commits = expanded ? segment.commits : segment.collapsedCommits
            for (i, commit) in commits.enumerated() {
                let open = isIdentity && i == 0 && graph.hasUncommittedChanges
                rows.append(Row(content: .commit(commit, open: open), lane: 0,
                                isIdentity: isIdentity, label: i == 0 ? segment.branchLabel : nil))
            }
            if segment.isTruncatable && !expanded {
                rows.append(Row(content: .hidden(segment.hiddenCount), lane: 0, isIdentity: false, label: nil))
            }
        }

        // Each forked lane (trunk-ahead, then revealed branches) gets the next lane index.
        var nextLane = 1
        func appendLane(_ segment: GraphSegment) {
            let lane = nextLane; nextLane += 1
            let commits = expanded ? segment.commits : segment.collapsedCommits
            for (i, commit) in commits.enumerated() {
                rows.append(Row(content: .commit(commit, open: false), lane: lane,
                                isIdentity: false, label: i == 0 ? segment.branchLabel : nil))
            }
            if segment.isTruncatable && !expanded {
                rows.append(Row(content: .hidden(segment.hiddenCount), lane: lane, isIdentity: false, label: nil))
            }
        }

        if let trunk = graph.trunkAhead { appendLane(trunk) }
        for revealed in graph.revealedLanes { appendLane(revealed) }

        if let meeting = graph.meetingCommit {
            rows.append(Row(content: .meeting(meeting, open: false), lane: 0, isIdentity: false, label: nil))
        }
        return rows
    }
}
