import SwiftUI
import GitrasilCore

/// One worktree tab: identity/status header over the history graph. The file viewer, explorer,
/// terminal, and mutations are later work — this first cut renders the signature graph from a
/// live, reactive snapshot.
struct WorktreeTabView: View {
    let store: WorktreeStore
    @State private var expandTruncated = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
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
                ScrollView([.vertical, .horizontal]) {
                    HistoryGraphView(graph: snapshot.graph, expandTruncated: expandTruncated)
                        .padding(20)
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasTruncation(snapshot.graph) {
                        Button(expandTruncated ? "Collapse" : "Expand all") {
                            expandTruncated.toggle()
                        }
                        .buttonStyle(.bordered)
                        .padding(12)
                    }
                }
            }
        } else if let error = store.lastError {
            CenteredMessage(text: error, isError: true)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
