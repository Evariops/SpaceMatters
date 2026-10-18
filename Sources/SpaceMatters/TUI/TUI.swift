import Foundation

/// `SpaceMatters --tui [path]` — the app, in a terminal (SPEC-15).
///
/// Same engine, same tree, same live fill as the window, and the same
/// controllers behind every action: this is a *view*, not a second app. What a
/// terminal cannot carry — the treemap, the sunburst — is replaced by the
/// per-row bar and the queries behind the MCP tools (find, largest, cold); the
/// rest is here, deleting included, with the confirmations that earns.
///
/// Threading: `ScanController` and `CleanupController` are `@MainActor` and the
/// scanner's live refresh rides the main run loop, so the main thread runs the
/// run loop and the frame loop gets a thread of its own. Blocking on `poll()`
/// in a thread that owes a run loop its time is how a "live" view stops
/// filling in.
///
/// - Tag: TUI
enum TUI {

    /// Frame period. Ten frames a second is the rate the window samples the
    /// tree at; each frame is diffed, so an idle scan costs a `poll()`.
    private static let tickMilliseconds: Int32 = 100

    @discardableResult
    static func run(path: String?) -> Int32 {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            FileHandle.standardError.write(Data(
                "error: --tui needs an interactive terminal — for pipes, use --scan or --briefing\n".utf8))
            return 2
        }
        if let path, !FileManager.default.fileExists(atPath: path) {
            FileHandle.standardError.write(Data("error: path does not exist: \(path)\n".utf8))
            return 1
        }

        // Built here, on the main thread, before the run loop starts: the
        // controllers are main-actor-isolated and the frame loop only ever
        // reaches them through the host.
        let app = MainActor.assumeIsolated { () -> TUIApp in
            let host = AppTUIHost(scan: ScanController(), cleanup: CleanupController())
            let app = TUIApp(host: host)
            if let path { app.open(path: URL(fileURLWithPath: path).standardizedFileURL.path) }
            return app
        }

        guard Terminal.enter() else {
            FileHandle.standardError.write(Data("error: could not put the terminal in raw mode\n".utf8))
            return 1
        }

        let loop = Thread {
            frames(app: app)
            // The run loop never returns, so the frame loop is what ends the
            // process — after giving the terminal back.
            Terminal.leave()
            exit(0)
        }
        loop.name = "SpaceMatters TUI"
        loop.stackSize = 1 << 20
        loop.start()

        // Drives the main actor (every controller call lands here), the
        // scanner's refresh timer and FSEvents.
        RunLoop.main.run()
        return 0
    }

    private static func frames(app: TUIApp) {
        var lastFrame: [String] = []
        var lastSize = (width: 0, height: 0)

        while true {
            app.refresh()
            if app.wantsToQuit { return }

            let size = Terminal.size()
            if size != lastSize {
                Terminal.clear()
                lastFrame = []
                lastSize = size
            }
            let frame = app.render(width: size.width, height: size.height)
            Terminal.draw(frame, over: lastFrame)
            lastFrame = frame

            // `nil` means input is gone (the terminal was closed): stop rather
            // than spin on a descriptor that reads as ready forever.
            guard let keys = Terminal.readKeys(timeout: tickMilliseconds) else { return }
            for key in keys {
                if !app.apply(key) { return }
            }
            if app.wantsToQuit { return }
        }
    }
}
