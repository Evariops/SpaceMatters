import Foundation

/// Fitting text into terminal cells. A `Character` count is not a width: CJK
/// and emoji take two cells, combining marks none — and a name drawn one cell
/// too wide wraps and shears every line below it.
enum TextCell {

    /// File names are untrusted bytes: one carrying an escape sequence would
    /// otherwise *drive* the terminal it is printed on. Control and format
    /// characters are dropped, as the digest does.
    static func sanitize(_ text: String) -> String {
        let clean = String(String.UnicodeScalarView(
            text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        return clean.isEmpty ? "?" : clean
    }

    static func width(_ text: String) -> Int {
        text.reduce(0) { $0 + width(of: $1) }
    }

    /// Cells a rendered line occupies, ignoring the SGR sequences in it. What
    /// the terminal will actually fill — which is what decides whether an
    /// `ESC[K` after it would erase the last column rather than clear it.
    static func displayWidth(_ line: String) -> Int {
        enum State { case text, escape, sequence }
        var state = State.text
        var total = 0
        for character in line {
            switch state {
            case .text:
                if character == "\u{1B}" { state = .escape } else { total += width(of: character) }
            case .escape:
                // `ESC [` (CSI) and `ESC O` (SS3) introduce a sequence; the
                // introducer itself is in the @–~ range that *ends* one, so it
                // has to be stepped over before looking for the terminator.
                state = (character == "[" || character == "O") ? .sequence : .text
            case .sequence:
                if let scalar = character.unicodeScalars.first, (0x40...0x7E).contains(scalar.value) {
                    state = .text
                }
            }
        }
        return total
    }

    static func width(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        switch first.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format, .control: return 0
        default: break
        }
        if first.properties.isEmojiPresentation || scalars.contains("\u{FE0F}") { return 2 }
        return isWide(first.value) ? 2 : 1
    }

    /// East Asian Wide and Fullwidth blocks — the ranges that matter for file
    /// names, not the full UAX #11 table.
    private static func isWide(_ v: UInt32) -> Bool {
        (0x1100...0x115F).contains(v) || (0x2E80...0x303E).contains(v)
            || (0x3041...0x33FF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x4E00...0x9FFF).contains(v) || (0xA000...0xA4CF).contains(v)
            || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x20000...0x3FFFD).contains(v)
    }

    /// At most `width` cells, cut at the end with "…".
    static func fit(_ text: String, _ width: Int) -> String {
        guard width > 0 else { return "" }
        guard self.width(text) > width else { return text }
        var out = ""
        var used = 0
        for character in text {
            let w = self.width(of: character)
            if used + w > width - 1 { break }
            out.append(character)
            used += w
        }
        return out + "…"
    }

    /// At most `width` cells, cut at the start with "…" — for paths.
    static func fitLeading(_ text: String, _ width: Int) -> String {
        guard width > 0 else { return "" }
        guard self.width(text) > width else { return text }
        var out = ""
        var used = 0
        for character in text.reversed() {
            let w = self.width(of: character)
            if used + w > width - 1 { break }
            out.insert(character, at: out.startIndex)
            used += w
        }
        return "…" + out
    }

    static func padLeft(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - self.width(text))) + text
    }

    static func padRight(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - self.width(text)))
    }

    /// Centred in `width` cells, padded on both sides.
    static func center(_ text: String, _ width: Int) -> String {
        let fitted = fit(text, width)
        let left = max(0, (width - self.width(fitted)) / 2)
        return padRight(String(repeating: " ", count: left) + fitted, width)
    }

    /// A proportion as a bar of `width` cells, in eighths of a cell.
    static func bar(_ fraction: Double, width: Int) -> String {
        guard width > 0 else { return "" }
        let eighths = Int((min(max(fraction, 0), 1) * Double(width * 8)).rounded())
        let full = eighths / 8
        let partial = eighths % 8
        var s = String(repeating: "█", count: full)
        if partial > 0 { s.append(["▏", "▎", "▍", "▌", "▋", "▊", "▉"][partial - 1]) }
        return padRight(s, width)
    }

    /// Wrap at cell width, breaking on spaces where it can — modal bodies are
    /// prose, and a sentence clipped at the box edge loses the warning in it.
    static func wrap(_ text: String, _ width: Int) -> [String] {
        guard width > 0 else { return [] }
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                let candidate = line.isEmpty ? String(word) : line + " " + word
                if self.width(candidate) <= width {
                    line = candidate
                } else {
                    if !line.isEmpty { lines.append(line) }
                    line = self.width(String(word)) > width ? fit(String(word), width) : String(word)
                }
            }
            lines.append(line)
        }
        return lines
    }

    /// A path, wrapped without losing a character: broken after a `/` where
    /// that fits, mid-name where nothing does. `wrap` cuts an over-long word
    /// with an ellipsis, which is right for prose and wrong here — in a
    /// deletion prompt the whole path is the point of showing it.
    static func wrapPath(_ path: String, _ width: Int) -> [String] {
        guard width > 0 else { return [] }
        var segments: [String] = []
        var segment = ""
        for character in path {
            segment.append(character)
            if character == "/" { segments.append(segment); segment = "" }
        }
        if !segment.isEmpty { segments.append(segment) }

        var lines: [String] = []
        var line = ""
        for segment in segments {
            if self.width(line + segment) <= width {
                line += segment
                continue
            }
            if !line.isEmpty { lines.append(line) }
            line = ""
            for character in segment {
                if !line.isEmpty, self.width(line + String(character)) > width {
                    lines.append(line)
                    line = ""
                }
                line.append(character)
            }
        }
        if !line.isEmpty || lines.isEmpty { lines.append(line) }
        return lines
    }
}

/// The SGR sequences the terminal UI draws with. Colour is used for meaning
/// only — danger, a selected row, a heading — so a monochrome or
/// oddly-themed terminal loses decoration, never information: every coloured
/// thing also says what it is in words.
enum Style {
    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func reverse(_ s: String) -> String { wrap(s, "7") }
    static func red(_ s: String) -> String { wrap(s, "31") }
    static func green(_ s: String) -> String { wrap(s, "32") }
    static func yellow(_ s: String) -> String { wrap(s, "33") }
    static func blue(_ s: String) -> String { wrap(s, "34") }
    static func cyan(_ s: String) -> String { wrap(s, "36") }
    static func boldRed(_ s: String) -> String { wrap(s, "1;31") }

    private static func wrap(_ s: String, _ code: String) -> String {
        s.isEmpty ? s : "\u{1B}[\(code)m" + s + "\u{1B}[0m"
    }

    /// Spinner frame for a running job, from a monotonically rising tick.
    static func spinner(_ tick: Int) -> String {
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        return frames[((tick % frames.count) + frames.count) % frames.count]
    }
}

/// The non-ASCII characters the interface draws with, and the one-cell ASCII
/// stand-in for each.
///
/// Box drawing, the bar's eighths, `…`, `·`, `—` and the arrows are East Asian
/// *Ambiguous*: a terminal configured to draw ambiguous characters wide (the
/// common CJK setup) gives them two cells, and every line of the interface
/// overflows. `SPACEMATTERS_TUI_ASCII=1` swaps them for ASCII.
///
/// Every substitution is one cell wide, so a frame measured before the swap
/// still fits after it — the widths the renderer computed stay true.
enum Glyphs {

    static let ascii = ProcessInfo.processInfo.environment["SPACEMATTERS_TUI_ASCII"] == "1"

    private static let table: [Character: Character] = [
        "…": "~", "·": "|", "—": "-", "–": "-",
        "↑": "^", "↓": "v", "→": ">", "←": "<", "↳": ">",
        "⏎": "*", "⌫": "<", "▸": ">", "⚠": "!", "✦": "*",
        "█": "#", "▏": "=", "▎": "=", "▍": "=", "▌": "=", "▋": "=", "▊": "=", "▉": "=",
        "┌": "+", "┐": "+", "└": "+", "┘": "+", "─": "-", "│": "|",
        "⠋": "-", "⠙": "\\", "⠹": "|", "⠸": "/", "⠼": "-",
        "⠴": "\\", "⠦": "|", "⠧": "/", "⠇": "-", "⠏": "\\",
    ]

    /// Applied to a finished frame line, so no screen has to know about it.
    static func asciify(_ line: String) -> String {
        guard ascii else { return line }
        // Only the chrome is swapped: a CJK or accented *name* is the user's
        // data, and its width (Wide, not Ambiguous) is measured correctly.
        return String(line.map { table[$0] ?? $0 })
    }
}
