import SwiftUI
import GitrasilCore

/// One worktree tab: identity/status header over the history graph. The file viewer, explorer,
/// terminal, and mutations are later work — this first cut renders the signature graph from a
/// live, reactive snapshot.
struct WorktreeTabView: View {
    let store: WorktreeStore
    @State private var expandTruncated = false

    @State private var selectedCommit: CommitNode?
    @State private var detail: CommitDetail?
    @State private var selectedFile: FileChange?
    @State private var diff: FileDiff?
    @State private var isLoadingDiff = false

    enum NavMode: String, CaseIterable { case history = "History", files = "Files" }
    @State private var navMode: NavMode = .history
    @State private var explorerStatus: [String: WorkingFileStatus] = [:]
    @State private var explorerIgnored: Set<String> = []
    @State private var selectedExplorerPath: String?

    @State private var showTerminal = true
    @State private var availableBranches: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showTerminal {
                VSplitView {
                    content.frame(minHeight: 220)
                    TerminalPanel(workingDirectory: store.worktreeURL)
                        .frame(minHeight: 120, idealHeight: 200)
                }
            } else {
                content
            }
        }
    }

    // MARK: Selection flow

    private func selectCommit(_ commit: CommitNode) {
        selectedCommit = commit
        selectedFile = nil
        diff = nil
        detail = nil
        Task { detail = try? await store.commitDetail(sha: commit.sha) }
    }

    private func selectFile(_ file: FileChange) {
        guard let commit = selectedCommit else { return }
        selectedFile = file
        isLoadingDiff = true
        Task {
            diff = try? await store.fileDiff(
                source: .commit(sha: commit.sha, shortSHA: commit.shortSHA), path: file.path)
            isLoadingDiff = false
        }
    }

    private func clearSelection() {
        selectedCommit = nil; detail = nil; selectedFile = nil; diff = nil
    }

    private func openExplorerFile(_ path: String, meetingBase: String?) {
        guard let meetingBase else { return }
        selectedExplorerPath = path
        isLoadingDiff = true
        Task {
            diff = try? await store.fileDiff(source: .explorer(meetingBase: meetingBase), path: path)
            isLoadingDiff = false
        }
    }

    private func loadExplorerData() async {
        if let data = try? await store.explorerData() {
            explorerStatus = data.status
            explorerIgnored = data.ignored
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(Palette.identity).frame(width: 12, height: 12)

            Text(branchLabel).font(.system(size: 15, weight: .semibold))

            if let badge = store.snapshot?.badge {
                BadgeView(badge: badge)
            }

            if let between = store.snapshot?.graph.branchesBetween, between > 0 {
                Pill(text: between == 1 ? "1 branch between" : "\(between) branches between")
            }

            Spacer()

            if let snapshot = store.snapshot, snapshot.statusFacts.behind, isMutable(snapshot),
               let trunk = snapshot.trunkRef {
                Button {
                    Task { await store.rebaseOnto(target: trunk) }
                } label: {
                    Label("Rebase onto \(snapshot.trunkName ?? trunk)", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.borderless)
            }

            if store.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button { Task { await store.undo() } } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            Button { showTerminal.toggle() } label: {
                Label("Terminal", systemImage: "terminal")
            }
            .buttonStyle(.borderless)
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var branchLabel: String {
        switch store.snapshot?.branch {
        case .branch(let name): return name
        case .detached(let sha): return "detached @ \(sha)"
        case nil: return "…"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            OperationBar(
                inProgress: store.snapshot?.inProgress,
                mutationError: store.mutationError,
                onContinue: { Task { await store.continueOperation() } },
                onAbort: { Task { await store.abortOperation() } },
                onDismiss: { store.dismissMutationError() }
            )
            mainContent
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if let snapshot = store.snapshot {
            if snapshot.graph.isEmpty {
                CenteredMessage(text: "No commits yet")
            } else {
                HSplitView {
                    navigationColumn(snapshot)
                        .frame(minWidth: 320, idealWidth: 380)
                    FileViewer(diff: diff, isLoading: isLoadingDiff)
                        .frame(minWidth: 360)
                }
            }
        } else if let error = store.lastError {
            CenteredMessage(text: error, isError: true)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The left navigation column: a History / Files toggle over either the history graph (with the
    /// commit detail panel docked below on selection) or the directory explorer (design brief §7).
    @ViewBuilder
    private func navigationColumn(_ snapshot: WorktreeSnapshot) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $navMode) {
                ForEach(NavMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()

            switch navMode {
            case .history:
                historyColumn(snapshot)
            case .files:
                FileTreeView(
                    rootURL: store.worktreeURL,
                    status: explorerStatus,
                    ignored: explorerIgnored,
                    selectedPath: selectedExplorerPath,
                    onOpen: { openExplorerFile($0, meetingBase: snapshot.graph.meetingCommit?.sha) }
                )
                .task(id: navMode) { await loadExplorerData() }
            }
        }
    }

    @ViewBuilder
    private func historyColumn(_ snapshot: WorktreeSnapshot) -> some View {
        VSplitView {
            VStack(spacing: 0) {
                branchesToolbar
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    HistoryGraphView(
                        graph: snapshot.graph,
                        expandTruncated: expandTruncated,
                        selectedSHA: selectedCommit?.sha,
                        onSelect: selectCommit
                    )
                    .padding(16)
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasTruncation(snapshot.graph) {
                        Button(expandTruncated ? "Collapse" : "Expand all") { expandTruncated.toggle() }
                            .buttonStyle(.bordered)
                            .padding(10)
                    }
                }
            }
            .task { await loadBranches() }

            if let detail {
                CommitDetailPanel(
                    detail: detail,
                    selectedPath: selectedFile?.path,
                    canDrop: selectedCommit.map(canDrop) ?? false,
                    canCherryPick: selectedCommit.map(canCherryPick) ?? false,
                    onSelectFile: selectFile,
                    onDrop: dropSelected,
                    onCherryPick: cherryPickSelected,
                    onClose: clearSelection
                )
                .frame(minHeight: 140, idealHeight: 220)
            }
        }
    }

    /// The "show other branches" control (design brief §5): reveal/hide branches as cherry-pick
    /// sources in the graph.
    private var branchesToolbar: some View {
        HStack(spacing: 8) {
            Menu {
                if availableBranches.isEmpty {
                    Text("No other branches").foregroundStyle(.secondary)
                }
                ForEach(availableBranches, id: \.self) { branch in
                    let revealed = store.revealedBranches.contains(branch)
                    Button {
                        Task { revealed ? await store.hide(branch) : await store.reveal(branch) }
                    } label: {
                        Label(branch, systemImage: revealed ? "checkmark" : "circle")
                    }
                }
            } label: {
                Label("Show branches", systemImage: "arrow.triangle.branch")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if !store.revealedBranches.isEmpty {
                Text(store.revealedBranches.sorted().joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func hasTruncation(_ graph: HistoryGraph) -> Bool {
        graph.segments.contains(where: \.isTruncatable)
            || (graph.trunkAhead?.isTruncatable ?? false)
            || graph.revealedLanes.contains(where: \.isTruncatable)
    }

    private func loadBranches() async {
        availableBranches = (try? await store.availableBranches()) ?? []
    }

    /// History edits are available only on a clean, attached worktree with no operation in flight.
    private func isMutable(_ snapshot: WorktreeSnapshot) -> Bool {
        !snapshot.statusFacts.dirty && !snapshot.isDetached && snapshot.inProgress == nil
    }

    /// A commit is droppable when it's on the worktree's own line and the worktree is mutable.
    private func canDrop(_ commit: CommitNode) -> Bool {
        guard let snapshot = store.snapshot, isMutable(snapshot) else { return false }
        let cw = snapshot.graph.segments.first { $0.kind == .currentWorktree }
        return cw?.commits.contains { $0.sha == commit.sha } ?? false
    }

    private func dropSelected() {
        guard let commit = selectedCommit else { return }
        Task { await store.drop(oldest: commit.sha, newest: commit.sha) }
    }

    /// A commit can be cherry-picked when it's on a revealed (other-branch) lane and the worktree
    /// is mutable.
    private func canCherryPick(_ commit: CommitNode) -> Bool {
        guard let snapshot = store.snapshot, isMutable(snapshot) else { return false }
        return snapshot.graph.revealedLanes.contains { lane in
            lane.commits.contains { $0.sha == commit.sha }
        }
    }

    private func cherryPickSelected() {
        guard let commit = selectedCommit else { return }
        Task { await store.cherryPick(oldest: commit.sha, newest: commit.sha) }
    }
}

// MARK: - Small components

enum Palette {
    /// The single worktree's identity color for v1 (per-worktree assignment is later work).
    static let identity = Color(red: 0.80, green: 0.40, blue: 0.20)
    static let grey = Color.secondary
}

struct BadgeView: View {
    let badge: StatusBadge

    var body: some View {
        Text(badge.rawValue)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(color, in: RoundedRectangle(cornerRadius: 5))
    }

    private var color: Color {
        switch badge {
        case .conflicted: return .red
        case .modified: return Color(red: 0.85, green: 0.6, blue: 0.1)
        case .behind: return .blue
        }
    }
}

struct Pill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }
}

struct CenteredMessage: View {
    let text: String
    var isError = false
    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
