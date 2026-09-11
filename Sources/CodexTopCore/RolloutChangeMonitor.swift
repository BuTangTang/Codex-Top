import Foundation
import Dispatch
import Darwin

/// Watches a bounded set of local rollout files without reading their contents.
/// The owner decides which files matter and coalesces refreshes after a change.
@MainActor public final class RolloutChangeMonitor {
    private var watches: [String: RolloutFileWatch] = [:]
    private let onChange: @MainActor @Sendable () -> Void

    public init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
    }

    public func update(urls: Set<URL>) {
        let paths = Set(urls.filter(\.isFileURL).map { $0.standardizedFileURL.path })
        let desired = Set(paths.sorted().prefix(64))
        for path in Set(watches.keys).subtracting(desired) {
            watches.removeValue(forKey: path)?.cancel()
        }
        for path in desired.sorted() where watches[path] == nil {
            addWatch(path: path)
        }
    }

    /// Stops current watches. A later update may start a new set.
    public func stop() {
        let previous = watches
        watches.removeAll()
        for watch in previous.values { watch.cancel() }
    }

    private func addWatch(path: String) {
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete, .revoke],
            queue: .main
        )
        let watch = RolloutFileWatch(source: source)
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self, weak watch] in
            guard let watch else { return }
            // This source is delivered only on the main queue. Keeping the
            // handler synchronous also makes stop/update suppress queued events.
            MainActor.assumeIsolated {
                self?.receive(path: path, token: watch.token, events: watch.source.data)
            }
        }
        watches[path] = watch
        source.resume()
    }

    private func receive(path: String, token: UUID, events: DispatchSource.FileSystemEvent) {
        guard !events.isEmpty, let watch = watches[path], watch.token == token else { return }
        if !events.intersection([.rename, .delete, .revoke]).isEmpty {
            // The descriptor follows an inode, not its path. Drop it before
            // notifying so a reentrant update can attach to a replacement file.
            watches.removeValue(forKey: path)
            watch.cancel()
        }
        onChange()
    }
}

/// The source and token never change. Source access is on the main queue except
/// cancel(), which Dispatch permits from any thread, including deinitialization.
private final class RolloutFileWatch: @unchecked Sendable {
    let token = UUID()
    let source: any DispatchSourceFileSystemObject

    init(source: any DispatchSourceFileSystemObject) { self.source = source }
    func cancel() { source.cancel() }
    deinit { source.cancel() }
}
