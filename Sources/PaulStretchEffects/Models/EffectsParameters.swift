//
//  EffectsParameters.swift
//  SwiftPaulStretch
//
//  The effect-chain settings: Filter → EQ → Delay → Reverb.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// Settings for the stock effect chain (Filter → EQ → Delay → Reverb).
///
/// One `EffectsParameters` value drives both halves of the
/// what-you-hear-is-what-you-export pattern: apply it to a live
/// ``EffectChain`` on a playback graph *and* pass it to
/// ``EffectsBaker/bake(_:effects:)`` (or ``StreamingEffectsBaker``) when
/// exporting, and the rendered file matches the monitored audio.
///
/// The struct is `Codable` so host apps can persist it inside their presets.
/// All effects default to off.
public struct EffectsParameters: Sendable, Equatable, Codable {

    // MARK: Reverb

    /// Whether the reverb is active.
    public var reverbEnabled = false

    /// The reverb space. Defaults to ``ReverbPreset/cathedral``, the classic
    /// PaulStretch pairing.
    public var reverbPreset: ReverbPreset = .cathedral

    /// Reverb wet/dry mix, `0…100`.
    public var reverbMix: Float = 35

    // MARK: 3-band EQ

    /// Whether the EQ is active.
    public var eqEnabled = false

    /// Low-shelf gain at 120 Hz, in decibels.
    public var eqLowGain: Float = 0

    /// Parametric-band gain at 1 kHz, in decibels.
    public var eqMidGain: Float = 0

    /// High-shelf gain at 6 kHz, in decibels.
    public var eqHighGain: Float = 0

    // MARK: Resonant low-pass filter

    /// Whether the filter is active.
    public var filterEnabled = false

    /// Filter cutoff frequency, in hertz (clamped to `20…20000`).
    public var filterCutoff: Float = 8000

    /// Resonance peak at the cutoff, in decibels (`0…24`). At `0` the filter
    /// runs non-resonant.
    public var filterResonance: Float = 0

    // MARK: Delay

    /// Whether the delay is active.
    public var delayEnabled = false

    /// Delay time, in seconds.
    public var delayTime: Float = 0.35

    /// Delay feedback, `-100…100` (negative values invert).
    public var delayFeedback: Float = 35

    /// Delay wet/dry mix, `0…100`.
    public var delayMix: Float = 25

    /// `true` when at least one effect is enabled — baking with everything
    /// off is a no-op and returns the dry audio untouched.
    public var isAnyEnabled: Bool { reverbEnabled || eqEnabled || filterEnabled || delayEnabled }

    /// Creates the all-off default settings.
    public init() {}
}

#endif  // !os(watchOS)
