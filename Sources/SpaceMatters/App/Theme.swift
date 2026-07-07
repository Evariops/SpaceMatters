import SwiftUI

/// A hand-built dark palette (with a light variant) so the look is intentional
/// rather than inherited from system materials.
struct Theme {
    var isDark: Bool

    var windowBackground: Color { isDark ? Color(hex: 0x0E1116) : Color(hex: 0xF6F7F9) }
    var panelBackground: Color  { isDark ? Color(hex: 0x161A21) : Color(hex: 0xFFFFFF) }
    var rowHover: Color         { isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04) }
    var rowSelected: Color      { accent.opacity(isDark ? 0.28 : 0.18) }
    var separator: Color        { isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.10) }
    var textPrimary: Color      { isDark ? Color(hex: 0xE8ECF2) : Color(hex: 0x1B1F24) }
    var textSecondary: Color    { isDark ? Color(hex: 0x9AA4B2) : Color(hex: 0x5B6470) }
    var accent: Color           { Color(hex: 0x4C8DFF) }
    var barTrack: Color         { isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.06) }
    var treemapBackground: Color { isDark ? Color(hex: 0x0A0C10) : Color(hex: 0xEAECEF) }
    var treemapBorder: Color    { isDark ? Color.black.opacity(0.45) : Color.white.opacity(0.55) }

    /// A warm-leaning, varied categorical palette (hues, in degrees). Tiles are
    /// coloured per-folder, so a region shows many hues rather than one — warmer
    /// and livelier than a single-family wash.
    static let paletteHues: [Double] = [
        6,   // red
        16,  // coral
        26,  // orange
        36,  // amber
        45,  // gold
        130, // green
        95,  // olive
        160, // teal-green
        190, // cyan
        205, // sky
        225, // blue
        255, // indigo
        282, // violet
        308, // purple
        330, // magenta
        348, // pink
    ]

    /// Stable, vivid color for a string (list bars, type swatches).
    func color(forHashable string: String, brightnessBoost: Double = 0) -> Color {
        let hue = Theme.paletteHues[Theme.stableIndex(string, Theme.paletteHues.count)]
        let sat = isDark ? 0.74 : 0.80
        let bri = min(0.98, (isDark ? 0.84 : 0.74) + brightnessBoost)
        return Color(hue: hue / 360, saturation: sat, brightness: bri)
    }

    /// Treemap tile color, keyed by the folder's **dominant file type** so the map
    /// reads with meaning and matches the File-types legend exactly (same hue per
    /// extension). `weight` (size relative to the biggest tile, 0…1) modulates
    /// brightness so heavy items glow and light ones sit back, while staying vivid.
    func treemapTypeColor(extName: String, weight: Double) -> Color {
        treemapTypeColor(hueIndex: Theme.stableIndex(extName, Theme.paletteHues.count), weight: weight)
    }

    /// Same as `treemapTypeColor(extName:weight:)` but keyed on the already-resolved
    /// palette index — lets the treemap memoise colours by `(hueIndex, weight)`
    /// without re-hashing an extension string on the resize hot path.
    func treemapTypeColor(hueIndex: Int, weight: Double) -> Color {
        let hue = Theme.paletteHues[hueIndex]
        let w = max(0, min(1, weight))
        let sat = isDark ? 0.74 : 0.80
        var bri = (isDark ? 0.60 : 0.56) + 0.30 * w
        if !isDark { bri *= 0.95 }
        bri = max(0.40, min(0.94, bri))
        return Color(hue: hue / 360, saturation: sat, brightness: bri)
    }

    /// Unified capacity-gauge colour (F6): the same green/orange/red thresholds
    /// everywhere (volumes and Kubernetes were 70/90 vs 70/85 before).
    static func usageColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: return Color(hex: 0x3FB950)   // green
        case ..<0.9: return Color(hex: 0xD29922)   // amber
        default:     return Color(hex: 0xF85149)   // red
        }
    }

    /// A words-not-only-colour severity label for the same thresholds, so the
    /// gauge is legible without relying on hue (J10.2, colour-blindness).
    static func usageLevel(_ fraction: Double) -> String {
        switch fraction {
        case ..<0.7: return "OK"
        case ..<0.9: return "High"
        default:     return "Critical"
        }
    }

    // Deterministic (FNV-1a) so colors are stable across launches, unlike the
    // per-process-seeded standard Hasher.
    private static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }
    static func stableIndex(_ s: String, _ count: Int) -> Int {
        Int(fnv(s) % UInt64(count))
    }
    static func stableUnit(_ s: String) -> Double {
        Double((fnv(s) >> 13) % 1000) / 1000.0
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(isDark: true)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
