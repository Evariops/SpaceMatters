import Foundation

enum Format {
    /// Human-readable byte size, base 1024 (KiB/MiB/… shown as KB/MB for brevity).
    static func bytes(_ value: Int64) -> String {
        let v = Double(value)
        if value < 1024 { return "\(value) B" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var size = v / 1024
        var unit = 0
        while size >= 1024 && unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        if size >= 100 { return String(format: "%.0f %@", size, units[unit]) }
        if size >= 10 { return String(format: "%.1f %@", size, units[unit]) }
        return String(format: "%.2f %@", size, units[unit])
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
