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

    /// Frame period while something is moving — the rate the window samples
    /// the tree at. Each frame is diffed, so an unchanged one writes nothing.
    static let liveTickMilliseconds: Int32 = 100
    /// …and once the scan is done with no job running, the loop stops redrawing
    /// on a timer: it waits for a key, waking on its own only often enough to
    /// pick up what the live watcher changed underneath.
    static let idleTickMilliseconds: Int32 = 1000

    /// How long to wait for input before building the next frame. Pure, so
    /// "no 10 Hz once nothing moves" is a value a test can check.
    static func tick(for status: TUIStatus) -> Int32 {
        status.isScanning || status.busy != nil ? liveTickMilliseconds : idleTickMilliseconds
    }

    @discardableResult
    static func run(path: String?) -> Int32 {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            return fail("--tui needs an interactive terminal — for pipes, use --scan or --briefing", 2)
        }
        // A terminal that cannot move its cursor cannot host this: `TERM=dumb`
        // (Emacs' shell, some CI shells) or no TERM at all would take the
        // escape sequences literally.
        let term = ProcessInfo.processInfo.environment["TERM"] ?? ""
        guard !term.isEmpty, term != "dumb" else {
            return fail("--tui needs a terminal that understands VT sequences (TERM is "
                        + (term.isEmpty ? "unset" : "\"\(term)\"") + ") — use --scan or --briefing", 2)
        }
        if let path, !FileManager.default.fileExists(atPath: path) {
            return fail("path does not exist: \(path)", 1)
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
            return fail("could not put the terminal in raw mode", 1)
        }

        let loop = Thread {
            let code = frames(app: app)
            // The run loop never returns, so the frame loop is what ends the
            // process — after giving the terminal back.
            Terminal.leave()
            exit(code)
        }
        loop.name = "SpaceMatters TUI"
        loop.stackSize = 1 << 20
        loop.start()

        // Drives the main actor (every controller call lands here), the
        // scanner's refresh timer and FSEvents.
        RunLoop.main.run()
        return 0
    }

    private static func fail(_ message: String, _ code: Int32) -> Int32 {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        return code
    }

    /// The frame loop. Returns the process exit code: losing the terminal is
    /// not a clean quit and must not report as one.
    private static func frames(app: TUIApp) -> Int32 {
        var lastFrame: [String] = []
        var lastSize = (width: 0, height: 0)

        while true {
            app.refresh()
            if app.wantsToQuit { return 0 }

            // Ctrl-Z then `fg` left the shell's output on screen, and a resize
            // invalidates every line's width: both mean "paint it all again".
            let resumed = Terminal.resumeIfNeeded()
            let size = Terminal.size()
            if resumed || Terminal.takeResize() || size != lastSize {
                Terminal.clear()
                lastFrame = []
                lastSize = size
            }

            let frame = app.render(width: size.width, height: size.height)
            if Terminal.draw(frame, over: lastFrame, width: size.width, cursorRow: app.cursorRow) {
                lastFrame = frame
            } else {
                // A write was lost: do not record a frame that is not on
                // screen, or the diff would skip those lines forever.
                lastFrame = []
            }

            // `nil` means input is gone (the terminal was closed): stop rather
            // than spin on a descriptor that reads as ready forever.
            guard let keys = Terminal.readKeys(timeout: tick(for: app.status)) else { return 1 }
            for key in keys {
                guard app.apply(key) else { return 0 }
            }
            if app.wantsToQuit { return 0 }
        }
    }
}
