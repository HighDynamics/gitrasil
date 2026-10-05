import Foundation
import Observation

/// Where the pins are saved: a list of folder paths.
public protocol PinStorage: AnyObject {
    func loadPins() -> [String]
    func savePins(_ paths: [String])
}

extension UserDefaults: PinStorage {
    static let pinnedRepositoriesKey = "pinnedRepositories"
    public func loadPins() -> [String] { stringArray(forKey: Self.pinnedRepositoriesKey) ?? [] }
    public func savePins(_ paths: [String]) { set(paths, forKey: Self.pinnedRepositoriesKey) }
}

/// The repositories the user pinned to the desktop background, in the order they pinned them,
/// saved between launches (in `UserDefaults`, for the app).
///
/// Adding validates the folder with git and stores the top of its working tree, so pinning a
/// subfolder pins its repository. Two folders of the same repository (a subfolder, a symlinked
/// path, or another worktree of it) are one pin: the repo-wide graph is the same from any of them.
@MainActor
@Observable
public final class PinnedRepositories {

    public enum PinError: LocalizedError, Equatable {
        case notARepository(path: String)
        case alreadyPinned(path: String)

        public var errorDescription: String? {
            switch self {
            case .notARepository(let path): return "“\(path)” isn’t in a git repository."
            case .alreadyPinned(let path): return "That repository is already pinned, as “\(path)”."
            }
        }
    }

    /// The pinned repositories' folders (the top of a working tree each), oldest pin first.
    public private(set) var urls: [URL]

    /// The defaults suite the app saves to. `GITRASIL_BACKGROUND_DEFAULTS_SUITE` overrides it, so a
    /// test run can use a throwaway suite instead of the user's pins.
    public static let suiteName = "com.gitrasil.background"
    public static let suiteOverrideVariable = "GITRASIL_BACKGROUND_DEFAULTS_SUITE"

    private let storage: PinStorage

    public init(storage: PinStorage) {
        self.storage = storage
        self.urls = storage.loadPins().map { URL(fileURLWithPath: $0) }
    }

    /// The app's defaults suite name: the override when the environment names one, else the app's own.
    public static func appSuiteName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment[suiteOverrideVariable].flatMap { $0.isEmpty ? nil : $0 } ?? suiteName
    }

    /// Pin the repository containing `folder`. Returns the folder that was pinned (its working
    /// tree's top). Throws when the folder isn't in a repository or the repository is already pinned.
    @discardableResult
    public func add(_ folder: URL) async throws -> URL {
        guard let identity = await Self.identity(of: folder) else {
            throw PinError.notARepository(path: folder.path)
        }
        for pinned in urls {
            if let other = await Self.identity(of: pinned), other.commonDir == identity.commonDir {
                throw PinError.alreadyPinned(path: pinned.path)
            }
        }
        urls.append(identity.top)
        save()
        return identity.top
    }

    /// Unpin a repository (matched by its saved folder).
    public func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        urls.removeAll { $0.standardizedFileURL.path == path }
        save()
    }

    private func save() {
        storage.savePins(urls.map(\.path))
    }

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
