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
    var identityColor: Color = Palette.worktreeColors[0]
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

    private var rows: [Row] { Row.build(from: graph, expanded: expandTruncated) }
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

    private func scrollToHead(_ proxy: ScrollViewProxy, rows: [Row], headSHA: String?) {
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

    private func drawConnectors(_ rows: [Row], maxLane: Int, in context: inout GraphicsContext) {
        for lane in Set(rows.map(\.lane)) {
            let indices = rows.indices.filter { rows[$0].lane == lane }
            for (a, b) in zip(indices, indices.dropFirst()) {
                var path = Path()
                path.move(to: CGPoint(x: laneX(lane, maxLane: maxLane), y: y(a)))
                path.addLine(to: CGPoint(x: laneX(lane, maxLane: maxLane), y: y(b)))
                let color = rows[a].isIdentity ? identityColor : Color.gray.opacity(0.55)
                context.stroke(path, with: .color(color), lineWidth: 2)
            }
        }
    }

    /// A forking lane joins the commit it branches from with an angular path: straight down its own
    /// lane to just above the parent, then a single diagonal step into it — so the branch is fully
    /// in its lane by the row above the fork.
    private func drawForks(_ rows: [Row], maxLane: Int, in context: inout GraphicsContext) {
        let meeting = rows.lastIndex { $0.isMeeting }
        for (index, row) in rows.enumerated() {
            guard let forkBase = row.forkBaseSHA else { continue }
            guard let target = (rows.firstIndex { $0.commit?.sha == forkBase } ?? meeting),
                  target > index else { continue }
            let sourceX = laneX(row.lane, maxLane: maxLane)
            let targetX = laneX(rows[target].lane, maxLane: maxLane)
            var path = Path()
            path.move(to: CGPoint(x: sourceX, y: y(index)))
            if target - 1 > index {
                path.addLine(to: CGPoint(x: sourceX, y: y(target - 1)))   // stay in-lane…
            }
            path.addLine(to: CGPoint(x: targetX, y: y(target)))          // …then one diagonal step
            context.stroke(path, with: .color(Color.gray.opacity(0.55)), lineWidth: 2)
        }
    }

    private func drawDots(_ rows: [Row], maxLane: Int, in context: inout GraphicsContext) {
        for (index, row) in rows.enumerated() {
            guard let commit = row.commit else { continue }
            let center = CGPoint(x: laneX(row.lane, maxLane: maxLane), y: y(index))
            if selectedSHAs.contains(commit.sha) {
                let halo = CGRect(x: center.x - dotRadius - 4, y: center.y - dotRadius - 4,
                                  width: (dotRadius + 4) * 2, height: (dotRadius + 4) * 2)
                context.fill(Path(ellipseIn: halo), with: .color(identityColor.opacity(0.25)))
            }
            let color = row.isIdentity ? identityColor : Color.gray
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
    let identityColor: Color
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
        Text(text)
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
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

// MARK: - Row model

private struct Row {
    enum Content {
        case commit(CommitNode)
        case meeting(CommitNode)
        case hidden(Int)
    }

    let content: Content
    /// 0 = the current-worktree spine (drawn right-most); higher lanes are fork lanes to its left.
    let lane: Int
    let isIdentity: Bool
    let open: Bool
    let label: String?
    var forkBaseSHA: String?
    let isDropSource: Bool
    let isCherrySource: Bool
    let rebaseBranch: String?
    /// Revealed branches that point at this exact commit but have no commits of their own — shown as
    /// extra ref pills (a worktree parked at an intermediary, say).
    var extraLabels: [String] = []

    var isMeeting: Bool { if case .meeting = content { return true } else { return false } }
    var commit: CommitNode? {
        switch content {
        case .commit(let c), .meeting(let c): return c
        case .hidden: return nil
        }
    }

    /// Flatten the graph into rows, newest at the top and the meeting commit at the bottom.
    ///
    /// Lanes follow `git log --graph`: the current-worktree spine is lane 0 (right-most). Trunk-ahead
    /// is lane 1; further branches add lanes to the left. A branch that is the *first* to fork from a
    /// lane's current tip continues straight up in that lane (a chain stacks into one line); a second
    /// branch off the same commit takes a new lane to the left and joins with an angular fork.
    static func build(from graph: HistoryGraph, expanded: Bool) -> [Row] {
        // Depth of every commit on cw's spine (cw's own commits, then intermediaries, newest→oldest)
        // and the meeting at the bottom. A fork lane is ordered by how deep its fork point sits: the
        // shallower (closer to cw's tip), the nearer cw it's drawn.
        var spineDepth: [String: Int] = [:]
        var depthCursor = 0
        for segment in graph.segments {
            for commit in segment.commits { spineDepth[commit.sha] = depthCursor; depthCursor += 1 }
        }
        if let meeting = graph.meetingCommit { spineDepth[meeting.sha] = depthCursor; depthCursor += 1 }
        // Continue depth up main's ahead-commits (oldest→newest), past the meeting: a branch that
        // forks off one of them is farther from cw than main's own meeting fork, so it sorts beyond
        // main — deterministically, by where on main it forks — instead of all landing at a single
        // fallback depth.
        for commit in (graph.trunkAhead?.commits.reversed() ?? []) {
            spineDepth[commit.sha] = depthCursor; depthCursor += 1
        }
        let belowMeeting = depthCursor   // fork points on nothing drawn sort outermost of all

        // Assign fork branches to lanes. `laneSegments[i]` is one lane, bottom→top; `laneTops[i]` is
        // that lane's current tip SHA (advances as continuations stack on top).
        var laneSegments: [[GraphSegment]] = []
        var laneTops: [String] = []

        func addBranch(_ segment: GraphSegment) {
            if let base = segment.forkBase, let i = laneTops.firstIndex(of: base) {
                laneSegments[i].append(segment)                       // continue this lane
                laneTops[i] = segment.commits.first?.sha ?? laneTops[i]
            } else {
                laneSegments.append([segment])                        // new lane
                laneTops.append(segment.commits.first?.sha ?? "")
            }
        }
        if let trunk = graph.trunkAhead { addBranch(trunk) }
        for revealed in graph.revealedLanes { addBranch(revealed) }

        // Order lanes by fork proximity to cw: a lane's fork point is its base (first) segment's
        // forkBase; shallower depth → inner lane (nearer cw). A branch that forks off cw's own spine
        // therefore sits inside main, which forks at the meeting — so main is drawn outside every
        // spine-rooted branch. (A branch that instead forks off one of main's own ahead-commits sits
        // further out still.) The sort is stable on the original order so equal-depth lanes keep their
        // reveal order — a lane already on screen never swaps places when another is revealed.
        func forkDepth(_ chain: [GraphSegment]) -> Int {
            guard let base = chain.first?.forkBase else { return belowMeeting }
            return spineDepth[base] ?? belowMeeting
        }
        laneSegments = laneSegments.enumerated()
            .sorted { a, b in
                let da = forkDepth(a.element), db = forkDepth(b.element)
                return da == db ? a.offset < b.offset : da < db
            }
            .map(\.element)

        var rows: [Row] = []

        // Fork lanes, left-most (highest lane index) first so branches fan upward to the left.
        for (index, segments) in laneSegments.enumerated().reversed() {
            let lane = index + 1
            rows.append(contentsOf: forkLaneRows(segments, lane: lane, expanded: expanded))
        }

        // cw spine (lane 0), lowest branch: cw's commits, then its intermediates, newest→oldest.
        for segment in graph.segments {
            rows.append(contentsOf: laneRows(segment, lane: 0,
                                             isIdentity: segment.kind == .currentWorktree,
                                             dirty: graph.hasUncommittedChanges,
                                             cherry: false, expanded: expanded))
        }

        // The diverging point, bottom-most.
        if let meeting = graph.meetingCommit {
            rows.append(Row(content: .meeting(meeting), lane: 0, isIdentity: false, open: false,
                            label: nil, forkBaseSHA: nil, isDropSource: false,
                            isCherrySource: false, rebaseBranch: nil))
        }

        // Attach ref pills for revealed branches that point at a drawn commit but add no commits.
        if !graph.revealedPointers.isEmpty {
            var matched = Set<String>()
            for i in rows.indices {
                if let sha = rows[i].commit?.sha, let names = graph.revealedPointers[sha] {
                    rows[i].extraLabels = names
                    matched.insert(sha)
                }
            }
            // A pointer whose tip is behind the meeting (an ancestor of it) matches no drawn row;
            // anchor it on the meeting commit so the branch still surfaces instead of vanishing —
            // exactly the drop this mechanism exists to prevent.
            let orphaned = graph.revealedPointers.filter { !matched.contains($0.key) }
                .flatMap(\.value).sorted()
            if !orphaned.isEmpty, let meetingIndex = rows.lastIndex(where: { $0.isMeeting }) {
                rows[meetingIndex].extraLabels += orphaned
            }
        }
        return rows
    }

    /// Rows for one fork lane (its stacked segments, top→bottom). Continuations sit contiguously
    /// above the segment they extend (a straight in-lane line); only the lane's bottom segment
    /// carries the angular join down to the commit it forks from.
    private static func forkLaneRows(_ segments: [GraphSegment], lane: Int, expanded: Bool) -> [Row] {
        var out: [Row] = []
        for segment in segments.reversed() {   // top (newest continuation) → bottom (base)
            let cherry: Bool = { if case .revealed = segment.kind { return true } else { return false } }()
            out.append(contentsOf: laneRows(segment, lane: lane, isIdentity: false,
                                            dirty: false, cherry: cherry, expanded: expanded))
        }
        if let base = segments.first, !out.isEmpty { out[out.count - 1].forkBaseSHA = base.forkBase }
        return out
    }

    /// A segment's rows, newest→oldest, with truncation shown as a hidden marker below the tip and
    /// the branch label on the newest (tip) commit.
    private static func laneRows(_ segment: GraphSegment, lane: Int, isIdentity: Bool,
                                 dirty: Bool, cherry: Bool, expanded: Bool) -> [Row] {
        var out: [Row] = []
        if segment.isTruncatable && !expanded {
            if let tip = segment.collapsedCommits.first {
                out.append(commitRow(tip, lane: lane, isIdentity: isIdentity, isTip: true,
                                     dirty: dirty, cherry: cherry, label: segment.branchLabel))
            }
            out.append(Row(content: .hidden(segment.hiddenCount), lane: lane, isIdentity: false,
                           open: false, label: nil, forkBaseSHA: nil, isDropSource: false,
                           isCherrySource: false, rebaseBranch: nil))
        } else {
            for (i, commit) in segment.commits.enumerated() {   // newest → oldest
                let isTip = i == 0
                out.append(commitRow(commit, lane: lane, isIdentity: isIdentity, isTip: isTip,
                                     dirty: dirty, cherry: cherry,
                                     label: isTip ? segment.branchLabel : nil))
            }
        }
        return out
    }

    private static func commitRow(_ commit: CommitNode, lane: Int, isIdentity: Bool, isTip: Bool,
                                  dirty: Bool, cherry: Bool, label: String?) -> Row {
        Row(content: .commit(commit), lane: lane, isIdentity: isIdentity,
            open: isIdentity && isTip && dirty,
            label: label, forkBaseSHA: nil,
            isDropSource: isIdentity, isCherrySource: cherry,
            rebaseBranch: isTip ? label : nil)
    }
}
