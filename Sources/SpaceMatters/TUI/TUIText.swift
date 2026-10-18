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
