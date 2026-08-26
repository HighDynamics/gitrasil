import SwiftUI
import AppKit
import GitrasilCore

/// The full history graph: a Canvas "rail" (dots, lane connectors, and fork lines drawn to each
/// lane's true parent commit) behind a column of SwiftUI commit rows. Each row shows subject +
/// sha · author · time, highlights when selected, and reveals its contextual mutation buttons on
/// hover (design brief §5, §9). Row and rail share one row height so they stay aligned.
struct HistoryGraphView: View {
    let graph: HistoryGraph
    let expandTruncated: Bool
    let selectedSHAs: Set<String>
    let isMutable: Bool
    let mutabilityReason: String?
    var onSelect: (CommitNode, _ extend: Bool) -> Void = { _, _ in }
    var onDrop: (CommitNode) -> Void = { _ in }
    var onCherryPick: (CommitNode) -> Void = { _ in }
    var onRebase: (String) -> Void = { _ in }

    private let rowHeight: CGFloat = 52
    private let railLeft: CGFloat = 18
    private let laneGap: CGFloat = 22
    private let dotRadius: CGFloat = 6

    private var rows: [Row] { Row.build(from: graph, expanded: expandTruncated) }

    var body: some View {
        let rows = self.rows
        let maxLane = rows.map(\.lane).max() ?? 0
        let railWidth = laneX(maxLane) + dotRadius + 14
        let height = CGFloat(max(rows.count, 1)) * rowHeight

        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                drawConnectors(rows, in: &context)
                drawForks(rows, in: &context)
                drawDots(rows, in: &context)
            }
            .frame(width: railWidth, height: height)
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    CommitRowView(
                        row: row,
                        isSelected: row.commit.map { selectedSHAs.contains($0.sha) } ?? false,
                        isMutable: isMutable,
                        mutabilityReason: mutabilityReason,
                        onTap: { extend in row.commit.map { onSelect($0, extend) } },
                        onDrop: { row.commit.map(onDrop) },
                        onCherryPick: { row.commit.map(onCherryPick) },
                        onRebase: onRebase
                    )
                    .frame(height: rowHeight)
                }
            }
            .padding(.leading, railWidth)
        }
        .frame(width: railWidth + 560, height: height, alignment: .topLeading)
    }

    private func y(_ index: Int) -> CGFloat { CGFloat(index) * rowHeight + rowHeight / 2 }
    private func laneX(_ lane: Int) -> CGFloat { railLeft + CGFloat(lane) * laneGap }

    // MARK: Rail drawing

    private func drawConnectors(_ rows: [Row], in context: inout GraphicsContext) {
        for lane in Set(rows.map(\.lane)) {
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

    /// Draw each forking lane's join line to its true parent commit's row (falling back to the
    /// meeting commit if that parent isn't a visible row).
    private func drawForks(_ rows: [Row], in context: inout GraphicsContext) {
        let meeting = rows.lastIndex { $0.isMeeting }
        for (index, row) in rows.enumerated() {
            guard let forkBase = row.forkBaseSHA else { continue }
            let targetIndex = rows.firstIndex { $0.commit?.sha == forkBase } ?? meeting
            guard let targetIndex else { continue }
            var path = Path()
            path.move(to: CGPoint(x: laneX(row.lane), y: y(index)))
            path.addLine(to: CGPoint(x: laneX(rows[targetIndex].lane), y: y(targetIndex)))
            context.stroke(path, with: .color(Color.gray.opacity(0.55)), lineWidth: 2)
        }
    }

    private func drawDots(_ rows: [Row], in context: inout GraphicsContext) {
        for (index, row) in rows.enumerated() {
            guard let commit = row.commit else { continue }
            let center = CGPoint(x: laneX(row.lane), y: y(index))
            if selectedSHAs.contains(commit.sha) {
                let halo = CGRect(x: center.x - dotRadius - 4, y: center.y - dotRadius - 4,
                                  width: (dotRadius + 4) * 2, height: (dotRadius + 4) * 2)
                context.fill(Path(ellipseIn: halo), with: .color(Palette.identity.opacity(0.25)))
            }
            let color = row.isIdentity ? Palette.identity : Color.gray
            let rect = CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
            if row.open {
                context.fill(Path(ellipseIn: rect), with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 2)
            } else if row.isMeeting {
                context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 2)
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
    }
}

// MARK: - Row view

private struct CommitRowView: View {
    let row: Row
    let isSelected: Bool
    let isMutable: Bool
    let mutabilityReason: String?
    let onTap: (Bool) -> Void
    let onDrop: () -> Void
    let onCherryPick: () -> Void
    let onRebase: (String) -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            content
            Spacer(minLength: 8)
            if hovered { actions }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture { onTap(NSEvent.modifierFlags.contains(.shift)) }
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var content: some View {
        switch row.content {
        case .commit(let commit), .meeting(let commit):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let label = row.label {
                        Text(label)
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text(commit.subject).font(.system(size: 13)).lineLimit(1)
                }
                Text("\(commit.shortSHA) · \(commit.author) · \(RelativeTime.string(commit.date))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        case .hidden(let count):
            Text("\(count) commit\(count == 1 ? "" : "s") hidden")
                .font(.system(size: 11).italic()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if let branch = row.rebaseBranch {
                actionButton("Rebase onto \(branch)", systemImage: "arrow.triangle.merge") { onRebase(branch) }
            }
            if row.isCherrySource {
                actionButton("Cherry-pick", systemImage: "arrow.down.doc") { onCherryPick() }
            }
            if row.isDropSource {
                actionButton("Drop", systemImage: "trash", destructive: true) { onDrop() }
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, destructive: Bool = false,
                              _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(destructive ? .red : .accentColor)
        .disabled(!isMutable)
        .help(isMutable ? title : (mutabilityReason ?? title))
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(isSelected ? Palette.identity.opacity(0.14) : (hovered ? Color.gray.opacity(0.08) : .clear))
            .padding(.horizontal, 4)
    }
}

// MARK: - Row model

private struct Row {
    enum Content {
        case commit(CommitNode)
        case meeting(CommitNode)
        case hidden(Int)
    }

    let content: Content
    let lane: Int
    let isIdentity: Bool
    let open: Bool
    let label: String?
    var forkBaseSHA: String?
    let isDropSource: Bool
    let isCherrySource: Bool
    let rebaseBranch: String?

    var isMeeting: Bool { if case .meeting = content { return true } else { return false } }
    var commit: CommitNode? {
        switch content {
        case .commit(let c), .meeting(let c): return c
        case .hidden: return nil
        }
    }

    static func build(from graph: HistoryGraph, expanded: Bool) -> [Row] {
        var rows: [Row] = []

        // Lane 0: the cw spine and its intermediate branches.
        for segment in graph.segments {
            let isIdentity = segment.kind == .currentWorktree
            let commits = expanded ? segment.commits : segment.collapsedCommits
            for (i, commit) in commits.enumerated() {
                rows.append(Row(
                    content: .commit(commit), lane: 0, isIdentity: isIdentity,
                    open: isIdentity && i == 0 && graph.hasUncommittedChanges,
                    label: i == 0 ? segment.branchLabel : nil,
                    forkBaseSHA: nil,
                    isDropSource: isIdentity,
                    isCherrySource: false,
                    rebaseBranch: i == 0 ? segment.branchLabel : nil))
            }
            if segment.isTruncatable && !expanded {
                rows.append(hiddenRow(segment.hiddenCount, lane: 0))
            }
        }

        // Lanes 1+: trunk-ahead, then each revealed branch.
        var nextLane = 1
        func appendLane(_ segment: GraphSegment, cherry: Bool) {
            let lane = nextLane; nextLane += 1
            let start = rows.count
            let commits = expanded ? segment.commits : segment.collapsedCommits
            for (i, commit) in commits.enumerated() {
                rows.append(Row(
                    content: .commit(commit), lane: lane, isIdentity: false, open: false,
                    label: i == 0 ? segment.branchLabel : nil,
                    forkBaseSHA: nil,
                    isDropSource: false,
                    isCherrySource: cherry,
                    rebaseBranch: i == 0 ? segment.branchLabel : nil))
            }
            if segment.isTruncatable && !expanded {
                rows.append(hiddenRow(segment.hiddenCount, lane: lane))
            }
            // The lane's oldest visible row carries the fork-join to its parent.
            if rows.count > start { rows[rows.count - 1].forkBaseSHA = segment.forkBase }
        }

        if let trunk = graph.trunkAhead { appendLane(trunk, cherry: false) }
        for revealed in graph.revealedLanes { appendLane(revealed, cherry: true) }

        if let meeting = graph.meetingCommit {
            rows.append(Row(
                content: .meeting(meeting), lane: 0, isIdentity: false, open: false,
                label: nil, forkBaseSHA: nil, isDropSource: false, isCherrySource: false, rebaseBranch: nil))
        }
        return rows
    }

    private static func hiddenRow(_ count: Int, lane: Int) -> Row {
        Row(content: .hidden(count), lane: lane, isIdentity: false, open: false,
            label: nil, forkBaseSHA: nil, isDropSource: false, isCherrySource: false, rebaseBranch: nil)
    }
}
