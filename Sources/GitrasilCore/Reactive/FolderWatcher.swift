import Foundation

/// Fires when entries are added to, removed from or renamed in any of a few directories (not
/// their contents further down): a folder pin's folder and its plain subfolders, so a repository
/// cloned, moved or deleted there is noticed without hearing every write inside the repositories.
/// Bursts are coalesced (`delay`). Runs its handler on the main queue.
public final class FolderWatcher {
    public let paths: [String]
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    public init(paths: [String], delay: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.paths = paths
        for path in paths {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
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

    public func stop() {
        pending?.cancel()
        for source in sources { source.cancel() }
        sources = []
    }

    deinit { stop() }
}
