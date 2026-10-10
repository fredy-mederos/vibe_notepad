import CoreServices
import Foundation

/// Watches a folder tree with FSEvents and reports, coalesced and on the main queue, the
/// folders whose contents changed.
final class DirectoryWatcher {
    struct Change {
        /// The folder whose entries changed (no trailing slash, as FSEvents reports it: symlinks resolved).
        var path: String
        /// Events were dropped or coalesced: everything under `path` may have changed.
        var includesSubfolders: Bool
    }

    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private let onChange: ([Change]) -> Void

    init(url: URL, latency: TimeInterval = 0.35, onChange: @escaping ([Change]) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self)
            let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
            var changes: [Change] = []
            for index in 0..<count {
                guard let path = list[index] as? String else { continue }
                let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
                changes.append(Change(path: trimmed, includesSubfolders: flags[index] & rescan != 0))
            }
            // The stream delivers on the main queue.
            MainActor.assumeIsolated { watcher.onChange(changes) }
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [url.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
