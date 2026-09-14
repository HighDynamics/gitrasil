import AppKit
import Foundation
import Observation
import GitrasilCore

/// App-wide external-diff-tool preference: the installed GUI tools and the configured default,
/// backed by the user's global git config (`diff.guitool`). A single instance is shared between
/// the Settings window and every worktree tab, so changing the default in Settings is reflected
/// immediately wherever the "Open in external diff tool" control lives.
///
/// (Previously each tab cached the configured tool once. Clearing the default in Settings left a
/// tab still launching the stale default via `-g` — and with the config now empty, git's `-g`
/// auto-fallback silently opened whatever tool it found first.)
@MainActor
@Observable
final class DiffToolSettings {
    /// GUI diff tools installed on this machine (drives the picker when no default is set).
    private(set) var available: [DiffToolOption] = []
    /// The configured default tool id, or nil to ask which to use.
    private(set) var configured: String?
    private(set) var loaded = false

    /// `git config --global` ignores the working directory, so any valid cwd works; use $HOME.
    private let runner: GitRunning = GitRunner(
        workdir: FileManager.default.homeDirectoryForCurrentUser,
        extraEnvironment: GitRunner.appEnvironment)

    /// Load once (on first appearance). Later changes flow through `setDefault`/`clearDefault`.
    func loadIfNeeded() async {
        guard !loaded else { return }
        await reload()
    }

    /// Re-read the configured default and the tools to offer: git's recognized candidates, narrowed
    /// to those whose macOS app is actually installed (LaunchServices) — git's own availability
    /// check false-positives (e.g. Araxis via a stray `compare` binary), and that failure is
    /// silent, so we verify the real app here.
    func reload() async {
        let candidates = (try? await DiffTool.candidateGUITools(runner: runner)) ?? []
        available = candidates.filter { Self.isInstalled($0.id) }
        configured = await DiffTool.configuredTool(runner: runner)
        loaded = true
    }

    /// Whether a recognized diff tool's app is installed, checked against LaunchServices by the
    /// bundle ids mapped in `DiffTool.appBundleIDs`.
    private static func isInstalled(_ toolID: String) -> Bool {
        (DiffTool.appBundleIDs[toolID] ?? []).contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    /// Persist `id` as the default GUI diff tool and reflect it immediately.
    func setDefault(_ id: String) async {
        try? await DiffTool.setDefaultTool(id, runner: runner)
        configured = id
    }

    /// Clear the default so the picker asks which tool to use each time.
    func clearDefault() async {
        try? await DiffTool.clearDefaultTool(runner: runner)
        configured = nil
    }
}
