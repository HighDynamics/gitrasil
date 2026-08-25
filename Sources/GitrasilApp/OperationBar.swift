import SwiftUI
import GitrasilCore

/// The conditional operation bar (design brief §9). It occupies one strip that shows either the
/// continue/abort controls while an operation is paused, or a dismissible message about a failed /
/// blocked mutation. Driven by the re-derived snapshot, so it appears and clears in reaction to the
/// real git state — including a continue/abort the user did from the terminal.
struct OperationBar: View {
    let inProgress: InProgressOperation?
    let mutationError: String?
    let onContinue: () -> Void
    let onAbort: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        if let inProgress {
            bar(color: .red) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("\(name(inProgress)) paused — resolve conflicts in your editor or terminal, then continue.")
                    .font(.system(size: 12))
                Spacer()
                Button("Abort", role: .destructive, action: onAbort).buttonStyle(.bordered)
                Button("Continue", action: onContinue).buttonStyle(.borderedProminent)
            }
        } else if let mutationError {
            bar(color: .orange) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(mutationError).font(.system(size: 12))
                Spacer()
                Button("Dismiss", action: onDismiss).buttonStyle(.bordered)
            }
        }
    }

    private func bar<Content: View>(color: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12))
    }

    private func name(_ op: InProgressOperation) -> String {
        switch op {
        case .rebase: return "Rebase"
        case .cherryPick: return "Cherry-pick"
        case .merge: return "Merge"
        }
    }
}
