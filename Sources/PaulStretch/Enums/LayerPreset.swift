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

    /// The layer recipe for each preset, or `nil` for ``off`` (a single
    /// unscaled, unity-gain, unshifted pass).
    ///
    /// Use these as starting points for
    /// ``StretchParameters/customLayers`` — for example, slow a shimmer
    /// voice down by raising the pitched layer's `scale`.
    public var layers: [StretchLayer]? {
        switch self {
        case .off:
            return nil
        case .subtle:
            return [StretchLayer(scale: 0.7, gain: 0.45),
                    StretchLayer(scale: 1.0, gain: 0.75),
                    StretchLayer(scale: 1.4, gain: 0.45)]
        case .standard:
            return [StretchLayer(scale: 0.5, gain: 0.55),
                    StretchLayer(scale: 1.0, gain: 0.70),
                    StretchLayer(scale: 2.0, gain: 0.50)]
        case .lush:
            return [StretchLayer(scale: 0.25, gain: 0.40),
                    StretchLayer(scale: 0.5, gain: 0.55),
                    StretchLayer(scale: 1.0, gain: 0.70),
                    StretchLayer(scale: 2.0, gain: 0.55),
                    StretchLayer(scale: 4.0, gain: 0.40)]
        case .shimmer:
            return [StretchLayer(scale: 0.5, gain: 0.55),
                    StretchLayer(scale: 1.0, gain: 0.70),
                    StretchLayer(scale: 1.0, gain: 0.45, pitchSemitones: 12)]
        case .shimmerDeep:
            return [StretchLayer(scale: 0.5, gain: 0.50, pitchSemitones: -12),
                    StretchLayer(scale: 1.0, gain: 0.70),
                    StretchLayer(scale: 1.0, gain: 0.45, pitchSemitones: 12)]
        }
    }
}
