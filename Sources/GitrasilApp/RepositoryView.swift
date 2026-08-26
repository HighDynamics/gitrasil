import SwiftUI
import GitrasilCore

/// The repository window's chrome: a worktree tab strip over the selected worktree's view. One
/// window = one repository, one tab = one worktree. The tab strip only appears once there's more
/// than one worktree; a lone worktree fills the window as before.
struct RepositoryView: View {
    let repo: RepositoryStore

    var body: some View {
        VStack(spacing: 0) {
            if repo.worktrees.count > 1 {
                tabStrip
                Divider()
            }
            content
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(repo.worktrees) { worktree in
                    tab(worktree)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
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
                            identityColor: Palette.identity(repo.colorIndex(for: path)))
                .id(path)
        } else if let error = repo.lastError {
            CenteredMessage(text: error, isError: true)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
