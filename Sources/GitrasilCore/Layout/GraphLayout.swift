import Foundation

/// One row of the laid-out history graph: a commit (or the meeting commit, or a "N hidden" marker)
/// placed in a lane. The layout is pure — lanes and fork joins, no pixels — so a renderer (the live
/// desktop background) only decides how it looks.
public struct GraphRow: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case commit(CommitNode)
        case meeting(CommitNode)
        case hidden(Int)
    }

    public let content: Content
    /// 0 = the current-worktree spine (drawn right-most); higher lanes are fork lanes to its left.
    public let lane: Int
    public let isIdentity: Bool
    public let open: Bool
    public let label: String?
    public var forkBaseSHA: String?
    /// Which overlap sliver this lane's fork *target* lands on — 0 for the commit's main dot, n for the
    /// n-th sliver out — so a branch created off an overlapping worktree joins that worktree's offset
    /// sliver rather than the shared commit's main dot. Renderers scale it by their sliver offset.
    public var forkTargetSliver: Int = 0
    /// The branch this row's lane represents (intermediate / trunk-ahead / revealed), used to color a
    /// lane by its worktree's identity color. `nil` for the cw spine (colored by `isIdentity`) and
    /// the meeting.
    public var branch: String? = nil
    /// Revealed branches that point at this exact commit but have no commits of their own — shown as
    /// extra ref pills (a worktree parked at an intermediary, say).
    public var extraLabels: [String] = []

    public var isMeeting: Bool { if case .meeting = content { return true } else { return false } }
    public var commit: CommitNode? {
        switch content {
        case .commit(let c), .meeting(let c): return c
        case .hidden: return nil
        }
    }
}

public enum GraphLayout {

    /// If `branch` was created off one of the worktrees overlapping `forkBase` (a recorded/backfilled
    /// origin), the sliver (1-based) its fork should join — so the fork joins the source worktree
    /// there rather than the shared commit's main dot. `nil` when the origin is unknown or isn't one
    /// of the overlappers.
    public static func sliverAttribution(branch: String?, forkBase: String?, graph: HistoryGraph) -> Int? {
        guard let branch, let forkBase,
              let parent = graph.branchParents[branch],
              let slivers = graph.revealedPointers[forkBase],
              let rank = slivers.firstIndex(of: parent) else { return nil }
        return rank + 1
    }

    /// Flatten the graph into rows, newest at the top and the meeting commit at the bottom.
    ///
    /// Lanes follow `git log --graph`: the current-worktree spine is lane 0 (right-most). Trunk-ahead
    /// is lane 1; further branches add lanes to the left. A branch that is the *first* to fork from a
    /// lane's current tip continues straight up in that lane (a chain stacks into one line); a second
    /// branch off the same commit takes a new lane to the left and joins with an angular fork.
    public static func rows(for graph: HistoryGraph, expanded: Bool) -> [GraphRow] {
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

        // A revealed branch that forks off the cw's tip is not a divergence — it's the cw's line
        // continued (cw + N commits ahead). Pull the first such lane out to render straight above the
        // cw spine in lane 0 (its own color, no fork); any further ones fork normally. The fork point
        // is the commit, so overlapping worktrees sharing that tip don't change this.
        // The cw's line continues with an ahead-branch off its tip — but only one that belongs to the
        // cw (unknown origin, or the cw itself). A branch created off an overlapping worktree stays a
        // fork lane so it can join that worktree's sliver instead.
        let cwTip = graph.segments.first?.commits.first?.sha
        var cwAhead: [GraphSegment] = []
        if let cwTip, let idx = laneSegments.firstIndex(where: { chain in
            chain.first?.forkBase == cwTip
                && sliverAttribution(branch: chain.first?.branchLabel, forkBase: cwTip, graph: graph) == nil
        }) {
            cwAhead = laneSegments.remove(at: idx)
        }

        // Order lanes as a forest so each branch sits next to the lane it forks from and each subtree
        // stays contiguous — a branch off main is drawn right beside main, not sorted purely by depth
        // (which could place it beyond an unrelated branch and cross over it). A lane whose fork point
        // lands on another lane is that lane's child, drawn just outside it; a lane forking off the cw
        // spine is a root. Roots (and siblings) are ordered by fork proximity to cw: shallower fork
        // depth → nearer cw. Ties keep reveal order, so a lane on screen keeps its place.
        var commitLane: [String: Int] = [:]
        for (i, chain) in laneSegments.enumerated() {
            for segment in chain { for commit in segment.commits { commitLane[commit.sha] = i } }
        }
        var children = [[Int]](repeating: [], count: laneSegments.count)
        var roots: [Int] = []
        for i in laneSegments.indices {
            if let base = laneSegments[i].first?.forkBase, let parent = commitLane[base], parent != i {
                children[parent].append(i)
            } else {
                roots.append(i)
            }
        }
        func forkDepth(_ i: Int) -> Int {
            (laneSegments[i].first?.forkBase).flatMap { spineDepth[$0] } ?? belowMeeting
        }
        // How far left this lane's fork lands: 0 for the main dot, larger for a further-out sliver.
        // Ordering siblings by it keeps an inner-sliver lane inside an outer-sliver one, so attributed
        // forks don't cross regardless of reveal order.
        func targetSliver(_ i: Int) -> Int {
            sliverAttribution(branch: laneSegments[i].first?.branchLabel,
                              forkBase: laneSegments[i].first?.forkBase, graph: graph) ?? 0
        }
        func ordered(_ lanes: [Int]) -> [Int] {
            lanes.sorted { a, b in
                if forkDepth(a) != forkDepth(b) { return forkDepth(a) < forkDepth(b) }
                if targetSliver(a) != targetSliver(b) { return targetSliver(a) < targetSliver(b) }
                return a < b
            }
        }
        var order: [Int] = []
        func visit(_ i: Int) { order.append(i); ordered(children[i]).forEach(visit) }
        ordered(roots).forEach(visit)
        laneSegments = order.map { laneSegments[$0] }

        var rows: [GraphRow] = []

        // Fork lanes, left-most (highest lane index) first so branches fan upward to the left.
        for (index, segments) in laneSegments.enumerated().reversed() {
            let lane = index + 1
            rows.append(contentsOf: forkLaneRows(segments, lane: lane, expanded: expanded))
        }

        // The cw's ahead-continuation, straight above the spine in lane 0 (no fork). Rendered in its
        // own color (a .revealed segment), so it reads as that branch's commits ahead of the cw's tip.
        for segment in cwAhead.reversed() {
            rows.append(contentsOf: laneRows(segment, lane: 0, isIdentity: false,
                                             dirty: false, expanded: expanded))
        }

        // cw spine (lane 0), lowest branch: cw's commits, then its intermediates, newest→oldest.
        for segment in graph.segments {
            rows.append(contentsOf: laneRows(segment, lane: 0,
                                             isIdentity: segment.kind == .currentWorktree,
                                             dirty: graph.hasUncommittedChanges,
                                             expanded: expanded))
        }

        // The diverging point, bottom-most.
        if let meeting = graph.meetingCommit {
            rows.append(GraphRow(content: .meeting(meeting), lane: 0, isIdentity: false, open: false,
                                 label: nil, forkBaseSHA: nil))
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

        // Route each fork's join to its source worktree's sliver when its origin is one of the
        // worktrees overlapping the fork commit (attribution); others join the commit's main dot.
        if !graph.branchParents.isEmpty {
            for i in rows.indices where rows[i].forkBaseSHA != nil {
                if let sliver = sliverAttribution(branch: rows[i].branch, forkBase: rows[i].forkBaseSHA, graph: graph) {
                    rows[i].forkTargetSliver = sliver
                }
            }
        }
        return rows
    }

    /// Rows for one fork lane (its stacked segments, top→bottom). Continuations sit contiguously
    /// above the segment they extend (a straight in-lane line); only the lane's bottom segment
    /// carries the angular join down to the commit it forks from.
    private static func forkLaneRows(_ segments: [GraphSegment], lane: Int, expanded: Bool) -> [GraphRow] {
        var out: [GraphRow] = []
        for segment in segments.reversed() {   // top (newest continuation) → bottom (base)
            out.append(contentsOf: laneRows(segment, lane: lane, isIdentity: false,
                                            dirty: false, expanded: expanded))
        }
        if let base = segments.first, !out.isEmpty { out[out.count - 1].forkBaseSHA = base.forkBase }
        return out
    }

    /// A segment's rows, newest→oldest, with truncation shown as a hidden marker below the tip and
    /// the branch label on the newest (tip) commit.
    private static func laneRows(_ segment: GraphSegment, lane: Int, isIdentity: Bool,
                                 dirty: Bool, expanded: Bool) -> [GraphRow] {
        var out: [GraphRow] = []
        if segment.isTruncatable && !expanded {
            if let tip = segment.collapsedCommits.first {
                out.append(commitRow(tip, lane: lane, isIdentity: isIdentity, isTip: true,
                                     dirty: dirty, label: segment.branchLabel,
                                     branch: segment.branchLabel))
            }
            out.append(GraphRow(content: .hidden(segment.hiddenCount), lane: lane, isIdentity: false,
                                open: false, label: nil, forkBaseSHA: nil, branch: segment.branchLabel))
        } else {
            for (i, commit) in segment.commits.enumerated() {   // newest → oldest
                let isTip = i == 0
                out.append(commitRow(commit, lane: lane, isIdentity: isIdentity, isTip: isTip,
                                     dirty: dirty,
                                     label: isTip ? segment.branchLabel : nil,
                                     branch: segment.branchLabel))
            }
        }
        return out
    }

    private static func commitRow(_ commit: CommitNode, lane: Int, isIdentity: Bool, isTip: Bool,
                                  dirty: Bool, label: String?, branch: String?) -> GraphRow {
        GraphRow(content: .commit(commit), lane: lane, isIdentity: isIdentity,
                 open: isIdentity && isTip && dirty,
                 label: label, forkBaseSHA: nil, branch: branch)
    }
}
