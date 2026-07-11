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
}

extension LayerPreset {

    /// The (duration scale, mix gain) recipe for each preset, or `nil` for
    /// ``off`` (a single unscaled, unity-gain pass).
    var layers: [(scale: Double, gain: Float)]? {
        switch self {
        case .off:      return nil
        case .subtle:   return [(0.7, 0.45), (1.0, 0.75), (1.4, 0.45)]
        case .standard: return [(0.5, 0.55), (1.0, 0.70), (2.0, 0.50)]
        case .lush:     return [(0.25, 0.40), (0.5, 0.55), (1.0, 0.70), (2.0, 0.55), (4.0, 0.40)]
        }
    }
}
