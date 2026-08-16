import Foundation
import simd

/// What an assistant concluded about a folder — SPEC-14 §3.5.
///
/// The scanner measures, the model classifies, and the map is where the two meet:
/// a verdict tints the treemap and the sunburst so the conclusion lands where the
/// user already is, instead of only in a transcript they have to read next to it.
enum Verdict: String, CaseIterable, Sendable {
    /// Regenerable, cold, or otherwise disposable.
    case safe
    /// Large and worth a decision, but not obviously disposable.
    case review
    /// Explicitly not to be touched.
    case keep

    var label: String {
        switch self {
        case .safe: return "Safe to delete"
        case .review: return "Worth reviewing"
        case .keep: return "Keep"
        }
    }

    /// sRGB the map paints a verdict in. Defined here rather than in either
    /// renderer so the treemap, the sunburst and the outline cannot drift apart
    /// on what "safe" looks like.
    ///
    /// `review` is a deliberately saturated orange rather than the amber first
    /// tried: this app's default palette is full of golds, and an amber verdict
    /// was indistinguishable from an unmarked tile.
    var tint: SIMD3<Float> {
        switch self {
        case .safe: return SIMD3(0.24, 0.76, 0.42)
        case .review: return SIMD3(0.98, 0.53, 0.11)
        // Slate, not blue: the outline draws every unmarked folder in the
        // accent, which is blue, so a blue "keep" was indistinguishable from no
        // verdict at all. Desaturated also reads as "inert, leave it", which is
        // exactly what the verdict means.
        case .keep: return SIMD3(0.55, 0.60, 0.68)
        }
    }

    /// Apply a verdict to a tile's palette colour.
    ///
    /// Blending toward the tint was wrong: at any strength below 1 the type hue
    /// keeps contributing, so the *same verdict rendered a different colour
    /// depending on the file type underneath it* — `review` orange over a green
    /// subtree came out olive, and read as neither. A verdict has to look the
    /// same everywhere or it means nothing.
    ///
    /// So the hue is replaced outright and only the **brightness** of the
    /// original survives, which is what carried relative size — the map keeps
    /// its depth, the verdict keeps its identity.
    func applied(to color: SIMD4<Float>) -> SIMD4<Float> {
        let luma = 0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z
        let scale = 0.62 + 0.38 * min(1, max(0, luma))
        return SIMD4<Float>(tint.x * scale, tint.y * scale, tint.z * scale, color.w)
    }
}

struct VerdictNote: Sendable, Equatable {
    let verdict: Verdict
    /// One line, in the model's words — shown on hover so a colour is never the
    /// whole argument for deleting something.
    let reason: String
}
