import Foundation
import Observation

/// One pin: a repository, or a folder of repositories (each drawn, as they come and go).
public struct Pin: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case repository
        case folder
    }

    public let kind: Kind
    public let url: URL

    public init(_ kind: Kind, _ url: URL) {
        self.kind = kind
        self.url = PinnedRepositories.folderURL(url.standardizedFileURL.path)
    }

    var path: String { url.standardizedFileURL.path }
}

/// Where the pins are saved.
public protocol PinStorage: AnyObject {
    func loadPins() -> [Pin]
    func savePins(_ pins: [Pin])
}

extension UserDefaults: PinStorage {
    static let pinsKey = "pins"
    /// The list of repository paths earlier builds read; still written, with the repository pins.
    static let pinnedRepositoriesKey = "pinnedRepositories"

    public func loadPins() -> [Pin] {
        if let saved = array(forKey: Self.pinsKey) as? [[String: String]] {
            return saved.compactMap { entry in
                guard let kind = entry["kind"].flatMap(Pin.Kind.init(rawValue:)), let path = entry["path"] else { return nil }
                return Pin(kind, URL(fileURLWithPath: path))
            }
        }
        return (stringArray(forKey: Self.pinnedRepositoriesKey) ?? []).map { Pin(.repository, URL(fileURLWithPath: $0)) }
    }

    public func savePins(_ pins: [Pin]) {
        set(pins.map { ["kind": $0.kind.rawValue, "path": $0.url.path] }, forKey: Self.pinsKey)
        set(pins.filter { $0.kind == .repository }.map(\.url.path), forKey: Self.pinnedRepositoriesKey)
    }
}

/// What the user pinned to the desktop background, in the order they pinned it, saved between
/// launches (in `UserDefaults`, for the app), and the repositories that makes: `shown`.
///
/// Adding validates the folder with git and stores the top of its working tree, so pinning a
/// subfolder pins its repository. Two folders of the same repository (a subfolder, a symlinked
/// path, or another worktree of it) are one pin: the repo-wide graph is the same from any of them.
///
/// A folder that isn't a repository's top but holds repositories (one level down, or two through a
/// plain subfolder) is pinned as a folder: it stands for every repository in it, picking up ones
/// added or removed later (`FolderWatcher` on the folder and its plain subfolders).
@MainActor
@Observable
public final class PinnedRepositories {

    public enum PinError: LocalizedError, Equatable {
        case notARepository(path: String)
        case alreadyPinned(path: String)

        public var errorDescription: String? {
            switch self {
            case .notARepository(let path):
                return "“\(path)” isn’t in a git repository, and holds none one or two folders down."
            case .alreadyPinned(let path): return "That’s already pinned, as “\(path)”."
            }
        }
    }

    /// The pins, oldest first.
    public private(set) var pins: [Pin]

    /// The repositories on the background: the pins expanded in order, at most `limit` (`resolve`).
    public private(set) var shown: [URL] = []

    /// The repositories in each folder pin, in name order.
    public private(set) var contents: [URL: [URL]] = [:]

    /// The defaults suite the app saves to. `GITRASIL_BACKGROUND_DEFAULTS_SUITE` overrides it, so a
    /// test run can use a throwaway suite instead of the user's pins.
    public static let suiteName = "com.gitrasil.background"
    public static let suiteOverrideVariable = "GITRASIL_BACKGROUND_DEFAULTS_SUITE"

    public let limit: Int
    private let storage: PinStorage
    @ObservationIgnored private var watchers: [URL: FolderWatcher] = [:]

    public init(storage: PinStorage, limit: Int = 4) {
        self.storage = storage
        self.limit = limit
        self.pins = storage.loadPins()
        refresh()
    }

    /// The app's defaults suite name: the override when the environment names one, else the app's own.
    public static func appSuiteName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment[suiteOverrideVariable].flatMap { $0.isEmpty ? nil : $0 } ?? suiteName
    }

    /// Pin `folder`: the repository it's the top of; else, when it holds repositories, the folder;
    /// else the repository it's in. Throws when it's none of those, or already pinned.
    @discardableResult
    public func add(_ folder: URL) async throws -> Pin {
        let identity = await Self.identity(of: folder)
        let resolved = Self.folderURL(folder.resolvingSymlinksInPath().path)
        let pin: Pin
        if let identity, identity.top.path == resolved.path {
            pin = Pin(.repository, identity.top)
        } else if !Self.scan(resolved).isEmpty {
            pin = Pin(.folder, resolved)
        } else if let identity {
            pin = Pin(.repository, identity.top)
        } else {
            throw PinError.notARepository(path: folder.path)
        }
        if let existing = pins.first(where: { $0.path == pin.path }) {
            throw PinError.alreadyPinned(path: existing.url.path)
        }
        if pin.kind == .repository, let identity {
            for pinned in pins where pinned.kind == .repository {
                if let other = await Self.identity(of: pinned.url), other.commonDir == identity.commonDir {
                    throw PinError.alreadyPinned(path: pinned.url.path)
                }
            }
        }
        pins.append(pin)
        save()
        return pin
    }

    /// Unpin (matched by its saved folder).
    public func remove(_ pin: Pin) {
        pins.removeAll { $0.path == pin.path }
        save()
    }

    /// Pin again at `index` (clamped), as when a pin unticked in the menu is ticked again.
    public func insert(_ pin: Pin, at index: Int) {
        guard !pins.contains(where: { $0.path == pin.path }) else { return }
        pins.insert(pin, at: min(max(index, 0), pins.count))
        save()
    }

    /// Look in every pinned folder again and re-rank what's shown: when a folder changes, hourly,
    /// and when the menu opens. Publishes only what changed.
    public func refresh() {
        var found: [URL: [URL]] = [:]
        for pin in pins where pin.kind == .folder { found[pin.url] = Self.scan(pin.url) }
        if found != contents { contents = found }
        let activity = Dictionary(found.values.joined().map { ($0, Self.lastActivity(of: $0)) },
                                  uniquingKeysWith: { a, _ in a })
        let next = Self.resolve(pins, contents: found, activity: activity, limit: limit)
        if next != shown { shown = next }
        watch()
    }

    /// How many of a folder pin's repositories are shown, of how many it holds.
    public func shownCount(of pin: Pin) -> (shown: Int, of: Int) {
        let all = contents[pin.url] ?? []
        let on = Set(shown.map(\.path))
        return (all.filter { on.contains($0.path) }.count, all.count)
    }

    private func save() {
        storage.savePins(pins)
        refresh()
    }

    /// Watch each pinned folder and its plain subfolders (not the repositories' insides), re-armed
    /// as those come and go.
    private func watch() {
        var next: [URL: FolderWatcher] = [:]
        for pin in pins where pin.kind == .folder {
            let directories = [pin.url] + Self.plainSubfolders(of: pin.url)
            if let existing = watchers[pin.url], existing.paths == directories.map(\.path) {
                next[pin.url] = existing
            } else {
                next[pin.url] = FolderWatcher(paths: directories.map(\.path)) { [weak self] in
                    Task { @MainActor in self?.refresh() }
                }
            }
        }
        for (url, watcher) in watchers where next[url] !== watcher { watcher.stop() }
        watchers = next
    }

    // MARK: Resolving

    /// The repositories to draw: each pin in order, until `limit`. A repository pin is its
    /// repository. A folder takes as many of the slots left as it has repositories; when it has more,
    /// the most recently active (`activity`), shown in name order so activity elsewhere doesn't
    /// shuffle them. A repository already shown isn't shown twice.
    public static func resolve(_ pins: [Pin], contents: [URL: [URL]], activity: [URL: Date], limit: Int) -> [URL] {
        var shown: [URL] = []
        var seen = Set<String>()
        for pin in pins {
            let left = limit - shown.count
            guard left > 0 else { break }
            switch pin.kind {
            case .repository:
                if seen.insert(pin.path).inserted { shown.append(pin.url) }
            case .folder:
                let repos = (contents[pin.url] ?? []).filter { !seen.contains($0.standardizedFileURL.path) }
                var chosen = repos
                if repos.count > left {
                    let ranked = repos.sorted { a, b in
                        let (x, y) = (activity[a] ?? .distantPast, activity[b] ?? .distantPast)
                        return x != y ? x > y : byName(a, b)
                    }
                    let keep = Set(ranked.prefix(left).map(\.path))
                    chosen = repos.filter { keep.contains($0.path) }
                }
                for repo in chosen {
                    seen.insert(repo.standardizedFileURL.path)
                    shown.append(repo)
                }
            }
        }
        return shown
    }

    // MARK: Looking in folders (no git process: this runs on every change to a folder)

    /// The repositories in `folder`, one level down or two through a plain subfolder, in name order.
    /// A linked worktree (a `.git` file) is left out when its repository is also there.
    public nonisolated static func scan(_ folder: URL) -> [URL] {
        var found: [URL] = []
        for child in subfolders(of: folder) {
            if isRepository(child) {
                found.append(child)
            } else {
                found += subfolders(of: child).filter(isRepository)
            }
        }
        let tops = Set(found.map(\.path))
        return found
            .filter { repo in mainRepository(ofWorktree: repo).map { !tops.contains($0.path) } ?? true }
            .sorted(by: byName)
    }

    nonisolated static func plainSubfolders(of folder: URL) -> [URL] {
        subfolders(of: folder).filter { !isRepository($0) }
    }

    nonisolated static func subfolders(of folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return children.filter { child in
            let values = try? child.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }.map { folderURL($0.resolvingSymlinksInPath().path) }
    }

    nonisolated static func isRepository(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path)
    }

    /// For a linked worktree (its `.git` a file pointing into `<repo>/.git/worktrees/<name>`), its
    /// main repository's folder.
    nonisolated static func mainRepository(ofWorktree folder: URL) -> URL? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(".git"), encoding: .utf8),
              text.hasPrefix("gitdir:") else { return nil }
        let gitdir = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let path = URL(fileURLWithPath: gitdir, relativeTo: folder).standardizedFileURL.path
        guard let range = path.range(of: "/.git/worktrees/") else { return nil }
        return URL(fileURLWithPath: String(path[..<range.lowerBound])).resolvingSymlinksInPath()
    }

    /// When a repository was last committed to or checked out: its HEAD log's time, else HEAD's.
    public nonisolated static func lastActivity(of repo: URL) -> Date {
        var gitdir = repo.appendingPathComponent(".git")
        if let text = try? String(contentsOf: gitdir, encoding: .utf8), text.hasPrefix("gitdir:") {
            let path = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitdir = URL(fileURLWithPath: path, relativeTo: repo).standardizedFileURL
        }
        for file in ["logs/HEAD", "HEAD"] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: gitdir.appendingPathComponent(file).path)
            if let date = attributes?[.modificationDate] as? Date { return date }
        }
        return .distantPast
    }

    /// A folder's URL, spelled one way (a directory URL), so the same folder is always an equal URL.
    nonisolated static func folderURL(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    nonisolated static func byName(_ a: URL, _ b: URL) -> Bool {
        let order = a.lastPathComponent.localizedStandardCompare(b.lastPathComponent)
        return order == .orderedSame ? a.path < b.path : order == .orderedAscending
    }

    // MARK: Identity

    /// A folder's working-tree top, and the repository's common git dir (shared by all its worktrees),
    /// both with symlinks resolved. Nil when git doesn't see a repository there.
    nonisolated static func identity(of folder: URL) async -> (top: URL, commonDir: String)? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let runner = GitRunner(workdir: folder, extraEnvironment: GitRunner.appEnvironment)
        guard let out = try? await runner.runChecked(["rev-parse", "--show-toplevel", "--git-common-dir"]) else {
            return nil
        }
        let lines = (out.stdoutString ?? "").split(separator: "\n").map(String.init)
        guard lines.count == 2, !lines[0].isEmpty else { return nil }
        let top = URL(fileURLWithPath: lines[0]).resolvingSymlinksInPath()
        let common = URL(fileURLWithPath: lines[1], relativeTo: folder).standardizedFileURL.resolvingSymlinksInPath()
        return (top, common.path)
    }
}
