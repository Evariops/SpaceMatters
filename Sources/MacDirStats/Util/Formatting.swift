import Foundation

enum Format {
    /// Localized decimal separator (thread-safe snapshot; formatting can run on
    /// the main actor or the headless CLI thread).
    private static let decimalSeparator = Locale.current.decimalSeparator ?? "."

    /// Human-readable byte size. **Base 1024 with honest IEC labels** (KiB/MiB/…),
    /// matching `du`/"On disk"; the separator is localized (A10, J9.5). Base-10 to
    /// match Finder exactly is a possible future toggle (see SPEC-03 §3.d).
    static func bytes(_ value: Int64) -> String {
        if value < 1024 { return "\(value) B" }
        let units = ["KiB", "MiB", "GiB", "TiB", "PiB"]
        var size = Double(value) / 1024
        var unit = 0
        while size >= 1024 && unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        let mantissa: String
        if size >= 100 { mantissa = String(format: "%.0f", size) }
        else if size >= 10 { mantissa = String(format: "%.1f", size) }
        else { mantissa = String(format: "%.2f", size) }
        let localized = decimalSeparator == "." ? mantissa : mantissa.replacingOccurrences(of: ".", with: decimalSeparator)
        return "\(localized) \(units[unit])"
    }

    /// Compact integer with thousands separators.
    static func count(_ value: Int64) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func rate(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "%.1fk/s", value / 1000)
        }
        return String(format: "%.0f/s", value)
    }

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
}
