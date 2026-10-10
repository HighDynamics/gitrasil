import AppKit
import GitrasilCore

/// The menu-bar item: the one place to choose what the background shows. Lists the pins as a
/// checklist (unticking one unpins it and the menu stays open, so several go in one visit; it stays
/// listed, unticked, until the menu closes, so ticking it again puts it back in its place), each with
/// a button to reveal it in Finder; a pinned folder lists its repositories under it, ticked where
/// they're shown. Adds repositories or folders through an open panel, holds the settings (how several
/// are arranged, what they're drawn in, which names hang on banners and whether they sway in gusts),
/// grows the trees again on request (as they are, or reshuffled), and quits. Run as Gitrasil.app, it
/// also opens at login and checks for a newer release, each when asked to (`AppServices`).
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {

    private let pins: PinnedRepositories
    private let settings: BackgroundSettings
    /// GITRASIL_BACKGROUND_BREEZE=off: the gusts setting is shown off and can't be turned on.
    private let gustsOverridden: Bool
    /// Grows the whole scene again (Watch Gitrasil Grow).
    private let regrow: () -> Void
    /// Open at login and the update check; nil when not run as an app.
    private let app: AppServices?
    private let item: NSStatusItem
    /// While the menu is open: the pins as listed when it opened (unticked ones too), their rows, and
    /// each listed repository of a pinned folder.
    private var listed: [Pin] = []
    private var rows: [PinRow] = []
    private var folderEntries: [(entry: NSMenuItem, repo: URL)] = []

    init(pins: PinnedRepositories, settings: BackgroundSettings, gustsOverridden: Bool, app: AppServices?,
         regrow: @escaping () -> Void) {
        self.pins = pins
        self.settings = settings
        self.gustsOverridden = gustsOverridden
        self.app = app
        self.regrow = regrow
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = MenuBarIcon.image()
        item.button?.toolTip = "Gitrasil Background"
        let menu = NSMenu()
        menu.delegate = self
        // A previewed light or dark mode (GITRASIL_BACKGROUND_APPEARANCE) reaches the menu too.
        menu.appearance = NSApp.appearance
        item.menu = menu
    }

    // Rebuilt each time it opens, so it always matches the pins.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // A pinned folder may have gained a repository, or another become the most recently active.
        pins.refresh()
        listed = pins.pins
        rows = []
        folderEntries = []
        addUpdateNotice(to: menu)
        menu.addItem(.sectionHeader(title: "Pinned"))
        if listed.isEmpty {
            let none = NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for pin in listed {
            let row = PinRow(pin: pin, toggled: { [weak self] row in self?.toggle(row) },
                             reveal: { NSWorkspace.shared.activateFileViewerSelecting([pin.url]) })
            rows.append(row)
            let entry = NSMenuItem()
            entry.view = row
            menu.addItem(entry)
            guard pin.kind == .folder else { continue }
            let repos = pins.contents[pin.url] ?? []
            for repo in repos.prefix(12) {
                let inner = NSMenuItem(title: repo.lastPathComponent, action: nil, keyEquivalent: "")
                inner.indentationLevel = 2
                inner.isEnabled = false
                inner.toolTip = repo.path
                folderEntries.append((inner, repo))
                menu.addItem(inner)
            }
            if repos.count > 12 {
                let more = NSMenuItem(title: "and \(repos.count - 12) more", action: nil, keyEquivalent: "")
                more.indentationLevel = 2
                more.isEnabled = false
                menu.addItem(more)
            }
        }
        update()
        menu.addItem(.separator())
        menu.addItem(action("Add Repository or Folder…", #selector(add), nil, key: "n"))
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Arrange As"))
        for (choice, title, tip) in [
            (Arrangement.orchard, "Orchard", "A tree for each repository"),
            (.singleTree, "Single Tree", "One trunk with a bough for each repository")
        ] {
            let entry = NSMenuItem(title: title, action: #selector(arrange(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice.rawValue
            entry.toolTip = tip
            entry.state = settings.arrangement == choice ? .on : .off
            menu.addItem(entry)
        }
        let forest = action("Forest", #selector(toggleForest), nil)
        forest.state = settings.showsForest ? .on : .off
        forest.toolTip = "Shows up to \(ForestPolicy.standard.paneLimit) repositories, not \(ForestPolicy.standard.plainLimit): "
            + "the single tree keeps the most recently active, the rest stand in a forest behind it, "
            + "and an orchard goes into rows. Their order is set at launch and each midnight"
        menu.addItem(forest)
        menu.addItem(treeCapacityItem())
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Medium"))
        for (choice, title, tip) in [
            (Medium.ink, "Ink", "Brush ink on cream paper"),
            (.charcoal, "Charcoal", "Charcoal and coloured pastel on paper with a tooth"),
            (.chalk, "Chalk", "Coloured chalk on a slate board, in light and dark mode alike")
        ] {
            let entry = NSMenuItem(title: title, action: #selector(draw(in:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice.rawValue
            entry.toolTip = tip
            entry.state = settings.medium == choice ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Banners"))
        let branches = action("Branch Names", #selector(toggleBranchNames), nil)
        branches.state = settings.showsBranchNames ? .on : .off
        branches.toolTip = "Each branch’s name hangs on a pennant from its tip"
        menu.addItem(branches)
        let repos = action("Repository Names", #selector(toggleRepoNames), nil)
        repos.state = settings.showsRepoNames ? .on : .off
        repos.toolTip = "In a single tree, each repository’s name hangs on a ribbon from its bough "
            + "(an orchard always writes it under its tree)"
        menu.addItem(repos)
        let inView = action("Draw All Banners in View", #selector(toggleAllBannersInView), nil)
        inView.state = settings.drawsAllBannersInView ? .on : .off
        inView.toolTip = "Every banner on top of the tree. Off, each hangs at its bough’s depth, "
            + "so the boughs and leaves in front of it hide it"
        menu.addItem(inView)
        let hanging = action("Hang Banners from Boughs", #selector(toggleHangingBanners), nil)
        hanging.state = settings.hangsBanners ? .on : .off
        hanging.toolTip = "Each branch’s pennant dangles from its bough until a gust lifts it. "
            + "Off, it streams out from its tip on a thread"
        menu.addItem(hanging)
        let gusts = action("Sway in Gusts", #selector(toggleGusts), nil)
        gusts.state = settings.gusts && !gustsOverridden ? .on : .off
        gusts.toolTip = gustsOverridden
            ? "Kept still by GITRASIL_BACKGROUND_BREEZE=off"
            : "Now and then a gust sways the banners for a few seconds (not in Low Power Mode); "
            + "the first blows at once, even then. Off, they hang still"
        menu.addItem(gusts)
        menu.addItem(.separator())
        let watch = action("Watch Gitrasil Grow", #selector(watchGrow), nil)
        watch.toolTip = "Grows every tree again from the ground"
        menu.addItem(watch)
        let reshuffle = action("Reshuffle Branches", #selector(reshuffleBranches), nil)
        reshuffle.toolTip = "Grows every tree again with its branches leaning and curving a new way (the same branches, kept between launches)"
        menu.addItem(reshuffle)
        menu.addItem(.separator())
        addAppItems(to: menu)
        menu.addItem(action("Quit Gitrasil Background", #selector(quit), nil, key: "q"))
    }

    /// At the top, when a check has found a newer release: its name, opening its page.
    private func addUpdateNotice(to menu: NSMenu) {
        guard let app, let release = app.updates.available else { return }
        let update = NSMenuItem(title: "Gitrasil \(release.version) Is Available", action: #selector(openRelease(_:)), keyEquivalent: "")
        update.target = self
        update.representedObject = release.page
        update.toolTip = "Opens its release page on GitHub (you have \(app.version))"
        update.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        menu.addItem(update)
        menu.addItem(.separator())
    }

    /// What only the app has: under its version, Open at Login and the update checks.
    private func addAppItems(to menu: NSMenu) {
        guard let app else { return }
        menu.addItem(.sectionHeader(title: "Gitrasil \(app.version)"))
        let login = action("Open at Login", #selector(toggleOpenAtLogin), nil)
        switch app.loginItem {
        case .on:
            login.state = .on
            login.toolTip = "Opens Gitrasil when you log in (listed in System Settings → General → Login Items)"
        case .awaitingApproval:
            // Asked for, but not allowed yet: half on, and a click takes the request back.
            login.state = .mixed
            login.toolTip = "Waiting for you to allow Gitrasil in System Settings → General → Login Items; "
                + "click to stop asking"
        case .off:
            login.state = .off
            login.toolTip = app.runsFromATemporaryPlace
                ? "Move Gitrasil to the Applications folder first: run from its download or disk image, it can’t open at login"
                : "Opens Gitrasil when you log in (listed in System Settings → General → Login Items)"
        }
        menu.addItem(login)
        let daily = action("Check for Updates Daily", #selector(toggleDailyUpdateCheck), nil)
        daily.state = app.updates.isEnabled ? .on : .off
        daily.toolTip = "Once a day, asks GitHub whether a newer Gitrasil has been released "
            + "(\(app.updates.repository)); it sends nothing about you or your repositories"
        menu.addItem(daily)
        let now = action("Check for Updates Now", #selector(checkForUpdatesNow), nil)
        now.toolTip = "Asks GitHub now whether a newer Gitrasil has been released"
        menu.addItem(now)
        menu.addItem(.separator())
    }

    /// "Repos on the Tree": how many repositories the single tree holds, Automatic (the display's number) or a step.
    /// The rest stand behind it in the Forest when that's on; without it, the background shows no more than this.
    private func treeCapacityItem() -> NSMenuItem {
        let policy = ForestPolicy(), plain = policy.plainLimit
        let parent = NSMenuItem(title: "Repos on the Tree", action: #selector(openTreeCapacity), keyEquivalent: "")
        parent.target = self
        parent.toolTip = "How many repositories the single tree holds. With Forest on, the rest stand behind it; "
            + "with it off, the background shows no more than \(plain)."
        if let held = ForestPolicy.standard.fixedTreeCapacity {
            parent.toolTip = "Held at \(held) by GITRASIL_TREE_CAPACITY: the choices below do nothing"
        }
        let submenu = NSMenu(title: parent.title)
        submenu.autoenablesItems = true
        for choice in [nil] + ForestPolicy.treeCapacitySteps.map(Optional.some) {
            let entry = NSMenuItem(title: choice.map(String.init) ?? "Automatic", action: #selector(chooseTreeCapacity(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice
            entry.state = settings.treeCapacity == choice ? .on : .off
            if let choice {
                entry.toolTip = "At most \(choice) on the tree" + (choice > plain ? ", more than \(plain) only with Forest on" : "")
            } else {
                let laptop = policy.treeCapacity(for: CGSize(width: 1440, height: 900))
                let tall = policy.treeCapacity(for: CGSize(width: 2560, height: 1440))
                entry.toolTip = "As many as the display reads well: \(laptop) on a 900 point tall display, \(tall) from 1440 points tall"
            }
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    /// Only here for the menu to validate (it greys the parent in the orchard): the item opens its submenu.
    @objc private func openTreeCapacity() {}

    private func action(_ title: String, _ selector: Selector, _ url: URL?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.representedObject = url
        return item
    }

    @objc private func arrange(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = Arrangement(rawValue: raw) else { return }
        settings.arrangement = choice
    }

    @objc private func draw(in sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = Medium(rawValue: raw) else { return }
        settings.medium = choice
    }

    @objc private func chooseTreeCapacity(_ sender: NSMenuItem) {
        settings.treeCapacity = sender.representedObject as? Int
    }

    @objc private func toggleForest() {
        settings.showsForest.toggle()
    }

    @objc private func toggleBranchNames() {
        settings.showsBranchNames.toggle()
    }

    @objc private func toggleRepoNames() {
        settings.showsRepoNames.toggle()
    }

    @objc private func toggleAllBannersInView() {
        settings.drawsAllBannersInView.toggle()
    }

    @objc private func toggleHangingBanners() {
        settings.hangsBanners.toggle()
    }

    @objc private func toggleGusts() {
        settings.gusts.toggle()
    }

    @objc private func watchGrow() {
        regrow()
    }

    /// A new layout seed; the background grows the trees again in their new shape.
    @objc private func reshuffleBranches() {
        settings.reshuffle()
    }

    @objc private func openRelease(_ sender: NSMenuItem) {
        guard let page = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(page)
    }

    @objc private func toggleOpenAtLogin() {
        guard let app else { return }
        // On or waiting for approval, a click unregisters it.
        let on = app.loginItem == .off
        do {
            try app.setOpensAtLogin(on)
        } catch {
            logEvent("open at login: \(error)")
            inform(on ? "Couldn’t make Gitrasil open at login" : "Couldn’t stop Gitrasil opening at login",
                   error.localizedDescription)
        }
    }

    /// Turning daily checks on checks at once, if a day has passed since the last.
    @objc private func toggleDailyUpdateCheck() {
        guard let app else { return }
        app.updates.isEnabled.toggle()
        app.checkForUpdatesIfDue()
    }

    @objc private func checkForUpdatesNow() {
        guard let app else { return }
        Task {
            do {
                switch try await app.updates.check() {
                case .newer(let release):
                    let alert = NSAlert()
                    alert.messageText = "Gitrasil \(release.version) is available"
                    alert.informativeText = "You have \(app.version). Its release page on GitHub has the download."
                    alert.addButton(withTitle: "Open Release Page")
                    alert.addButton(withTitle: "Later")
                    NSApp.activate()
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
                case .upToDate:
                    inform("Gitrasil is up to date", "\(app.version) is the newest version.")
                case .noRelease:
                    inform("No release found", "\(app.updates.repository) on GitHub has no published release of "
                           + "Gitrasil yet, or isn’t public.")
                }
            } catch {
                logEvent("update check: \(error)")
                inform("Couldn’t check for updates", error.localizedDescription)
            }
        }
    }

    private func inform(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }

    /// Gusts sway banners, so with none hanging (or the breeze turned off from outside) there's nothing
    /// to set, nor where the banners are drawn; only pennants hang from boughs; with nothing pinned
    /// there's nothing to grow.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleGusts): settings.hasBanners && !gustsOverridden
        case #selector(toggleAllBannersInView): settings.hasBanners
        case #selector(toggleHangingBanners): settings.showsBranchNames
        case #selector(watchGrow), #selector(reshuffleBranches): !pins.shown.isEmpty
        // The orchard has no tree to hold them: the choice is kept, and waits.
        case #selector(chooseTreeCapacity(_:)), #selector(openTreeCapacity): settings.arrangement == .singleTree
        // Unregistering is always allowed, so a login item made before a move can be removed.
        case #selector(toggleOpenAtLogin): app.map { !$0.runsFromATemporaryPlace || $0.loginItem != .off } ?? false
        case #selector(checkForUpdatesNow): app.map { !$0.updates.isChecking } ?? false
        default: true
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        listed = []
        rows = []
        folderEntries = []
    }

    /// Untick to unpin, tick to pin again where it was listed.
    private func toggle(_ row: PinRow) {
        if row.isOn {
            guard let index = listed.firstIndex(of: row.pin) else { return }
            let before = listed[..<index].filter { pins.pins.contains($0) }.count
            pins.insert(row.pin, at: before)
        } else {
            pins.remove(row.pin)
        }
        update()
    }

    /// Each row's note (missing, not shown, how many of a folder's are shown) and which of a folder's
    /// repositories are ticked, as the pins stand now.
    private func update() {
        let shown = Set(pins.shown.map(\.path))
        for row in rows {
            let pinned = pins.pins.contains(row.pin)
            var note = ""
            var tip = row.pin.url.path
            if !FileManager.default.fileExists(atPath: row.pin.url.path) {
                note = "missing"
            } else if pinned, row.pin.kind == .folder {
                let count = pins.shownCount(of: row.pin)
                note = count.of == 0 ? "no repositories" : count.shown == count.of ? "all \(count.of)" : "\(count.shown) of \(count.of) shown"
                if count.shown < count.of {
                    tip += "\nThe background shows \(pins.limit) at most: of a folder with more, the most recently active."
                    tip += settings.showsForest ? "" : " Forest shows more."
                }
            } else if pinned, !shown.contains(row.pin.url.path) {
                note = "not shown"
                tip += "\nThe background shows the first \(pins.limit).\(settings.showsForest ? "" : " Forest shows more.")"
            }
            row.show(on: pinned, note: note, tip: tip)
        }
        for (entry, repo) in folderEntries {
            entry.state = shown.contains(repo.path) ? .on : .off
        }
    }

    @objc private func add() {
        // An accessory app has to come forward for its panel to take focus.
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Pin Repositories"
        panel.message = "Choose repositories to draw on the desktop, or a folder of them."
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

/// A pin's row in the menu: a checkbox with its name (a folder icon for a pinned folder), a quiet note,
/// and a reveal-in-Finder button. A view, so clicking it doesn't close the menu.
@MainActor
private final class PinRow: NSView {
    let pin: Pin
    private let check: NSButton
    private let note = NSTextField(labelWithString: "")
    private let toggled: (PinRow) -> Void
    private let reveal: () -> Void

    var isOn: Bool { check.state == .on }

    init(pin: Pin, toggled: @escaping (PinRow) -> Void, reveal: @escaping () -> Void) {
        self.pin = pin
        self.toggled = toggled
        self.reveal = reveal
        check = NSButton(checkboxWithTitle: pin.url.lastPathComponent, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        autoresizingMask = [.width]
        check.target = self
        check.action = #selector(flip)
        let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder") ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.isHidden = pin.kind != .folder
        note.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.alignment = .right
        let finder = NSButton(image: NSImage(systemSymbolName: "arrow.forward.circle",
                                             accessibilityDescription: "Reveal in Finder")!,
                              target: nil, action: nil)
        finder.isBordered = false
        finder.toolTip = "Reveal in Finder"
        finder.target = self
        finder.action = #selector(revealInFinder)
        for view in [check, icon, note, finder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.leadingAnchor.constraint(greaterThanOrEqualTo: icon.trailingAnchor, constant: 12),
            note.centerYAnchor.constraint(equalTo: centerYAnchor),
            finder.leadingAnchor.constraint(equalTo: note.trailingAnchor, constant: 6),
            finder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            finder.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(on: Bool, note text: String, tip: String) {
        check.state = on ? .on : .off
        note.stringValue = text
        toolTip = tip
        check.toolTip = tip
    }

    @objc private func flip() { toggled(self) }

    @objc private func revealInFinder() {
        reveal()
    }
}
