import SwiftUI
import GitrasilCore

/// The repository window's chrome: a worktree tab strip (with add/remove) over the selected
/// worktree's view. One window = one repository, one tab = one worktree.
struct RepositoryView: View {
    let repo: RepositoryStore

    /// Per-worktree terminal open/closed, remembered across tab switches. Absent = closed (the
    /// default): the terminal starts hidden and each tab keeps whatever the user last chose for it.
    @State private var terminalOpen: [URL: Bool] = [:]
    @State private var showingAddSheet = false
    @State private var worktreeToRemove: WorktreeInfo?

    /// Branch → identity color for every worktree that has a branch, so a worktree's branch is drawn
    /// in its own color wherever it appears in another worktree's graph. Branch names are unique
    /// across worktrees (git won't check out one branch in two worktrees).
    private var worktreeColors: [String: Color] {
        Dictionary(uniqueKeysWithValues: repo.worktrees.compactMap { worktree in
            worktree.branch.map { ($0, Palette.identity(repo.colorIndex(for: worktree.path))) }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            if let error = repo.actionError, !showingAddSheet {
                actionErrorBanner(error)
                Divider()
            }
            content
        }
        .sheet(isPresented: $showingAddSheet) {
            AddWorktreeSheet(repo: repo) { showingAddSheet = false; repo.dismissActionError() }
        }
        .confirmationDialog("Remove worktree?", isPresented: removeDialog, presenting: worktreeToRemove) { worktree in
            Button("Remove “\(label(worktree))”", role: .destructive) {
                Task { await repo.removeWorktree(worktree) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { worktree in
            Text("Removes the worktree at \(worktree.path.path). The branch itself is kept.")
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(repo.worktrees) { tab($0) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            Divider().frame(height: 20)
            addButton.padding(.horizontal, 6)   // pinned, so it stays reachable with many tabs
        }
    }

    private func tab(_ worktree: WorktreeInfo) -> some View {
        let selected = repo.selectedPath == worktree.path
        return Button {
            repo.select(worktree.path)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Palette.identity(repo.colorIndex(for: worktree.path)))
                    .frame(width: 9, height: 9)
                Text(label(worktree))
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(selected ? Color.gray.opacity(0.16) : Color.gray.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(worktree.path.path)
        .contextMenu {
            Button("Remove Worktree…", role: .destructive) { worktreeToRemove = worktree }
                .disabled(worktree.isMain)   // git refuses to remove the repository's main worktree
        }
    }

    private var addButton: some View {
        Button {
            repo.dismissActionError()
            showingAddSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add a worktree")
    }

    private func actionErrorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(error).font(.system(size: 12)).lineLimit(2)
            Spacer()
            Button { repo.dismissActionError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.red.opacity(0.08))
    }

    private var removeDialog: Binding<Bool> {
        Binding(get: { worktreeToRemove != nil }, set: { if !$0 { worktreeToRemove = nil } })
    }

    private func label(_ worktree: WorktreeInfo) -> String {
        if let branch = worktree.branch { return branch }
        if worktree.isDetached, let head = worktree.head { return "detached @ \(String(head.prefix(7)))" }
        return worktree.name
    }

    @ViewBuilder
    private var content: some View {
        if let path = repo.selectedPath {
            // `.id(path)` gives each worktree its own view identity, so switching tabs starts the
            // destination worktree with fresh selection/detail state rather than the prior tab's.
            WorktreeTabView(store: repo.store(for: path),
                            identityColor: Palette.identity(repo.colorIndex(for: path)),
                            worktreeColors: worktreeColors,
                            showTerminal: Binding(
                                get: { terminalOpen[path] ?? false },
                                set: { terminalOpen[path] = $0 }))
                .id(path)
        } else if let error = repo.lastError {
            CenteredMessage(text: error, isError: true)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
