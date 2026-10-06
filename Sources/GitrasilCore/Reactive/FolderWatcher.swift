import Foundation

/// Fires when entries are added to, removed from or renamed in any of a few directories (not
/// their contents further down): a folder pin's folder and its plain subfolders, so a repository
/// cloned, moved or deleted there is noticed without hearing every write inside the repositories.
/// Bursts are coalesced (`delay`). Runs its handler on the main queue.
public final class FolderWatcher {
    public let paths: [String]
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    /// Each path's folder as it was opened (nil where there was none), to notice one replaced.
    private var identities: [Identity?] = []

    public init(paths: [String], delay: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.paths = paths
        for path in paths {
            let descriptor = open(path, O_EVTONLY)
            var info = stat()
            guard descriptor >= 0, fstat(descriptor, &info) == 0 else {
                if descriptor >= 0 { close(descriptor) }
                identities.append(nil)
                continue
            }
            identities.append(Identity(info))
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                self?.pending?.cancel()
                let work = DispatchWorkItem(block: onChange)
                self?.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    /// Whether every path is still the folder that was opened. A folder deleted and made again (or
    /// one made where there was none) is a new folder, which this watcher can't see into.
    public var isCurrent: Bool {
        zip(paths, identities).allSatisfy { path, identity in
            var info = stat()
            return (stat(path, &info) == 0 ? Identity(info) : nil) == identity
        }
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }

    public func stop() {
        pending?.cancel()
        for source in sources { source.cancel() }
        sources = []
    }

    deinit { stop() }
}
