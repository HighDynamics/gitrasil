import SwiftUI
import GitrasilCore

/// The file viewer / diff panel (design brief §6). View-only: renders git's unified-diff text with
/// add/delete shading. Binary and empty cases show a placeholder. Heavy/binary cases (and any file)
/// hand off to an external tool via the optional actions: `onOpenInApp` opens the on-disk
/// working-tree file in the macOS default app (nil when the file isn't on disk); `onOpenDiffTool`
/// launches `git difftool` for the current diff source.
struct FileViewer: View {
    let diff: FileDiff?
    let isLoading: Bool
    var onOpenInApp: (() -> Void)? = nil
    var onOpenDiffTool: (() -> Void)? = nil

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
            if let onOpenDiffTool {
                Button(action: onOpenDiffTool) {
                    Label("Open in external diff tool", systemImage: "rectangle.split.2x1")
                }
                .buttonStyle(.borderless)
                .help("Open this diff in your configured git difftool")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
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
            if let onOpenDiffTool {
                Button(action: onOpenDiffTool) {
                    Label("Open in external diff tool", systemImage: "rectangle.split.2x1")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
