import Foundation

/// A key the browser understands, decoded from raw terminal bytes.
enum TerminalKey: Equatable {
    case up, down, left, right
    case pageUp, pageDown, home, end
    case enter, backspace, escape, tab
    /// The `Delete` key (`fn⌫` on a Mac keyboard), bound to "move to Trash" —
    /// `⌫` itself stays "go up one level", as it is in the window's outline.
    case delete
    /// Ctrl-C / Ctrl-D: raw mode turns signal generation off, so they arrive
    /// as bytes and quit like `q` instead of leaving the terminal raw.
    case interrupt
    /// Ctrl-Z, for the same reason: raw mode delivers it as a byte, and the
    /// frame loop turns it back into the job-control stop it stands for.
    case suspend
    /// Text the terminal marked as pasted (bracketed paste). Never a command:
    /// only a text field takes it, so a paste cannot drive the interface.
    case paste(String)
    case char(Character)
}

/// Raw-mode terminal I/O for `--tui` (SPEC-15): termios, the alternate screen,
/// the window size, signals, and the byte → key decoder.
///
/// Plain VT/ANSI sequences — every terminal macOS ships or people install
/// speaks them — so no curses and no dependency, in the spirit of the
/// hand-rolled JSON-RPC behind `--mcp`.
///
/// - Tag: Terminal
enum Terminal {

    // MARK: Session

    /// Switch to raw mode and the alternate screen. `false` when the terminal
    /// refused, in which case nothing was changed.
    ///
    /// Handlers are installed *before* raw mode: a crash or a `kill` in the
    /// window between the two would otherwise leave the shell raw with no one
    /// left to restore it.
    static func enter() -> Bool {
        installHandlers()
        return withSignalsBlocked {
            guard tcgetattr(STDIN_FILENO, savedTermios) == 0 else { return false }
            var raw = savedTermios.pointee
            raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
            raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
            // Read returns as soon as one byte is there and never blocks on a
            // timer of its own — `poll` is what decides how long to wait.
            withUnsafeMutableBytes(of: &raw.c_cc) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
            guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return false }
            sessionFlag.pointee = 1
            // Alternate screen, cursor hidden, autowrap off — the last is a
            // safety net: a line misjudged one cell too wide is clipped instead
            // of wrapping and shearing every line below it. Bracketed paste on,
            // so a paste arrives marked as one rather than as keystrokes: a
            // pasted `Do you have a minute?⏎` must not be read as `D`, then `y`.
            output("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l\u{1B}[?2004h\u{1B}[2J")
            return true
        }
    }

    /// Undo `enter()`. Idempotent, and async-signal-safe — it is also what the
    /// signal handlers run, so it only calls `write` and `tcsetattr`, and it
    /// reaches its state through raw pointers rather than Swift accessors
    /// (which are subject to exclusivity checks a signal can trap on).
    static func leave() {
        withSignalsBlocked { restoreTerminal() }
    }

    /// True while the alternate screen is up.
    static var isActive: Bool { sessionFlag.pointee != 0 }

    /// Ctrl-Z (or `kill -TSTP`) gave the terminal back and suspended us; `fg`
    /// woke us up. Re-enter raw mode and tell the caller to repaint from
    /// scratch — the shell has been drawing over our screen meanwhile.
    ///
    /// Returns `true` when a resume actually happened.
    static func resumeIfNeeded() -> Bool {
        guard resumeFlag.pointee != 0 else { return false }
        resumeFlag.pointee = 0
        installHandlers() // SIGTSTP was reset to the default to suspend for real
        _ = enter()
        return true
    }

    /// Ctrl-Z: stop the way the shell expects. The SIGTSTP handler gives the
    /// terminal back first, and `resumeIfNeeded` takes it again on `fg`.
    static func suspend() {
        raise(SIGTSTP)
    }

    /// Drop everything typed or pasted that has not been read yet — called
    /// once a question is on screen, so that only a key pressed after it was
    /// drawn can answer it. A paste cut short by the flush is closed too: what
    /// is left of it either went with the flush or arrives as a burst, which a
    /// confirmation refuses (`TUIApp.apply(batch:)`).
    static func discardInput() {
        tcflush(STDIN_FILENO, TCIFLUSH)
        pending = []
        pasting = false
    }

    /// The window was resized since the last call (SIGWINCH).
    static func takeResize() -> Bool {
        guard resizeFlag.pointee != 0 else { return false }
        resizeFlag.pointee = 0
        return true
    }

    // MARK: Output

    static func size() -> (width: Int, height: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (80, 24)
    }

    static func clear() {
        output("\u{1B}[2J")
    }

    /// Repaint only the lines that changed since `previous` — at ten frames a
    /// second most of the screen is identical, and rewriting it would flicker.
    ///
    /// `false` when a write was lost, so the caller can repaint from scratch
    /// rather than believe a half-written frame is on screen.
    @discardableResult
    static func draw(_ frame: [String], over previous: [String], width: Int, cursorRow: Int?) -> Bool {
        let text = diff(frame, over: previous, width: width, cursorRow: cursorRow)
        return text.isEmpty ? true : output(text)
    }

    /// The escape sequence that turns `previous` into `frame`. Pure, so what
    /// goes on the wire is a value a test can read.
    ///
    /// A line that fills the terminal gets no `ESC[K`: with autowrap off the
    /// cursor stays *on* the last column after writing it, and erase-to-end
    /// would wipe the cell just drawn.
    static func diff(_ frame: [String], over previous: [String], width: Int, cursorRow: Int?) -> String {
        var out = ""
        for (index, line) in frame.enumerated() where index >= previous.count || previous[index] != line {
            out += "\u{1B}[\(index + 1);1H\u{1B}[0m" + line + "\u{1B}[0m"
            if TextCell.displayWidth(line) < width { out += "\u{1B}[K" }
        }
        if previous.count > frame.count {
            for index in frame.count..<previous.count { out += "\u{1B}[\(index + 1);1H\u{1B}[K" }
        }
        // Park the cursor on the selected row even though it is hidden: screen
        // readers and Zoom follow the cursor, and a cursor left wherever the
        // last write ended follows nothing.
        if !out.isEmpty, let cursorRow, cursorRow >= 0 {
            out += "\u{1B}[\(cursorRow + 1);1H"
        }
        return out
    }

    /// Write everything or report failure. `EAGAIN` is retried through `poll`:
    /// stdin and stdout normally share one file description, so the
    /// non-blocking flag a shell left on stdin applies here too, and dropping
    /// the rest of a frame would leave stale lines the caller thinks are fresh.
    @discardableResult
    static func output(_ text: String) -> Bool {
        var text = text
        return text.withUTF8 { buffer in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let n = write(STDOUT_FILENO, base + offset, buffer.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var fds = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                    if poll(&fds, 1, writeTimeoutMilliseconds) <= 0 { return false }
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static let writeTimeoutMilliseconds: Int32 = 250

    // MARK: Input

    /// Bytes of an escape sequence split across reads. Touched only by the
    /// frame loop's thread.
    private nonisolated(unsafe) static var pending: [UInt8] = []
    /// Inside a bracketed paste whose end marker has not been read yet.
    private nonisolated(unsafe) static var pasting = false

    /// Wait up to `timeout` milliseconds for keys. `[]` on timeout; `nil` once
    /// input is gone (terminal closed) — the caller must stop rather than spin
    /// on a descriptor that is readable forever.
    static func readKeys(timeout: Int32) -> [TerminalKey]? {
        guard let bytes = read(timeout: timeout) else { return nil }
        guard !bytes.isEmpty || !pending.isEmpty else { return [] }

        var result = decode(pending + bytes, pasting: &pasting)
        pending = result.remainder
        // An unfinished sequence is held back rather than misread as `Esc` plus
        // its letters. Give the rest of it one short window to arrive — long
        // enough for a terminal's own bytes, short enough that a bare Esc
        // still feels instant. Inside a paste the held-back bytes are the start
        // of its end marker: they wait for the next read, however long.
        if !pending.isEmpty, !pasting {
            if let more = read(timeout: continuationMilliseconds), !more.isEmpty {
                let second = decode(pending + more, pasting: &pasting)
                result.keys += second.keys
                pending = second.remainder
            }
            if !pending.isEmpty, !pasting {
                // Nothing came: it really was a lone Esc (or junk).
                result.keys += flushPending()
            }
        }
        return result.keys
    }

    /// How long an incomplete escape sequence waits for its continuation.
    private static let continuationMilliseconds: Int32 = 25

    private static func flushPending() -> [TerminalKey] {
        let keys: [TerminalKey] = pending.first == 0x1B ? [.escape] : []
        pending = []
        return keys
    }

    /// One `poll` + `read`. `nil` when input is gone, `[]` on timeout.
    private static func read(timeout: Int32) -> [UInt8]? {
        var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&fds, 1, timeout)
        if ready < 0 { return errno == EINTR ? [] : nil }
        guard ready > 0 else { return [] }
        guard fds.revents & Int16(POLLIN) != 0 else { return nil } // POLLHUP / POLLERR / POLLNVAL
        var buffer = [UInt8](repeating: 0, count: 64)
        let capacity = buffer.count
        let n = Darwin.read(STDIN_FILENO, &buffer, capacity)
        if n < 0 { return errno == EINTR || errno == EAGAIN ? [] : nil }
        guard n > 0 else { return nil }
        return Array(buffer[0..<n])
    }

    /// Bytes → keys, plus whatever tail could not be decoded yet. Pure, so the
    /// escape-sequence grammar is testable.
    ///
    /// Arrows arrive as CSI (`ESC [ A`) or SS3 (`ESC O A`) depending on the
    /// terminal's cursor-key mode; modifiers ride as parameters (`ESC [ 1 ; 5 A`
    /// is Ctrl-↑) and are ignored. A sequence cut off by the read is returned
    /// as `remainder` for the next read to complete — never misread as
    /// keystrokes.
    static func decode(_ bytes: [UInt8]) -> (keys: [TerminalKey], remainder: [UInt8]) {
        var pasting = false
        return decode(bytes, pasting: &pasting)
    }

    /// `ESC [ 200 ~` … `ESC [ 201 ~`: what a terminal wraps a paste in once
    /// bracketed paste is on.
    private static let pasteStart: [UInt8] = Array("\u{1B}[200~".utf8)
    private static let pasteEnd: [UInt8] = Array("\u{1B}[201~".utf8)

    /// The same, carrying whether a paste is open across reads: a paste can be
    /// far longer than one read, and none of it may come out as keystrokes.
    static func decode(_ bytes: [UInt8], pasting: inout Bool) -> (keys: [TerminalKey], remainder: [UInt8]) {
        var keys: [TerminalKey] = []
        var i = 0
        while i < bytes.count {
            if pasting {
                if let end = firstIndex(of: pasteEnd, in: bytes, from: i) {
                    if end > i { keys.append(.paste(String(decoding: bytes[i..<end], as: UTF8.self))) }
                    pasting = false
                    i = end + pasteEnd.count
                    continue
                }
                // The end marker may be cut by the read: hold back whatever
                // could be its beginning, hand over the rest.
                var held = min(pasteEnd.count - 1, bytes.count - i)
                while held > 0, !bytes[(bytes.count - held)...].elementsEqual(pasteEnd.prefix(held)) { held -= 1 }
                let stop = bytes.count - held
                if stop > i { keys.append(.paste(String(decoding: bytes[i..<stop], as: UTF8.self))) }
                return (keys, Array(bytes[stop...]))
            }
            let byte = bytes[i]
            switch byte {
            case 0x1B:
                guard i + 1 < bytes.count else { return (keys, Array(bytes[i...])) }
                if bytes[i + 1] == 0x5B || bytes[i + 1] == 0x4F {
                    var j = i + 2
                    var params: [UInt8] = []
                    while j < bytes.count, (0x30...0x3F).contains(bytes[j]) {
                        params.append(bytes[j])
                        j += 1
                    }
                    guard j < bytes.count else { return (keys, Array(bytes[i...])) }
                    if bytes[j] == UInt8(ascii: "~"), params == Array("200".utf8) {
                        pasting = true
                        i = j + 1
                        continue
                    }
                    if let key = sequenceKey(final: bytes[j], params: params) { keys.append(key) }
                    i = j + 1
                    continue
                }
                // ESC + key is Meta/Alt. Nothing is bound to it, and emitting a
                // bare Esc here would make Alt-q quit the browser.
                i += 2
                continue
            case 0x0D, 0x0A:
                keys.append(.enter)
            case 0x7F, 0x08:
                keys.append(.backspace)
            case 0x03, 0x04:
                keys.append(.interrupt)
            case 0x1A:
                keys.append(.suspend)
            case 0x09:
                keys.append(.tab)
            case 0x20...0x7E:
                keys.append(.char(Character(Unicode.Scalar(byte))))
            case 0x80...0xFF:
                // A typed `é` or `ü` arrives as several bytes: the text fields
                // (search pattern, path to scan) must take them as one key.
                var j = i
                while j < bytes.count, bytes[j] >= 0x80 { j += 1 }
                // A UTF-8 character split across reads waits for its tail.
                if j == bytes.count, let last = bytes.last, last >= 0xC0 || bytes.count - i < 4 {
                    let text = String(decoding: bytes[i..<j], as: UTF8.self)
                    if text.unicodeScalars.contains("\u{FFFD}") { return (keys, Array(bytes[i...])) }
                }
                for character in String(decoding: bytes[i..<j], as: UTF8.self) where character != "\u{FFFD}" {
                    keys.append(.char(character))
                }
                i = j
                continue
            default:
                break // other control bytes: no binding uses them
            }
            i += 1
        }
        return (keys, [])
    }

    private static func firstIndex(of marker: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count - start >= marker.count else { return nil }
        for index in start...(bytes.count - marker.count)
        where bytes[index..<(index + marker.count)].elementsEqual(marker) {
            return index
        }
        return nil
    }

    private static func sequenceKey(final: UInt8, params: [UInt8]) -> TerminalKey? {
        switch final {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "C"): return .right
        case UInt8(ascii: "D"): return .left
        case UInt8(ascii: "H"): return .home
        case UInt8(ascii: "F"): return .end
        case UInt8(ascii: "~"):
            // `ESC [ 5 ~` style; the first parameter names the key.
            let first = params.split(separator: UInt8(ascii: ";")).first.map { String(decoding: $0, as: UTF8.self) } ?? ""
            switch first {
            case "1", "7": return .home
            case "3": return .delete
            case "4", "8": return .end
            case "5": return .pageUp
            case "6": return .pageDown
            default: return nil
            }
        default:
            return nil
        }
    }

    // MARK: Signals

    /// Signals that must not leave the terminal raw: the ones a user or a
    /// supervisor sends, and the ones a crash raises. `SIGKILL`/`SIGSTOP`
    /// cannot be caught — a `kill -9` is the one case the shell's own `reset`
    /// is the answer to.
    private static let fatalSignals: [Int32] = [
        SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE,
        SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGBUS, SIGSEGV, SIGSYS,
    ]

    private static func installHandlers() {
        for signal in fatalSignals {
            install(signal, handler: fatalSignalHandler, restart: true)
        }
        install(SIGTSTP, handler: stopSignalHandler, restart: true)
        install(SIGCONT, handler: continueSignalHandler, restart: true)
        // Deliberately without SA_RESTART: the frame loop's `poll` must come
        // back on a resize so the next frame is drawn at the new size.
        install(SIGWINCH, handler: windowSignalHandler, restart: false)
    }

    private static func install(_ signal: Int32,
                                handler: @escaping @convention(c) (Int32) -> Void,
                                restart: Bool) {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = handler
        sigemptyset(&action.sa_mask)
        action.sa_flags = restart ? Int32(SA_RESTART) : 0
        sigaction(signal, &action, nil)
    }

    /// Run `body` with the handled signals blocked on this thread — the window
    /// where the termios state is half-written is the one a handler must not
    /// land in. (Only this thread: an asynchronous signal can still be
    /// delivered to another one, which is why the handler is written to be
    /// safe on its own.)
    private static func withSignalsBlocked<T>(_ body: () -> T) -> T {
        var mask = sigset_t()
        sigemptyset(&mask)
        for signal in fatalSignals + [SIGTSTP, SIGCONT, SIGWINCH] { sigaddset(&mask, signal) }
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &mask, &previous)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        return body()
    }
}

// Process-wide raw storage, outside the enum: a C signal handler can capture
// nothing, and reading a Swift `var` from one risks a dynamic exclusivity trap
// if the main thread happens to be in its accessor. Pointers are written and
// read directly, which is what makes the handler honest about being
// async-signal-safe.
private let savedTermios = UnsafeMutablePointer<termios>.allocate(capacity: 1)
private let sessionFlag = UnsafeMutablePointer<sig_atomic_t>.allocate(capacity: 1)
private let resumeFlag = UnsafeMutablePointer<sig_atomic_t>.allocate(capacity: 1)
private let resizeFlag = UnsafeMutablePointer<sig_atomic_t>.allocate(capacity: 1)

/// Give the terminal back. `write` and `tcsetattr` are async-signal-safe; the
/// flag is cleared *after* the restore, so a second signal landing mid-restore
/// repeats it instead of skipping it.
private func restoreTerminal() {
    guard sessionFlag.pointee != 0 else { return }
    let restore: StaticString = "\u{1B}[0m\u{1B}[?2004l\u{1B}[?7h\u{1B}[?25h\u{1B}[?1049l"
    restore.withUTF8Buffer { buffer in
        _ = write(STDOUT_FILENO, buffer.baseAddress, buffer.count)
    }
    _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, savedTermios)
    sessionFlag.pointee = 0
}

/// Restore, then die of what actually killed us: re-raising with the default
/// disposition reports a death by signal, where `_exit(128 + signal)` would
/// claim a normal exit with a funny status and suppress the core dump.
private func fatalSignalHandler(_ signal: Int32) {
    restoreTerminal()
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

/// Ctrl-Z / `kill -TSTP`: hand the terminal back cooked, then suspend for
/// real, so the shell prompt behaves and `fg` can bring us back.
private func stopSignalHandler(_ signal: Int32) {
    restoreTerminal()
    Darwin.signal(SIGTSTP, SIG_DFL)
    raise(SIGTSTP)
}

private func continueSignalHandler(_ signal: Int32) {
    resumeFlag.pointee = 1
}

private func windowSignalHandler(_ signal: Int32) {
    resizeFlag.pointee = 1
}
