//
//  LayerPreset.swift
//  SwiftPaulStretch
//
//  Multi-pass layering presets for the PaulStretch mode.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// How many differently-scaled stretch passes are mixed into the final
/// render in ``StretchMode/paulStretch`` mode.
///
/// Each layer stretches the same source by a different multiple of the
/// target duration and is mixed in at a fixed gain, thickening the wash the
/// way detuned oscillators thicken a pad. More layers cost proportionally
/// more render time.
public enum LayerPreset: String, CaseIterable, Sendable, Codable {

    /// A single stretch pass — the purest PaulStretch sound, and the fastest.
    case off

    /// Three passes at 0.7× / 1.0× / 1.4× of the target duration.
    case subtle

    /// Three passes at 0.5× / 1.0× / 2.0× of the target duration.
    case standard

    /// Five passes at 0.25× / 0.5× / 1.0× / 2.0× / 4.0× of the target
    /// duration — the densest, slowest-moving wash.
    case lush

    /// Three passes with an octave-up voice mixed in — the Eno-style
    /// "shimmer" drone. Layer pitch offsets stack on top of
    /// ``StretchParameters/pitchSemitones``.
    case shimmer

    /// ``shimmer`` with the slow layer dropped an octave as well — a wider,
    /// darker shimmer with a sub foundation.
    case shimmerDeep
}

extension LayerPreset {

    /// The (duration scale, mix gain, pitch offset in semitones) recipe for
    /// each preset, or `nil` for ``off`` (a single unscaled, unity-gain,
    /// unshifted pass).
    var layers: [(scale: Double, gain: Float, pitch: Double)]? {
        switch self {
        case .off:         return nil
        case .subtle:      return [(0.7, 0.45, 0), (1.0, 0.75, 0), (1.4, 0.45, 0)]
        case .standard:    return [(0.5, 0.55, 0), (1.0, 0.70, 0), (2.0, 0.50, 0)]
        case .lush:        return [(0.25, 0.40, 0), (0.5, 0.55, 0), (1.0, 0.70, 0), (2.0, 0.55, 0), (4.0, 0.40, 0)]
        case .shimmer:     return [(0.5, 0.55, 0), (1.0, 0.70, 0), (1.0, 0.45, 12)]
        case .shimmerDeep: return [(0.5, 0.50, -12), (1.0, 0.70, 0), (1.0, 0.45, 12)]
        }
    }
}
