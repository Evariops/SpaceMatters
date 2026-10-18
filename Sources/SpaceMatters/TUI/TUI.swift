import Foundation

/// `SpaceMatters --tui [path]` — the scan, browsable in a terminal (SPEC-15).
///
/// Same engine, same tree, same live fill as the window: the scanner runs on
/// its worker pool and this loop samples the atomics ten times a second, as the
/// GUI does. What a terminal can't carry — the treemap, the sunburst, cleanup —
/// stays in the app; this is the outline, for when there is no window to open.
enum TUI {

    /// Frame period while the scan runs. Once it has finished, frames are still
    /// built at this rate but only written when something changed.
    private static let tickMilliseconds: Int32 = 100

    @discardableResult
    static func run(path: String) -> Int32 {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            FileHandle.standardError.write(Data(
                "error: --tui needs an interactive terminal — for pipes, use --scan or --briefing\n".utf8))
            return 2
        }
        guard FileManager.default.fileExists(atPath: path) else {
            FileHandle.standardError.write(Data("error: path does not exist: \(path)\n".utf8))
            return 1
        }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        let rootPath = url.path
        let root = FSNode(name: url.lastPathComponent.isEmpty ? rootPath : url.lastPathComponent, parent: nil)
        let scanner = DirectoryScanner(root: root, seeds: [.init(path: rootPath, node: root)],
                                       skipPaths: DirectoryScanner.recommendedSkipPaths(seedPaths: [rootPath]))

        guard Terminal.enter() else {
            FileHandle.standardError.write(Data("error: could not put the terminal in raw mode\n".utf8))
            return 1
        }
        defer { Terminal.leave() }

        var browser = TUIBrowser(root: root, rootPath: rootPath)
        let start = Date()
        var finishedAt: Date?
        var lastFrame: [String] = []
        var lastSize = (width: 0, height: 0)
        scanner.start()

        while true {
            if finishedAt == nil, scanner.isFinished { finishedAt = Date() }
            let size = Terminal.size()
            if size != lastSize {
                Terminal.clear()
                lastFrame = []
                lastSize = size
            }

            let status = TUIBrowser.Status(
                scanning: finishedAt == nil,
                elapsed: (finishedAt ?? Date()).timeIntervalSince(start),
                files: root.fileCount.load(ordering: .relaxed),
                folders: scanner.dirCount.load(ordering: .relaxed),
                skipped: scanner.errorCount.load(ordering: .relaxed),
                types: browser.showTypes ? scanner.snapshotExtensions(limit: 100) : [])
            let frame = browser.render(width: size.width, height: size.height, status: status)
            Terminal.draw(frame, over: lastFrame)
            lastFrame = frame

            guard let keys = Terminal.readKeys(timeout: tickMilliseconds) else { break }
            var keepOpen = true
            for key in keys where keepOpen { keepOpen = browser.apply(key) }
            if !keepOpen { break }
        }

        // Quitting mid-scan is allowed: stop handing out work, and let the
        // process exit take the workers down — nothing on disk was touched.
        scanner.cancel()
        return 0
    }
}
