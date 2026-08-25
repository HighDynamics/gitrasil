import SwiftUI
import SwiftTerm

/// The embedded terminal (design brief §8): a real PTY scoped to the worktree directory, via
/// SwiftTerm's LocalProcessTerminalView. The user's own git commands here flow back through the
/// store's FSEvents refresh, so side effects update the rest of the view.
struct TerminalView: NSViewRepresentable {
    let workingDirectory: URL

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        let envArray = environment.map { "\($0.key)=\($0.value)" }

        // cd into the worktree, then exec an interactive login shell there.
        let command = "cd \(shellQuote(workingDirectory.path)) && exec \(shell) -il"
        view.startProcess(executable: "/bin/sh", args: ["-c", command], environment: envArray)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The collapsible terminal panel: a titled strip plus the terminal itself.
struct TerminalPanel: View {
    let workingDirectory: URL

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 11))
                Text("Terminal").font(.system(size: 12, weight: .semibold))
                Text(workingDirectory.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            TerminalView(workingDirectory: workingDirectory)
        }
    }
}
