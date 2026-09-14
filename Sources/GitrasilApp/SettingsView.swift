import SwiftUI
import GitrasilCore

/// App settings (⌘,). Currently the external diff tool used by the "Open in external diff tool"
/// handoff — the user's global `diff.guitool`, switchable at any time. Backed by the shared
/// `DiffToolSettings`, so a change here is reflected immediately in every tab's diff-tool control.
struct SettingsView: View {
    @Environment(DiffToolSettings.self) private var settings
    @Environment(OpenWithSettings.self) private var openWith

    private let askEachTime = ""

    var body: some View {
        Form {
            Section("External diff tool") {
                if !settings.loaded {
                    ProgressView().controlSize(.small)
                } else if settings.available.isEmpty {
                    Text("No diff tool available.")
                        .foregroundStyle(.secondary)
                } else {
                    // Bound directly to the shared observable, so the picker always reflects the
                    // current default — including a default just set from the in-app menu.
                    Picker("Diff tool", selection: Binding(
                        get: { settings.configured ?? askEachTime },
                        set: { applyDiffTool($0) })) {
                        Text("Ask each time").tag(askEachTime)
                        ForEach(settings.available) { Text($0.name).tag($0.id) }
                    }
                    Text("Used when you choose “Open in external diff tool.”")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Section("Open files with") {
                if !openWith.loaded {
                    ProgressView().controlSize(.small)
                } else {
                    Picker("Default app", selection: Binding(
                        get: { openWith.configuredBundleID ?? askEachTime },
                        set: { openWith.setDefault($0.isEmpty ? nil : $0) })) {
                        Text("Ask each time").tag(askEachTime)
                        ForEach(openWith.available) { Text($0.name).tag($0.bundleID) }
                    }
                    Text("Used when you choose “Open with” for the working-tree file.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        // Re-read on open so the pickers reflect any change made elsewhere (e.g. the terminal).
        .task { await settings.reload(); await openWith.reload() }
    }

    private func applyDiffTool(_ new: String) {
        guard new != (settings.configured ?? askEachTime) else { return }
        Task {
            if new.isEmpty { await settings.clearDefault() }
            else { await settings.setDefault(new) }
        }
    }
}
