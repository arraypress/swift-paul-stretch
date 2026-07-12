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

    // MARK: Shimmer reverb

    /// Whether the shimmer reverb is active.
    ///
    /// Shimmer is the library's own DSP (see ``ShimmerReverb``): a reverb
    /// tank whose output is pitch-shifted and fed back into itself, so the
    /// wash climbs in ethereal octaves. Because `AVAudioEngine` graphs
    /// cannot contain feedback cycles, shimmer exists only in the *baked*
    /// path (``EffectsBaker``/``StreamingEffectsBaker``) — a live
    /// ``EffectChain`` ignores it; hosts re-bake to audition it.
    public var shimmerEnabled = false

    /// Shimmer wet/dry mix, `0…100`.
    public var shimmerMix: Float = 30

    /// The feedback pitch shift, in semitones. `+12` is the classic
    /// octave-up shimmer; `+7` gives fifths, negative values darken.
    public var shimmerPitch: Float = 12

    /// How much pitched wash feeds back into the tank, `0…100`. Higher
    /// values bloom longer and climb further.
    public var shimmerFeedback: Float = 45

    /// The reverb tank size, `0…100` (larger = longer, slower bloom).
    public var shimmerSize: Float = 80

    /// High-frequency damping inside the tank, `0…100`.
    public var shimmerDamping: Float = 40

    /// The climb rate of the shimmer, in seconds per octave step (`0…8`).
    ///
    /// A pre-delay in the pitched feedback path: each pass through the loop
    /// waits this long before re-entering the tank, so the bloom steps up
    /// audibly — `0` (the default) is the classic dense instant halo,
    /// `1`–`3` s turns it into a slow, deliberate ascent.
    public var shimmerClimbSeconds: Float = 0

    /// `true` when at least one effect is enabled — baking with everything
    /// off is a no-op and returns the dry audio untouched.
    public var isAnyEnabled: Bool {
        reverbEnabled || eqEnabled || filterEnabled || delayEnabled || shimmerEnabled
    }

    /// Creates the all-off default settings.
    public init() {}

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case reverbEnabled, reverbPreset, reverbMix
        case eqEnabled, eqLowGain, eqMidGain, eqHighGain
        case filterEnabled, filterCutoff, filterResonance
        case delayEnabled, delayTime, delayFeedback, delayMix
        case shimmerEnabled, shimmerMix, shimmerPitch, shimmerFeedback,
             shimmerSize, shimmerDamping, shimmerClimbSeconds
    }

    /// Tolerant decoding: any field missing from the JSON (a preset saved
    /// by an older library version) keeps its default, so stored presets
    /// survive library upgrades.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reverbEnabled = try c.decodeIfPresent(Bool.self, forKey: .reverbEnabled) ?? reverbEnabled
        reverbPreset = try c.decodeIfPresent(ReverbPreset.self, forKey: .reverbPreset) ?? reverbPreset
        reverbMix = try c.decodeIfPresent(Float.self, forKey: .reverbMix) ?? reverbMix
        eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? eqEnabled
        eqLowGain = try c.decodeIfPresent(Float.self, forKey: .eqLowGain) ?? eqLowGain
        eqMidGain = try c.decodeIfPresent(Float.self, forKey: .eqMidGain) ?? eqMidGain
        eqHighGain = try c.decodeIfPresent(Float.self, forKey: .eqHighGain) ?? eqHighGain
        filterEnabled = try c.decodeIfPresent(Bool.self, forKey: .filterEnabled) ?? filterEnabled
        filterCutoff = try c.decodeIfPresent(Float.self, forKey: .filterCutoff) ?? filterCutoff
        filterResonance = try c.decodeIfPresent(Float.self, forKey: .filterResonance) ?? filterResonance
        delayEnabled = try c.decodeIfPresent(Bool.self, forKey: .delayEnabled) ?? delayEnabled
        delayTime = try c.decodeIfPresent(Float.self, forKey: .delayTime) ?? delayTime
        delayFeedback = try c.decodeIfPresent(Float.self, forKey: .delayFeedback) ?? delayFeedback
        delayMix = try c.decodeIfPresent(Float.self, forKey: .delayMix) ?? delayMix
        shimmerEnabled = try c.decodeIfPresent(Bool.self, forKey: .shimmerEnabled) ?? shimmerEnabled
        shimmerMix = try c.decodeIfPresent(Float.self, forKey: .shimmerMix) ?? shimmerMix
        shimmerPitch = try c.decodeIfPresent(Float.self, forKey: .shimmerPitch) ?? shimmerPitch
        shimmerFeedback = try c.decodeIfPresent(Float.self, forKey: .shimmerFeedback) ?? shimmerFeedback
        shimmerSize = try c.decodeIfPresent(Float.self, forKey: .shimmerSize) ?? shimmerSize
        shimmerDamping = try c.decodeIfPresent(Float.self, forKey: .shimmerDamping) ?? shimmerDamping
        shimmerClimbSeconds = try c.decodeIfPresent(Float.self, forKey: .shimmerClimbSeconds) ?? shimmerClimbSeconds
    }
}

#endif  // !os(watchOS)
