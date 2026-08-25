import SwiftUI
import GitrasilCore

/// The directory explorer (design brief §7): the worktree's working directory as a lazy,
/// collapsible tree with per-file git-status decorations. Gitignored paths and `.git` are hidden.
/// Opening a file diffs it against the meeting base (base → working tree).
struct FileTreeView: View {
    let rootURL: URL
    let status: [String: WorkingFileStatus]
    let ignored: Set<String>
    let selectedPath: String?
    let onOpen: (String) -> Void

    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter files", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    DirectoryContents(
                        url: rootURL, relativePath: "", depth: 0,
                        status: status, ignored: ignored, filter: filter,
                        selectedPath: selectedPath, onOpen: onOpen)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A single directory's children, loaded lazily on first expansion. Recurses for subdirectories.
private struct DirectoryContents: View {
    let url: URL
    let relativePath: String
    let depth: Int
    let status: [String: WorkingFileStatus]
    let ignored: Set<String>
    let filter: String
    let selectedPath: String?
    let onOpen: (String) -> Void

    @State private var entries: [Entry]?
    private let isRoot: Bool

    init(url: URL, relativePath: String, depth: Int, status: [String: WorkingFileStatus],
         ignored: Set<String>, filter: String, selectedPath: String?, onOpen: @escaping (String) -> Void) {
        self.url = url; self.relativePath = relativePath; self.depth = depth
        self.status = status; self.ignored = ignored; self.filter = filter
        self.selectedPath = selectedPath; self.onOpen = onOpen
        self.isRoot = relativePath.isEmpty
    }

    var body: some View {
        ForEach(visibleEntries) { entry in
            if entry.isDirectory {
                DirectoryDisclosure(
                    entry: entry, depth: depth, status: status, ignored: ignored,
                    filter: filter, selectedPath: selectedPath, onOpen: onOpen)
            } else {
                FileLeaf(entry: entry, depth: depth,
                         status: status[entry.relativePath],
                         isSelected: entry.relativePath == selectedPath)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(entry.relativePath) }
            }
        }
        .onAppear { if entries == nil { entries = Entry.load(url, relativePath, ignored, status) } }
    }

    private var visibleEntries: [Entry] {
        let all = entries ?? (isRoot ? Entry.load(url, relativePath, ignored, status) : [])
        guard !filter.isEmpty else { return all }
        // Keep directories (to navigate into) and files matching the filter.
        return all.filter { $0.isDirectory || $0.name.localizedCaseInsensitiveContains(filter) }
    }
}

private struct DirectoryDisclosure: View {
    let entry: Entry
    let depth: Int
    let status: [String: WorkingFileStatus]
    let ignored: Set<String>
    let filter: String
    let selectedPath: String?
    let onOpen: (String) -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 10)
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(entry.name).font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 12 + 6).padding(.vertical, 2).padding(.trailing, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded || !filter.isEmpty {
                DirectoryContents(
                    url: entry.url, relativePath: entry.relativePath, depth: depth + 1,
                    status: status, ignored: ignored, filter: filter,
                    selectedPath: selectedPath, onOpen: onOpen)
            }
        }
    }
}

private struct FileLeaf: View {
    let entry: Entry
    let depth: Int
    let status: WorkingFileStatus?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: 10)
            Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(entry.name)
                .font(.system(size: 12))
                .strikethrough(status == .deleted)
                .foregroundStyle(status == .deleted ? Color.secondary : Color.primary)
            if let status {
                Text(status.letter)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(color(for: status))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 12 + 6).padding(.vertical, 2).padding(.trailing, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
    }

    private func color(for status: WorkingFileStatus) -> Color {
        switch status {
        case .modified, .renamed: return Color(red: 0.85, green: 0.6, blue: 0.1)
        case .added, .untracked: return .green
        case .deleted: return .red
        case .conflicted: return .red
        }
    }
}

/// One tree entry (a file or directory) with its worktree-relative path.
private struct Entry: Identifiable {
    let url: URL
    let name: String
    let relativePath: String
    let isDirectory: Bool
    var id: String { relativePath }

    /// List a directory's children: skip `.git` and ignored paths, directories first, then append
    /// deleted files (which no longer exist on disk) from the status map so they stay visible.
    static func load(_ url: URL, _ relativeBase: String, _ ignored: Set<String>,
                     _ status: [String: WorkingFileStatus]) -> [Entry] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []

        var entries: [Entry] = []
        for child in contents {
            let name = child.lastPathComponent
            if name == ".git" { continue }
            let rel = relativeBase.isEmpty ? name : relativeBase + "/" + name
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if ignored.contains(rel) || ignored.contains(rel + "/") { continue }
            entries.append(Entry(url: child, name: name, relativePath: rel, isDirectory: isDir))
        }

        // Deleted tracked files in this directory won't be on disk; surface them from status.
        for (path, s) in status where s == .deleted {
            let dir = (path as NSString).deletingLastPathComponent
            if dir == relativeBase && !entries.contains(where: { $0.relativePath == path }) {
                entries.append(Entry(url: url.appendingPathComponent((path as NSString).lastPathComponent),
                                     name: (path as NSString).lastPathComponent,
                                     relativePath: path, isDirectory: false))
            }
        }

        return entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
