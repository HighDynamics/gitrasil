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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
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

            if store.isRefreshing {
                ProgressView().controlSize(.small)
            }
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

            if let detail {
                CommitDetailPanel(
                    detail: detail,
                    selectedPath: selectedFile?.path,
                    onSelectFile: selectFile,
                    onClose: clearSelection
                )
                .frame(minHeight: 140, idealHeight: 220)
            }
        }
    }

    private func hasTruncation(_ graph: HistoryGraph) -> Bool {
        graph.segments.contains(where: \.isTruncatable) || (graph.trunkAhead?.isTruncatable ?? false)
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
