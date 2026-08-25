import SwiftUI
import AppKit
import GitrasilCore

@main
struct GitrasilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}

/// Ensures the app comes to the foreground with a normal window when launched via `swift run`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Opens a repository (auto from an argument, or via a picker) and hosts its worktree view.
/// v1 shows the repository's main worktree; the multi-tab / add-worktree flow is a later handoff.
struct RootView: View {
    @State private var store: WorktreeStore?

    var body: some View {
        Group {
            if let store {
                WorktreeTabView(store: store)
            } else {
                OpenRepoView(onOpen: open)
            }
        }
        .task {
            // Auto-open a repo passed as the first CLI argument, if it looks like one.
            guard store == nil, CommandLine.arguments.count > 1 else { return }
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            if isRepository(url) { open(url) }
        }
    }

    private func open(_ url: URL) {
        let store = WorktreeStore(worktreeURL: url)
        self.store = store
        Task { await store.start() }
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
