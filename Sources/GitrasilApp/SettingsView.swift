import SwiftUI
import GitrasilCore

/// App settings (⌘,). Currently the external diff tool used by the "Open in external diff tool"
/// handoff — the user's global `diff.guitool`, switchable at any time. Reads/writes global git
/// config, so it runs against a home-directory runner rather than any one worktree.
struct SettingsView: View {
    /// `git config --global` ignores the working directory, so any valid cwd works; use $HOME.
    private let runner = GitRunner(
        workdir: FileManager.default.homeDirectoryForCurrentUser,
        extraEnvironment: GitRunner.appEnvironment)

    @State private var tools: [DiffToolOption] = []
    /// The picker selection: a tool id, or "" for "ask each time" (no configured default).
    @State private var selection = ""
    @State private var loaded = false

    /// Sentinel tag for "no configured default" — the Files/commit control will prompt each time.
    private let askEachTime = ""

    var body: some View {
        Form {
            Section("External diff tool") {
                if !loaded {
                    ProgressView().controlSize(.small)
                } else if tools.isEmpty {
                    Text("No diff tool available.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Diff tool", selection: $selection) {
                        Text("Ask each time").tag(askEachTime)
                        ForEach(tools) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: selection) { _, new in apply(new) }
                    Text("Used when you choose “Open in external diff tool.”")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .task { await load() }
    }

    private func load() async {
        let installed = try? await DiffTool.installedGUITools(runner: runner)
        tools = installed ?? []
        selection = await DiffTool.configuredTool(runner: runner) ?? askEachTime
        loaded = true
    }

    private func apply(_ new: String) {
        Task {
            if new.isEmpty {
                try? await DiffTool.clearDefaultTool(runner: runner)
            } else {
                try? await DiffTool.setDefaultTool(new, runner: runner)
            }
        }
    }
}
