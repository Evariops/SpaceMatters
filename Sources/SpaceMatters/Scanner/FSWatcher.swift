import Foundation
import CoreServices

/// Watches a set of directory trees with FSEvents and reports coalesced changed
/// paths. Directory-level granularity (no `FileEvents` flag) with a debounce
/// latency, so a busy tree can't flood us — enough to mark a subtree dirty and
/// offer a targeted re-scan (SPEC-04). Delivered on a private dispatch queue.
final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.spacematters.fswatcher", qos: .utility)
    private let paths: [String]
    private let latency: CFTimeInterval
    private let handler: ([String]) -> Void

    /// `handler` is invoked on the private queue with the batch of changed paths.
    init(paths: [String], latency: CFTimeInterval = 1.0, handler: @escaping ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        // retain/release make the *stream* keep the watcher alive: without them
        // a callback in flight on the private queue races `stop()` + the last
        // release on the main thread, and `takeUnretainedValue` dereferences a
        // freed object. With them, FSEvents holds its own +1 until the stream
        // is destroyed, after any pending callback.
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<FSWatcher>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FSWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsWatcherCallback,
            &ctx,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    fileprivate func deliver(_ paths: [String]) { handler(paths) }
}

/// C callback trampoline: recover the `FSWatcher` from `info` and forward the
/// changed paths (delivered as a `CFArray` of `CFString` thanks to `UseCFTypes`).
private let fsWatcherCallback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
    guard let info else { return }
    let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
    let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
    var paths: [String] = []
    paths.reserveCapacity(count)
    for i in 0..<count {
        if let raw = CFArrayGetValueAtIndex(cfArray, i) {
            paths.append(unsafeBitCast(raw, to: CFString.self) as String)
        }
    }
    watcher.deliver(paths)
}
