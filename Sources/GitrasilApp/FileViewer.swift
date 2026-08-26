import SwiftUI
import GitrasilCore

/// The file viewer / diff panel (design brief §6). View-only: renders git's unified-diff text with
/// add/delete shading. Binary and empty cases show a placeholder; heavy external diffing is a
/// later "Open in external tool" handoff.
struct FileViewer: View {
    let diff: FileDiff?
    let isLoading: Bool

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
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private func body(for diff: FileDiff) -> some View {
        if diff.isBinary {
            CenteredMessage(text: "Binary file — no textual diff.")
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
