import SwiftUI
import GitrasilCore

/// Create a worktree: a new branch off a base, or a checkout of an existing branch, at a chosen
/// location (defaulting to a sibling `<repo>-<branch>` directory).
struct AddWorktreeSheet: View {
    let repo: RepositoryStore
    var onDone: () -> Void

    enum Mode: String, CaseIterable { case newBranch = "New branch", existing = "Existing branch" }

    @State private var mode: Mode = .newBranch
    @State private var newBranchName = ""
    @State private var base = ""
    @State private var existingBranch = ""
    @State private var path = ""
    @State private var pathEdited = false
    @State private var allBranches: [String] = []
    @State private var availableBranches: [String] = []
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Worktree").font(.system(size: 16, weight: .semibold))

            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: mode) { _, _ in syncPath() }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                if mode == .newBranch {
                    field("Branch") {
                        TextField("new-branch-name", text: $newBranchName)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: newBranchName) { _, _ in syncPath() }
                    }
                    field("Based on") { branchMenu(selection: $base, options: allBranches) }
                } else {
                    field("Branch") {
                        branchMenu(selection: $existingBranch, options: availableBranches)
                            .onChange(of: existingBranch) { _, _ in syncPath() }
                    }
                }
                field("Location") {
                    TextField("~/path/to/worktree", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: path) { _, _ in pathEdited = true }
                }
            }

            if let error = repo.actionError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) { onDone() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || creating)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            allBranches = await repo.allLocalBranches()
            availableBranches = await repo.branchesAvailableForCheckout()
            base = repo.currentBranch ?? allBranches.first ?? ""
            existingBranch = availableBranches.first ?? ""
            syncPath()
        }
    }

    @ViewBuilder
    private func field(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.trailing).foregroundStyle(.secondary)
            content()
        }
    }

    private func branchMenu(selection: Binding<String>, options: [String]) -> some View {
        Menu {
            if options.isEmpty { Text("No branches").foregroundStyle(.secondary) }
            ForEach(options, id: \.self) { branch in
                Button(branch) { selection.wrappedValue = branch }
            }
        } label: {
            HStack {
                Text(selection.wrappedValue.isEmpty ? "Select…" : selection.wrappedValue)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
    }

    private var branchForPath: String {
        (mode == .newBranch ? newBranchName : existingBranch).trimmingCharacters(in: .whitespaces)
    }

    private func syncPath() {
        guard !pathEdited else { return }
        let branch = branchForPath.isEmpty ? "worktree" : branchForPath
        path = repo.defaultWorktreePath(forBranch: branch).path
    }

    private var isValid: Bool {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch mode {
        case .newBranch: return !newBranchName.trimmingCharacters(in: .whitespaces).isEmpty && !base.isEmpty
        case .existing: return !existingBranch.isEmpty
        }
    }

    private func create() {
        creating = true
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let newBranch = mode == .newBranch ? newBranchName.trimmingCharacters(in: .whitespaces) : nil
        let base = mode == .newBranch ? self.base : existingBranch
        Task {
            await repo.createWorktree(newBranch: newBranch, base: base, at: target)
            creating = false
            if repo.actionError == nil { onDone() }
        }
    }
}
