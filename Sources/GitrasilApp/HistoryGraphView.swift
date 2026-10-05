import SwiftUI
import AppKit
import GitrasilCore

/// The full history graph. The diverging (meeting) commit is the bottom-most commit; branches fan
/// upward from it. The current worktree — with its intermediate ancestors — is the right-most lane
/// and the lowest branch (the first one off the diverging point), sitting just above the meeting.
/// Other branches (trunk-ahead, then revealed) stack above it and to the left, each joining the
/// commit it actually forks from. The view scrolls to HEAD by default.
///
/// A Canvas rail (dots + connectors) sits behind a column of SwiftUI commit rows; both share one
/// row height so they stay aligned. Rows carry per-commit metadata and reveal their contextual
/// mutation buttons on hover; shift-click extends a contiguous range.
struct HistoryGraphView: View {
    let graph: HistoryGraph
    /// The current worktree's identity color, used for its spine, dots, and selection highlight.
    var identityColor: Color = Palette.identity(0)
    /// Identity color per branch for branches that are themselves worktrees, so any lane that
    /// represents a worktree (a revealed branch, trunk, an intermediate) is drawn in that worktree's
    /// color rather than grey. Branches with no worktree stay grey.
    var worktreeColors: [String: Color] = [:]
    let expandTruncated: Bool
    let selectedSHAs: Set<String>
    let isMutable: Bool
    let mutabilityReason: String?
    var onSelect: (CommitNode, _ extend: Bool) -> Void = { _, _ in }
    var onDrop: (CommitNode) -> Void = { _ in }
    var onCherryPick: (CommitNode) -> Void = { _ in }
    var onRebase: (String) -> Void = { _ in }

    private let rowHeight: CGFloat = 52
    private let leadingPad: CGFloat = 18
    private let laneGap: CGFloat = 22
    private let dotRadius: CGFloat = 6

    private var rows: [GraphRow] { GraphLayout.rows(for: graph, expanded: expandTruncated) }
    private var headSHA: String? { graph.segments.first?.commits.first?.sha }

    var body: some View {
        let rows = self.rows
        let headSHA = self.headSHA
        let maxLane = rows.map(\.lane).max() ?? 0
        let railWidth = leadingPad + CGFloat(maxLane) * laneGap + dotRadius + 16
        let height = CGFloat(max(rows.count, 1)) * rowHeight
        // A definite content width: rows must NOT be maxWidth-flexible inside a horizontally
        // scrollable ScrollView, or the layout never stabilizes and SwiftUI re-lays-out forever.
        let contentWidth = railWidth + 560

        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        drawOverlapSlivers(rows, maxLane: maxLane, in: &context)
                        drawConnectors(rows, maxLane: maxLane, in: &context)
                        drawForks(rows, maxLane: maxLane, in: &context)
                        drawDots(rows, maxLane: maxLane, in: &context)
                    }
                    .frame(width: railWidth, height: height)
                    .allowsHitTesting(false)

                    // Rows span the full content width (the rail shows through behind them) and
                    // inset their content past the rail, so scrolling keeps the rail on-screen.
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            CommitRowView(
                                row: row,
                                identityColor: identityColor,
                                worktreeColors: worktreeColors,
                                leadingInset: railWidth,
                                isSelected: row.commit.map { selectedSHAs.contains($0.sha) } ?? false,
                                isMutable: isMutable,
                                mutabilityReason: mutabilityReason,
                                onTap: { extend in row.commit.map { onSelect($0, extend) } },
                                onDrop: { row.commit.map(onDrop) },
                                onCherryPick: { row.commit.map(onCherryPick) },
                                onRebase: onRebase
                            )
                            .frame(width: contentWidth, height: rowHeight)
                            .id(index)
                        }
                    }
                }
                .frame(width: contentWidth, height: height, alignment: .topLeading)
                .padding(16)
            }
            .onAppear { scrollToHead(proxy, rows: rows, headSHA: headSHA) }
            .onChange(of: headSHA) { _, _ in scrollToHead(proxy, rows: rows, headSHA: headSHA) }
            .onChange(of: rows.count) { _, _ in scrollToHead(proxy, rows: rows, headSHA: headSHA) }
        }
    }

    private func scrollToHead(_ proxy: ScrollViewProxy, rows: [GraphRow], headSHA: String?) {
        guard let headSHA, let index = rows.firstIndex(where: { $0.commit?.sha == headSHA }) else { return }
        // Center HEAD vertically but keep the rail pinned to the leading edge (x: 0), so scrolling
        // to HEAD doesn't push the lanes off-screen.
        DispatchQueue.main.async { proxy.scrollTo(index, anchor: UnitPoint(x: 0, y: 0.5)) }
    }

    // Row 0 at the top; newest commits toward the top, the meeting commit at the bottom. The
    // current-worktree lane (0) is the right-most.
    private func y(_ index: Int) -> CGFloat { CGFloat(index) * rowHeight + rowHeight / 2 }
    private func laneX(_ lane: Int, maxLane: Int) -> CGFloat {
        leadingPad + CGFloat(maxLane - lane) * laneGap
    }

    // MARK: Rail drawing

    /// The identity color of the worktree a row's lane represents, or nil for a lane that isn't a
    /// worktree (drawn grey). The cw spine resolves to `identityColor`.
    private func laneColor(_ row: GraphRow) -> Color? {
        if row.isIdentity { return identityColor }
        if let branch = row.branch { return worktreeColors[branch] }
        return nil
    }

    /// A stable identity for the spine segment a row belongs to, so a sliver knows how far its
    /// co-owned run extends: cw's own commits share one key; each intermediate branch its own.
    private func segmentKey(_ row: GraphRow) -> String {
        row.isIdentity ? "\u{0}cw" : (row.branch ?? "\u{0}none")
    }

    static let sliverOffset: CGFloat = 3

    /// A branch/worktree that shares another's line (a revealed pointer — no commits of its own) is
    /// drawn as an offset rail a few px to the left, *behind* the front lane, so it peeks out as a
    /// coloured sliver alongside the commits it owns — left, so the cw spine stays the rightmost.
    /// Multiple overlappers at one commit fan by the offset.
    ///
    /// The sliver spans only the overlapper's *owned* run (the front lane's identity commits); at the
    /// first commit it merely shares — an intermediary branch, or the meeting — it forks back into the
    /// front lane instead of running on as a parallel rail (which read as a phantom second branch).
    private func drawOverlapSlivers(_ rows: [GraphRow], maxLane: Int, in context: inout GraphicsContext) {
        guard !graph.revealedPointers.isEmpty else { return }
        for sha in graph.revealedPointers.keys.sorted() {
            guard let branches = graph.revealedPointers[sha],
                  let start = rows.firstIndex(where: { $0.commit?.sha == sha }) else { continue }
            let lane = rows[start].lane
            let run = (start..<rows.count).filter { rows[$0].lane == lane }
            // The overlapper co-owns the whole spine segment its anchor sits in — cw's own commits
            // when it's parked at cw's tip, or an intermediate branch's run when it's coincident with
            // a fork point deeper down. Below that segment the line belongs to another branch, so the
            // sliver forks back rather than running on as a phantom rail.
            let anchorKey = segmentKey(rows[start])
            let owned = Array(run.prefix { segmentKey(rows[$0]) == anchorKey })
            guard let firstOwned = owned.first, let lastOwned = owned.last else { continue }
            let rejoin = run.first { $0 > lastOwned }               // where it forks back into the shared line

            // Paint furthest-out first so each nearer sliver sits on top and every one peeks out —
            // otherwise a later, further sliver covers the earlier, nearer one.
            for (rank, branch) in branches.enumerated().reversed() {
                let dx = Self.sliverOffset * CGFloat(rank + 1)
                let color = worktreeColors[branch] ?? Color.gray.opacity(0.55)
                let x = laneX(lane, maxLane: maxLane) - dx   // left, keeping the cw spine rightmost
                var path = Path()
                path.move(to: CGPoint(x: x, y: y(firstOwned)))
                path.addLine(to: CGPoint(x: x, y: y(lastOwned)))
                if let rejoin {
                    path.addLine(to: CGPoint(x: laneX(rows[rejoin].lane, maxLane: maxLane), y: y(rejoin)))
                }
                context.stroke(path, with: .color(color), lineWidth: 2)
                for j in owned where rows[j].commit != nil {
                    let center = CGPoint(x: x, y: y(j))
                    let rect = CGRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                      width: dotRadius * 2, height: dotRadius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
    }

    private func drawConnectors(_ rows: [GraphRow], maxLane: Int, in context: inout GraphicsContext) {
        for lane in Set(rows.map(\.lane)) {
            let indices = rows.indices.filter { rows[$0].lane == lane }
            for (a, b) in zip(indices, indices.dropFirst()) {
                var path = Path()
                path.move(to: CGPoint(x: laneX(lane, maxLane: maxLane), y: y(a)))
                path.addLine(to: CGPoint(x: laneX(lane, maxLane: maxLane), y: y(b)))
                let color = laneColor(rows[a]) ?? Color.gray.opacity(0.55)
                context.stroke(path, with: .color(color), lineWidth: 2)
            }
        }
    }

    /// A forking lane joins the commit it branches from with an angular path: straight down its own
    /// lane to just above the parent, then a single diagonal step into it — so the branch is fully
    /// in its lane by the row above the fork.
    private func drawForks(_ rows: [GraphRow], maxLane: Int, in context: inout GraphicsContext) {
        let meeting = rows.lastIndex { $0.isMeeting }
        for (index, row) in rows.enumerated() {
            guard let forkBase = row.forkBaseSHA else { continue }
            guard let target = (rows.firstIndex { $0.commit?.sha == forkBase } ?? meeting),
                  target > index else { continue }
            let sourceX = laneX(row.lane, maxLane: maxLane)
            let targetDX = -Self.sliverOffset * CGFloat(row.forkTargetSliver)
            let targetX = laneX(rows[target].lane, maxLane: maxLane) + targetDX
            var path = Path()
            path.move(to: CGPoint(x: sourceX, y: y(index)))
            if target - 1 > index {
                path.addLine(to: CGPoint(x: sourceX, y: y(target - 1)))   // stay in-lane…
            }
            path.addLine(to: CGPoint(x: targetX, y: y(target)))          // …then one diagonal step
            let color = laneColor(row) ?? Color.gray.opacity(0.55)
            context.stroke(path, with: .color(color), lineWidth: 2)
        }
    }

    private func drawDots(_ rows: [GraphRow], maxLane: Int, in context: inout GraphicsContext) {
        for (index, row) in rows.enumerated() {
            guard let commit = row.commit else { continue }
            let center = CGPoint(x: laneX(row.lane, maxLane: maxLane), y: y(index))
            if selectedSHAs.contains(commit.sha) {
                let halo = CGRect(x: center.x - dotRadius - 4, y: center.y - dotRadius - 4,
                                  width: (dotRadius + 4) * 2, height: (dotRadius + 4) * 2)
                context.fill(Path(ellipseIn: halo), with: .color(identityColor.opacity(0.25)))
            }
            let color = laneColor(row) ?? Color.gray
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
    let row: GraphRow
    let identityColor: Color
    /// Branch → worktree identity color, so a ref pill for a branch that is a worktree is tinted its
    /// color instead of grey.
    let worktreeColors: [String: Color]
    let leadingInset: CGFloat
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
        .padding(.leading, leadingInset).padding(.trailing, 12)
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
                    if let label = row.label { refPill(label) }
                    ForEach(row.extraLabels, id: \.self) { refPill($0) }
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

    private func refPill(_ text: String) -> some View {
        // A branch that is a worktree gets its identity color; other refs stay grey.
        let color = worktreeColors[text]
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color ?? Color.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background((color ?? .gray).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
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
            .fill(isSelected ? identityColor.opacity(0.14) : (hovered ? Color.gray.opacity(0.08) : .clear))
            .padding(.horizontal, 4)
    }
}
