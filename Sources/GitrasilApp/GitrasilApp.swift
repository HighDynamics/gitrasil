import SwiftUI
import AppKit
import GitrasilCore

/// Opens a repository (auto from an argument, or via a picker) and hosts its worktree tabs — one
/// tab per worktree, via `RepositoryStore`.
struct RootView: View {
    @State private var repo: RepositoryStore?

    var body: some View {
        Group {
            if let repo {
                RepositoryView(repo: repo)
            } else {
                OpenRepoView(onOpen: open)
            }
        }
        .task {
            // Auto-open a repo passed as the first CLI argument, if it looks like one.
            guard repo == nil, CommandLine.arguments.count > 1 else { return }
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            if isRepository(url) { open(url) }
        }
    }

    private func open(_ url: URL) {
        let repo = RepositoryStore(anchorURL: url)
        self.repo = repo
        Task { await repo.start() }
    }

    private func isRepository(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }
}

struct OpenRepoView: View {
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("gitrasil").font(.system(size: 34, weight: .bold))
            Text("Open a git repository to view a worktree.")
                .foregroundStyle(.secondary)
            Button("Open Repository…", action: pick)
                .keyboardShortcut("o", modifiers: .command)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { onOpen(url) }
    }
}
