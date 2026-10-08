import Foundation
import Observation

/// A release's version: numbers separated by dots ("1.2.3"), with the leading "v" of a tag dropped.
/// Missing numbers count as 0, so 1.2 and 1.2.0 are the same version. Anything else (a pre-release
/// suffix, a name) isn't a version.
public struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {
    public let numbers: [Int]

    public init?(_ text: String) {
        var text = Substring(text)
        if text.first == "v" { text = text.dropFirst() }
        // Digits by Unicode scalar, ASCII only: a digit with a combining mark is one Character that
        // sorts among "0"..."9", but isn't a number.
        let numbers = text.split(separator: ".", omittingEmptySubsequences: false).map { part -> Int? in
            guard (1..<10).contains(part.unicodeScalars.count),
                  part.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            return Int(part)
        }
        guard !numbers.contains(nil) else { return nil }
        self.numbers = numbers.compactMap { $0 }
    }

    public var description: String { numbers.map(String.init).joined(separator: ".") }

    private func padded(to count: Int) -> [Int] { numbers + Array(repeating: 0, count: count - numbers.count) }

    public static func == (a: Self, b: Self) -> Bool {
        let count = max(a.numbers.count, b.numbers.count)
        return a.padded(to: count) == b.padded(to: count)
    }

    public static func < (a: Self, b: Self) -> Bool {
        let count = max(a.numbers.count, b.numbers.count)
        return a.padded(to: count).lexicographicallyPrecedes(b.padded(to: count))
    }
}

/// A published release of Gitrasil: its version and its page on GitHub.
public struct Release: Equatable, Sendable {
    public let version: ReleaseVersion
    public let page: URL

    public init(version: ReleaseVersion, page: URL) {
        self.version = version
        self.page = page
    }
}

/// The fields of GitHub's reply for a repository's latest release that the check reads.
private struct LatestReleaseReply: Decodable {
    let tag: String
    let draft: Bool?
    let prerelease: Bool?

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case draft, prerelease
    }
}

/// Whether a newer Gitrasil has been released: the latest published release in the repository's
/// GitHub Releases (drafts and pre-releases aren't), compared with the running version.
///
/// Opt-in and at most daily: off until turned on, and then a check is due a day after the last one.
/// A check is one unauthenticated request to the GitHub API, with no cookies or cache and nothing
/// about the user in it. A newer release found is kept (with when it last looked) next to the pins,
/// so it's still offered after a relaunch, until the running version catches up.
@MainActor
@Observable
public final class UpdateCheck {

    /// What a check found.
    public enum Outcome: Equatable, Sendable {
        case newer(Release)
        case upToDate(latest: ReleaseVersion)
        /// The repository has no published release (or can't be seen: a private repository).
        case noRelease
    }

    public enum CheckError: LocalizedError, Equatable {
        case status(Int)
        case unreadable
        /// The repository to check isn't "owner/name".
        case notARepository(String)

        public var errorDescription: String? {
            switch self {
            case .status(let code): "GitHub answered with status \(code)."
            case .unreadable: "GitHub’s answer couldn’t be read."
            case .notARepository(let text): "“\(text)” isn’t a GitHub repository (owner/name)."
            }
        }
    }

    /// Sends a request and returns the reply: `URLSession` in the app, a stand-in in tests.
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let enabledKey = "checksForUpdates"
    static let lastCheckedKey = "lastUpdateCheck"
    static let availableKey = "availableRelease"

    /// How long after one check the next is due.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// The running version.
    public let current: ReleaseVersion
    /// The GitHub repository whose releases are checked, as "owner/name".
    public let repository: String

    /// Whether to check daily; off until turned on.
    public var isEnabled: Bool {
        didSet { if isEnabled != oldValue { storage.set(isEnabled, forKey: Self.enabledKey) } }
    }

    /// When the last check was made, whatever it found.
    public private(set) var lastChecked: Date?
    /// A release newer than the running version, once a check has found one.
    public private(set) var available: Release?
    public private(set) var isChecking = false

    private let storage: SettingsStorage
    private let fetch: Fetch
    private let now: () -> Date

    public init(current: ReleaseVersion, repository: String, storage: SettingsStorage,
                fetch: @escaping Fetch = UpdateCheck.urlSession, now: @escaping () -> Date = Date.init) {
        self.current = current
        self.repository = repository
        self.storage = storage
        self.fetch = fetch
        self.now = now
        isEnabled = storage.object(forKey: Self.enabledKey) as? Bool ?? false
        lastChecked = storage.object(forKey: Self.lastCheckedKey) as? Date
        if let saved = storage.object(forKey: Self.availableKey) as? String {
            // Running that version (or a later one) by now: nothing to offer.
            available = ReleaseVersion(saved).flatMap { version in
                guard version > current, let page = try? Self.page(for: version, in: repository) else { return nil }
                return Release(version: version, page: page)
            }
            if available == nil { storage.set(nil, forKey: Self.availableKey) }
        }
    }

    /// Whether a daily check is due: never checked, a day gone since the last, or the clock turned
    /// back past it.
    public func isDue() -> Bool {
        guard let lastChecked else { return true }
        let elapsed = now().timeIntervalSince(lastChecked)
        return elapsed < 0 || elapsed >= Self.interval
    }

    /// Checks if daily checks are on and one is due; a failure waits for the next.
    public func checkIfDue() async {
        guard isEnabled, isDue(), !isChecking else { return }
        _ = try? await check()
    }

    /// Checks now, whether or not daily checks are on (Check for Updates Now).
    @discardableResult
    public func check() async throws -> Outcome {
        isChecking = true
        defer { isChecking = false }
        lastChecked = now()
        storage.set(lastChecked, forKey: Self.lastCheckedKey)

        let (data, response) = try await fetch(request())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let latest: ReleaseVersion?
        switch status {
        case 200: latest = try Self.latestVersion(in: data)
        case 404: latest = nil
        default: throw CheckError.status(status)
        }
        guard let latest else {
            remember(nil)
            return .noRelease
        }
        guard latest > current else {
            remember(nil)
            return .upToDate(latest: latest)
        }
        let release = Release(version: latest, page: try Self.page(for: latest, in: repository))
        remember(release)
        return .newer(release)
    }

    /// The request for the latest release: GitHub's REST API, which wants a User-Agent. The language
    /// is set, so the system's own (the user's locale) isn't sent.
    func request() throws -> URLRequest {
        var request = URLRequest(url: try Self.url("https://api.github.com/repos/\(repository)/releases/latest", for: repository),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Gitrasil/\(current)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The version of the latest release in the API's reply; nil for a draft, a pre-release, or a
    /// tag that isn't a version.
    static func latestVersion(in data: Data) throws -> ReleaseVersion? {
        guard let reply = try? JSONDecoder().decode(LatestReleaseReply.self, from: data) else { throw CheckError.unreadable }
        guard reply.draft != true, reply.prerelease != true else { return nil }
        return ReleaseVersion(reply.tag)
    }

    /// A release's page, made from the repository and version rather than taken from the reply, so
    /// what the menu opens is always on github.com. Releases are tagged "v" + the version.
    static func page(for version: ReleaseVersion, in repository: String) throws -> URL {
        try url("https://github.com/\(repository)/releases/tag/v\(version)", for: repository)
    }

    /// Whether `text` is a repository as GitHub names them, "owner/name" in letters, digits, `-`, `_`
    /// and `.` (not only dots), so it can only fill its place in a URL's path.
    static func isRepository(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        func isName(_ part: Substring) -> Bool {
            func allowed(_ scalar: Unicode.Scalar) -> Bool {
                scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || "-_.".unicodeScalars.contains(scalar))
            }
            return !part.isEmpty && !part.allSatisfy { $0 == "." } && part.unicodeScalars.allSatisfy(allowed)
        }
        return parts.count == 2 && parts.allSatisfy(isName)
    }

    private static func url(_ text: String, for repository: String) throws -> URL {
        guard isRepository(repository), let url = URL(string: text) else { throw CheckError.notARepository(repository) }
        return url
    }

    private func remember(_ release: Release?) {
        available = release
        storage.set(release.map(\.version.description), forKey: Self.availableKey)
    }

    /// Sends it with a session that keeps no cookies, cache or credentials.
    public nonisolated static let urlSession: Fetch = { request in
        try await ephemeral.data(for: request)
    }

    private nonisolated static let ephemeral = URLSession(configuration: .ephemeral)
}
