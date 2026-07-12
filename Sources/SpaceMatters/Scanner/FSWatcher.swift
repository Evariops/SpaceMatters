import Foundation
import CoreServices

/// One coalesced FSEvents change: the directory whose *direct* contents changed,
/// plus the event flags. At directory granularity the per-item flags
/// (`ItemRenamed`, `ItemCreated`…) are never delivered — the ones that carry
/// signal are `MustScanSubDirs` (the kernel coalesced events away: the whole
/// subtree must be re-scanned) and `RootChanged` (the watched root itself moved
/// or disappeared).
struct FSChange {
    let path: String
    let flags: FSEventStreamEventFlags

    var mustScanSubDirs: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
    var rootChanged: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 }
}

/// Watches a set of directory trees with FSEvents and reports coalesced changed
/// paths. Directory-level granularity (no `FileEvents` flag) with a debounce
/// latency, so a busy tree can't flood us — an event means "this directory's
/// direct contents changed", precise enough to re-stat just that directory
/// (SPEC-11). Delivered on a private dispatch queue.
final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.spacematters.fswatcher", qos: .utility)
    private let paths: [String]
    private let latency: CFTimeInterval
    private let handler: ([FSChange]) -> Void

    /// `handler` is invoked on the private queue with the batch of changes.
    init(paths: [String], latency: CFTimeInterval = 1.0, handler: @escaping ([FSChange]) -> Void) {
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
        // WatchRoot: get told when the watched root itself is renamed/deleted
        // (`RootChanged`) — deltas can't reconcile that; the UI offers a Rescan.
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot)
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

    fileprivate func deliver(_ changes: [FSChange]) { handler(changes) }
}

/// C callback trampoline: recover the `FSWatcher` from `info` and forward the
/// changed paths (delivered as a `CFArray` of `CFString` thanks to `UseCFTypes`)
/// paired with their event flags.
private let fsWatcherCallback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
    guard let info else { return }
    let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
    let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
    var changes: [FSChange] = []
    changes.reserveCapacity(count)
    for i in 0..<count {
        if let raw = CFArrayGetValueAtIndex(cfArray, i) {
            let path = unsafeBitCast(raw, to: CFString.self) as String
            changes.append(FSChange(path: path, flags: eventFlags[i]))
        }
    }
    watcher.deliver(changes)
}
