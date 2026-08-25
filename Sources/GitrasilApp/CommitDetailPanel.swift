import SwiftUI
import GitrasilCore

/// The commit detail panel (design brief §5): commit metadata and the files it touched. Selecting
/// a file drives the file viewer. Docks below the graph in the navigation column.
struct CommitDetailPanel: View {
    let detail: CommitDetail
    let selectedPath: String?
    let canDrop: Bool
    let onSelectFile: (FileChange) -> Void
    let onDrop: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(detail.commit.shortSHA)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                if detail.commitCount > 1 {
                    Pill(text: "\(detail.commitCount) commits")
                }
                Spacer()
                if canDrop {
                    Button("Drop", systemImage: "trash", role: .destructive, action: onDrop)
                        .buttonStyle(.borderless)
                        .help("Remove this commit from the branch (undoable)")
                }
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }

            Text(detail.fullMessage)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(detail.commit.author) · \(detail.commit.date)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(detail.files, id: \.path) { file in
                        FileRow(file: file, isSelected: file.path == selectedPath)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelectFile(file) }
                    }
                }
            }
        }
        .padding(12)
    }
}

struct FileRow: View {
    let file: FileChange
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(file.kind.letter)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(letterColor, in: RoundedRectangle(cornerRadius: 3))
            Text(file.path)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
    }

    private var letterColor: Color {
        switch file.kind {
        case .added: return .green
        case .modified: return Color(red: 0.85, green: 0.6, blue: 0.1)
        case .deleted: return .red
        case .renamed, .copied: return .blue
        }
    }
}
