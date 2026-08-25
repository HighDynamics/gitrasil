import Foundation
import CoreServices

/// Watches directories and fires when their contents change. Abstracted so the store can be
/// tested without real filesystem events.
public protocol DirectoryWatching: AnyObject, Sendable {
    func start()
    func stop()
}

/// FSEvents-backed watcher (engineering notes → Live refresh). Coalescing is handled two ways:
/// FSEvents' own latency batches bursts, and the store's re-derive read coalesces by kind — so a
/// flurry of writes collapses to a single snapshot re-derive.
public final class FSEventsWatcher: DirectoryWatching, @unchecked Sendable {
    private let paths: [String]
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "gitrasil.fsevents")
    private var stream: FSEventStreamRef?

    public init(paths: [String], latency: TimeInterval = 0.15, onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.latency = latency
        self.onChange = onChange
    }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }

        let flags = UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        guard let created = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
