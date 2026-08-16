import Foundation

/// One JSON line per cleaned target, appended to
/// `~/Library/Logs/SpaceMatters/cleanup.jsonl` — the forensic trail behind any
/// field report: what did the app touch, when, with which engine, what was
/// running at the time, and how did it end. Best-effort by design: journaling
/// must never fail or slow a clean.
enum CleanupJournal {
    struct Entry: Codable, Equatable {
        var timestamp: Date = .init()
        let targetID: String
        /// "file" for the built-in engine, the native label otherwise.
        var engine: String
        /// The paths touched — capped, see `init`. `pathCount` is the true
        /// figure whenever this is a sample.
        let paths: [String]
        /// How many paths the target actually had. Equal to `paths.count`
        /// except on a discovered target big enough to be sampled.
        var pathCount: Int
        let bytesBefore: Int64
        var bytesAfter: Int64 = 0
        var removed = 0
        var failed = 0
        var refused = 0
        /// Native cleaner failure, when one happened.
        var diagnostic: String?
        /// Tools detected running for this target when the clean started.
        var activeTools: [String] = []

        /// At most this many paths are written per entry.
        ///
        /// A hand-picked cache target has one or two paths, but a discovered one
        /// can have thousands — a real machine produced 8,360 `bin`/`obj`
        /// folders in a single target. Writing them all would turn one journal
        /// line into hundreds of kilobytes and make the file unreadable for the
        /// thing it exists for: seeing at a glance what the app touched. The
        /// count is kept exact; the list becomes a sample.
        static let maxJournalledPaths = 32

        init(targetID: String, engine: String, paths: [String], bytesBefore: Int64) {
            self.targetID = targetID
            self.engine = engine
            self.paths = Array(paths.prefix(Self.maxJournalledPaths))
            self.pathCount = paths.count
            self.bytesBefore = bytesBefore
        }
    }

    static func append(_ entry: Entry, directory: URL = defaultDirectory) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        let file = directory.appendingPathComponent("cleanup.jsonl")
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SpaceMatters")
    }
}
