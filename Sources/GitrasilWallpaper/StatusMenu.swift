import AppKit
import GitrasilCore

/// The menu-bar item: the one place to choose what the background shows. Lists the pinned
/// repositories (each with Reveal in Finder and Remove), adds one through an open panel, picks how
/// several are arranged (an orchard or a single tree), and quits.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {

    private let pins: PinnedRepositories
    private let arrangement: ArrangementSetting
    private let item: NSStatusItem

    init(pins: PinnedRepositories, arrangement: ArrangementSetting) {
        self.pins = pins
        self.arrangement = arrangement
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = MenuBarIcon.image()
        item.button?.toolTip = "Gitrasil Background"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    /// Where the item landed, for the launch log.
    var placement: String {
        guard let window = item.button?.window else { return "no button window" }
        return "status item window \(window.windowNumber) frame \(window.frame) visible \(item.isVisible) "
            + "occlusion-visible \(window.occlusionState.contains(.visible))"
    }

    // Rebuilt each time it opens, so it always matches the pins.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: "Pinned Repositories"))
        if pins.urls.isEmpty {
            let none = NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for (index, url) in pins.urls.enumerated() {
            let entry = NSMenuItem(title: url.lastPathComponent, action: nil, keyEquivalent: "")
            entry.toolTip = url.path
            if !FileManager.default.fileExists(atPath: url.path) {
                entry.badge = NSMenuItemBadge(string: "missing")
            } else if index >= BackgroundModel.maxPanes {
                entry.badge = NSMenuItemBadge(string: "not shown")
                entry.toolTip = "\(url.path)\nThe background shows the first \(BackgroundModel.maxPanes)."
            }
            let submenu = NSMenu()
            submenu.addItem(action("Reveal in Finder", #selector(reveal(_:)), url))
            submenu.addItem(action("Remove", #selector(remove(_:)), url))
            entry.submenu = submenu
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(action("Add Repository…", #selector(add), nil, key: "n"))
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Arrange As"))
        for (choice, title, tip) in [
            (Arrangement.orchard, "Orchard", "A tree for each repository"),
            (.singleTree, "Single Tree", "One trunk with a bough for each repository"),
        ] {
            let entry = NSMenuItem(title: title, action: #selector(arrange(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice.rawValue
            entry.toolTip = tip
            entry.state = arrangement.value == choice ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(action("Quit Gitrasil Background", #selector(quit), nil, key: "q"))
    }

    private func action(_ title: String, _ selector: Selector, _ url: URL?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.representedObject = url
        return item
    }

    @objc private func reveal(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func arrange(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = Arrangement(rawValue: raw) else { return }
        arrangement.value = choice
    }

    @objc private func remove(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        pins.remove(url)
    }

    @objc private func add() {
        // An accessory app has to come forward for its panel to take focus.
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Pin Repositories"
        panel.message = "Choose repository folders to draw on the desktop."
        panel.prompt = "Pin"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let folders = panel.urls
        Task {
            for folder in folders {
                do {
                    try await pins.add(folder)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t pin “\(folder.lastPathComponent)”"
                    alert.informativeText = error.localizedDescription
                    NSApp.activate()
                    alert.runModal()
                }
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
