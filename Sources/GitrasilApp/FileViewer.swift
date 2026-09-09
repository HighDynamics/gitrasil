import SwiftUI
import GitrasilCore

/// State and actions for the external-diff-tool control. When a tool is configured, the control is
/// a plain button; otherwise it's a menu of installed GUI tools with an "always use this
/// application" toggle that persists the pick. When no GUI tool is installed, it's disabled and
/// says so.
struct DiffToolControlModel {
    /// At least one GUI diff tool is installed.
    let isAvailable: Bool
    /// The configured default tool id, or nil to ask which to use.
    let configured: String?
    /// Installed GUI tools to choose from (used only when `configured` is nil).
    let tools: [DiffToolOption]
    /// Whether picking a tool should persist it as the default (else launch it once).
    let alwaysUse: Binding<Bool>
    /// Launch the diff tool; `tool` nil uses the configured default.
    let launch: (_ tool: String?) -> Void
    /// Persist `tool` as the default, then launch it.
    let setDefaultAndLaunch: (_ tool: String) -> Void
}

/// The file viewer / diff panel (design brief §6). View-only: renders git's unified-diff text with
/// add/delete shading. Empty cases show a placeholder. Heavy/binary cases (and any file) hand off
/// to an external tool: `onOpenInApp` opens the on-disk working-tree file in the macOS default app
/// (nil when the file isn't on disk); `diffTool` drives the `git difftool` handoff control.
struct FileViewer: View {
    let diff: FileDiff?
    let isLoading: Bool
    var onOpenInApp: (() -> Void)? = nil
    var diffTool: DiffToolControlModel? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let diff {
                header(diff)
                Divider()
                body(for: diff)
            } else if isLoading {
                CenteredMessage(text: "Loading diff…")
            } else {
                CenteredMessage(text: "Select a commit, then a file to see its diff.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ diff: FileDiff) -> some View {
        HStack(spacing: 8) {
            Text(diff.path).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(diff.label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if let onOpenInApp {
                Button(action: onOpenInApp) {
                    Label("Open in default app", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Open the working-tree file in the macOS default app")
            }
            if let diffTool {
                diffToolControl(diffTool, prominent: false)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// The external-diff-tool affordance: a plain button when a tool is configured, a picker menu
    /// (with the "always use this application" toggle) when one must be chosen, or a disabled
    /// "No diff tool available" when none is installed.
    @ViewBuilder
    private func diffToolControl(_ model: DiffToolControlModel, prominent: Bool) -> some View {
        let label = Label("Open in external diff tool", systemImage: "rectangle.split.2x1")
        if model.configured != nil {
            Button { model.launch(nil) } label: { label }
                .modifier(DiffToolButtonStyle(prominent: prominent))
        } else if model.isAvailable {
            Menu {
                Toggle("Always use this application", isOn: model.alwaysUse)
                Divider()
                ForEach(model.tools) { tool in
                    Button(tool.name) {
                        if model.alwaysUse.wrappedValue { model.setDefaultAndLaunch(tool.id) }
                        else { model.launch(tool.id) }
                    }
                }
            } label: { label }
            .menuStyle(.button)
            .modifier(DiffToolButtonStyle(prominent: prominent))
            .fixedSize()
        } else {
            Button { } label: { Label("No diff tool available", systemImage: "rectangle.split.2x1") }
                .buttonStyle(.borderless)
                .disabled(true)
                .help("Install a supported GUI diff tool (e.g. FileMerge) to enable this.")
        }
    }

    @ViewBuilder
    private func body(for diff: FileDiff) -> some View {
        if diff.isBinary {
            binaryPlaceholder
        } else if diff.isEmpty {
            CenteredMessage(text: "No changes for this file in this diff.")
        } else {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines(diff.unifiedText).enumerated()), id: \.offset) { _, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.kind.background)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Binary files have no textual hunks to render — offer the external diff tool instead of a
    /// dead-end message (the tool can show binary/heavy diffs the in-app view can't).
    @ViewBuilder
    private var binaryPlaceholder: some View {
        VStack(spacing: 12) {
            Text("Binary file — no textual diff.")
                .font(.system(size: 15)).foregroundStyle(.secondary)
            if let diffTool {
                diffToolControl(diffTool, prominent: true)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Borderless in the header, prominent on the binary placeholder — one control, two contexts.
    private struct DiffToolButtonStyle: ViewModifier {
        let prominent: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.borderless) }
        }
    }

    private struct DiffLine { let text: String; let kind: Kind
        enum Kind { case added, removed, hunk, meta, context
            var background: Color {
                switch self {
                case .added: return Color.green.opacity(0.18)
                case .removed: return Color.red.opacity(0.18)
                case .hunk: return Color.blue.opacity(0.12)
                default: return .clear
                }
            }
        }
    }

    private func lines(_ text: String) -> [DiffLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let s = String(raw)
            let kind: DiffLine.Kind
            if s.hasPrefix("@@") { kind = .hunk }
            else if s.hasPrefix("+++") || s.hasPrefix("---") || s.hasPrefix("diff ") || s.hasPrefix("index ") { kind = .meta }
            else if s.hasPrefix("+") { kind = .added }
            else if s.hasPrefix("-") { kind = .removed }
            else { kind = .context }
            return DiffLine(text: s, kind: kind)
        }
    }
}
