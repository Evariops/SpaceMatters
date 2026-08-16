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

    /// sRGB the map blends a tile toward. Defined here rather than in either
    /// renderer so the treemap and the sunburst cannot drift apart on what
    /// "safe" looks like.
    var tint: SIMD3<Float> {
        switch self {
        case .safe: return SIMD3(0.29, 0.78, 0.44)
        case .review: return SIMD3(0.96, 0.71, 0.24)
        case .keep: return SIMD3(0.42, 0.56, 0.92)
        }
    }

    /// Enough to read a verdict across the map at a glance, not so much that the
    /// type hue underneath it disappears — the colour still has its first job.
    static let tintStrength: Float = 0.6
}

struct VerdictNote: Sendable, Equatable {
    let verdict: Verdict
    /// One line, in the model's words — shown on hover so a colour is never the
    /// whole argument for deleting something.
    let reason: String
}
