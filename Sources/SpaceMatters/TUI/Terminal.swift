import Foundation

/// A key the browser understands, decoded from raw terminal bytes.
enum TerminalKey: Equatable {
    case up, down, left, right
    case pageUp, pageDown, home, end
    case enter, backspace, escape
    /// Ctrl-C / Ctrl-D: raw mode turns signal generation off, so they arrive
    /// as bytes and quit like `q` instead of leaving the terminal raw.
    case interrupt
    case char(Character)
}

/// Raw-mode terminal I/O for `--tui` (SPEC-15): termios, the alternate screen,
/// the window size, and the byte → key decoder.
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
    static func enter() -> Bool {
        guard tcgetattr(STDIN_FILENO, &savedTermios) == 0 else { return false }
        var raw = savedTermios
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return false }
        sessionActive = true
        // Being killed or losing the terminal must not leave the shell raw and
        // on the alternate screen.
        signal(SIGTERM, restoreAndExit)
        signal(SIGHUP, restoreAndExit)
        // Alternate screen, cursor hidden, autowrap off — the last is a safety
        // net: a line misjudged one cell too wide is clipped instead of
        // wrapping and shearing every line below it.
        output("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l\u{1B}[2J")
        return true
    }

    /// Undo `enter()`. Idempotent, and async-signal-safe — it is also what the
    /// signal handler runs, so it only calls `write` and `tcsetattr`.
    static func leave() {
        guard sessionActive else { return }
        sessionActive = false
        let restore: StaticString = "\u{1B}[0m\u{1B}[?7h\u{1B}[?25h\u{1B}[?1049l"
        restore.withUTF8Buffer { buffer in
            _ = write(STDOUT_FILENO, buffer.baseAddress, buffer.count)
        }
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTermios)
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
    static func draw(_ frame: [String], over previous: [String]) {
        var out = ""
        for (index, line) in frame.enumerated() where index >= previous.count || previous[index] != line {
            out += "\u{1B}[\(index + 1);1H\u{1B}[0m" + line + "\u{1B}[0m\u{1B}[K"
        }
        if previous.count > frame.count {
            for index in frame.count..<previous.count { out += "\u{1B}[\(index + 1);1H\u{1B}[K" }
        }
        if !out.isEmpty { output(out) }
    }

    static func output(_ text: String) {
        var text = text
        text.withUTF8 { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let n = write(STDOUT_FILENO, base + offset, buffer.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    // MARK: Input

    /// Wait up to `timeout` milliseconds for keys. `[]` on timeout; `nil` once
    /// input is gone (terminal closed) — the caller must stop rather than spin
    /// on a descriptor that is readable forever.
    static func readKeys(timeout: Int32) -> [TerminalKey]? {
        var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&fds, 1, timeout)
        if ready < 0 { return errno == EINTR ? [] : nil }
        guard ready > 0 else { return [] }
        guard fds.revents & Int16(POLLIN) != 0 else { return nil } // POLLHUP / POLLERR / POLLNVAL
        var buffer = [UInt8](repeating: 0, count: 64)
        let capacity = buffer.count
        let n = read(STDIN_FILENO, &buffer, capacity)
        if n < 0 { return errno == EINTR || errno == EAGAIN ? [] : nil }
        guard n > 0 else { return nil }
        return decode(Array(buffer[0..<n]))
    }

    /// Bytes → keys. Pure, so the escape-sequence grammar is testable.
    ///
    /// Arrows arrive as CSI (`ESC [ A`) or SS3 (`ESC O A`) depending on the
    /// terminal's cursor-key mode; modifiers ride as parameters (`ESC [ 1 ; 5 A`
    /// is Ctrl-↑) and are ignored. A sequence cut off by the read is dropped,
    /// never misread as keystrokes.
    static func decode(_ bytes: [UInt8]) -> [TerminalKey] {
        var keys: [TerminalKey] = []
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            switch byte {
            case 0x1B:
                if i + 2 < bytes.count, bytes[i + 1] == 0x5B || bytes[i + 1] == 0x4F {
                    var j = i + 2
                    var params: [UInt8] = []
                    while j < bytes.count, (0x30...0x3F).contains(bytes[j]) {
                        params.append(bytes[j])
                        j += 1
                    }
                    guard j < bytes.count else { return keys }
                    if let key = sequenceKey(final: bytes[j], params: params) { keys.append(key) }
                    i = j + 1
                    continue
                }
                keys.append(.escape)
            case 0x0D, 0x0A:
                keys.append(.enter)
            case 0x7F, 0x08:
                keys.append(.backspace)
            case 0x03, 0x04:
                keys.append(.interrupt)
            case 0x20...0x7E:
                keys.append(.char(Character(Unicode.Scalar(byte))))
            default:
                break // other control bytes and non-ASCII: no binding uses them
            }
            i += 1
        }
        return keys
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
            case "4", "8": return .end
            case "5": return .pageUp
            case "6": return .pageDown
            default: return nil
            }
        default:
            return nil
        }
    }
}

// Process-wide, outside the enum, because a C signal handler can capture
// nothing: the terminal state to restore has to live at a fixed address.
private var savedTermios = termios()
private var sessionActive = false

private func restoreAndExit(_ signal: Int32) {
    Terminal.leave()
    _exit(128 + signal)
}
