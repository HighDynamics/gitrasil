import Foundation

/// Formats a git ISO-8601 committer date (`%cI`) as a short relative string ("2h ago").
enum RelativeTime {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func string(_ isoDate: String) -> String {
        guard let date = iso.date(from: isoDate) else { return "" }
        return relative.localizedString(for: date, relativeTo: Date())
    }
}
