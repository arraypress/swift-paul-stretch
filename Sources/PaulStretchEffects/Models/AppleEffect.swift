//
//  AppleEffect.swift
//  SwiftPaulStretch
//
//  The complete palette of Apple audio processing units as Codable value
//  types — every effect, every parameter, for arbitrary ordered racks.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

// MARK: - EQ

/// Every band shape `AVAudioUnitEQ` offers.
public enum EQFilterType: String, CaseIterable, Sendable, Codable {
    case parametric, lowPass, highPass, resonantLowPass, resonantHighPass
    case bandPass, bandStop, lowShelf, highShelf, resonantLowShelf, resonantHighShelf

    /// The corresponding `AVAudioUnitEQFilterType`.
    public var avType: AVAudioUnitEQFilterType {
        switch self {
        case .parametric:        return .parametric
        case .lowPass:           return .lowPass
        case .highPass:          return .highPass
        case .resonantLowPass:   return .resonantLowPass
        case .resonantHighPass:  return .resonantHighPass
        case .bandPass:          return .bandPass
        case .bandStop:          return .bandStop
        case .lowShelf:          return .lowShelf
        case .highShelf:         return .highShelf
        case .resonantLowShelf:  return .resonantLowShelf
        case .resonantHighShelf: return .resonantHighShelf
        }
    }
}

/// One band of a fully-configurable ``AppleEffect/eq(_:)``.
public struct EQBandSettings: Sendable, Codable, Equatable {
    /// The band's filter shape.
    public var type: EQFilterType = .parametric
    /// Centre/corner frequency, in hertz (`20…sampleRate/2`).
    public var frequency: Float = 1000
    /// Bandwidth in octaves (`0.05…5`) — parametric/band types.
    public var bandwidth: Float = 1
    /// Gain in decibels (`-96…24`) — parametric/shelf types (resonant types
    /// use it as the resonance peak).
    public var gain: Float = 0
    /// Bypasses just this band.
    public var bypass: Bool = false

    public init(type: EQFilterType = .parametric, frequency: Float = 1000,
                bandwidth: Float = 1, gain: Float = 0, bypass: Bool = false) {
        self.type = type; self.frequency = frequency
        self.bandwidth = bandwidth; self.gain = gain; self.bypass = bypass
    }
}

/// Settings for a fully-configurable multi-band `AVAudioUnitEQ`.
public struct EQSettings: Sendable, Codable, Equatable {
    /// The bands, in order. Any count; each with any ``EQFilterType``.
    public var bands: [EQBandSettings]
    /// Overall gain applied after the bands, in decibels (`-96…24`).
    public var globalGain: Float = 0

    public init(bands: [EQBandSettings], globalGain: Float = 0) {
        self.bands = bands; self.globalGain = globalGain
    }
}

// MARK: - AVFAudio-native units

/// Settings for `AVAudioUnitReverb`.
public struct ReverbSettings: Sendable, Codable, Equatable {
    /// The factory space (all 13 — see ``ReverbPreset``).
    public var preset: ReverbPreset = .mediumHall
    /// Wet/dry mix, `0…100`.
    public var wetDryMix: Float = 40

    public init(preset: ReverbPreset = .mediumHall, wetDryMix: Float = 40) {
        self.preset = preset; self.wetDryMix = wetDryMix
    }
}

/// Settings for `AVAudioUnitDelay`.
public struct DelaySettings: Sendable, Codable, Equatable {
    /// Delay time, in seconds (`0…2`).
    public var delayTime: Float = 0.35
    /// Feedback, `-100…100` (negative inverts).
    public var feedback: Float = 40
    /// Low-pass cutoff in the feedback path, in hertz (`10…22050`).
    public var lowPassCutoff: Float = 15_000
    /// Wet/dry mix, `0…100`.
    public var wetDryMix: Float = 30

    public init(delayTime: Float = 0.35, feedback: Float = 40,
                lowPassCutoff: Float = 15_000, wetDryMix: Float = 30) {
        self.delayTime = delayTime; self.feedback = feedback
        self.lowPassCutoff = lowPassCutoff; self.wetDryMix = wetDryMix
    }
}

/// Settings for `AVAudioUnitDistortion`.
public struct DistortionSettings: Sendable, Codable, Equatable {
    /// The factory character (all 22 — see ``DistortionPreset``).
    public var preset: DistortionPreset = .multiDecimated1
    /// Pre-gain (drive), in decibels (`-80…20`).
    public var preGain: Float = -6
    /// Wet/dry mix, `0…100`.
    public var wetDryMix: Float = 50

    public init(preset: DistortionPreset = .multiDecimated1,
                preGain: Float = -6, wetDryMix: Float = 50) {
        self.preset = preset; self.preGain = preGain; self.wetDryMix = wetDryMix
    }
}

/// Settings for `AVAudioUnitTimePitch` — independent rate and pitch.
/// A time effect: baking at `rate ≠ 1` changes the output duration.
public struct TimePitchSettings: Sendable, Codable, Equatable {
    /// Playback rate (`1/32…32`), duration scales by `1/rate`.
    public var rate: Float = 1
    /// Pitch shift, in cents (`-2400…2400`).
    public var pitchCents: Float = 0
    /// Analysis overlap (`3…32`) — higher is smoother and costlier.
    public var overlap: Float = 8

    public init(rate: Float = 1, pitchCents: Float = 0, overlap: Float = 8) {
        self.rate = rate; self.pitchCents = pitchCents; self.overlap = overlap
    }
}

/// Settings for `AVAudioUnitVarispeed` — coupled rate and pitch, like a
/// tape machine. A time effect: baking at `rate ≠ 1` changes duration.
public struct VarispeedSettings: Sendable, Codable, Equatable {
    /// Playback rate (`0.25…4`), pitch follows.
    public var rate: Float = 1

    public init(rate: Float = 1) { self.rate = rate }
}

// MARK: - AudioToolbox units (no AVFAudio class — wrapped by description)

/// Settings for Apple's dynamics processor
/// (`kAudioUnitSubType_DynamicsProcessor`).
public struct DynamicsProcessorSettings: Sendable, Codable, Equatable {
    /// Compression threshold, in decibels (`-40…20`).
    public var threshold: Float = -20
    /// Headroom, in decibels (`0.1…40`). Lower = harder compression (Apple
    /// derives the ratio from this).
    public var headRoom: Float = 5
    /// Downward expansion ratio (`1…50`); `1` disables expansion.
    public var expansionRatio: Float = 1
    /// Expansion threshold, in decibels.
    public var expansionThreshold: Float = -100
    /// Attack time, in seconds (`0.0001…0.2`).
    public var attackTime: Float = 0.001
    /// Release time, in seconds (`0.01…3`).
    public var releaseTime: Float = 0.05
    /// Overall (make-up) gain, in decibels (`-40…40`).
    public var overallGain: Float = 0

    public init(threshold: Float = -20, headRoom: Float = 5,
                expansionRatio: Float = 1, expansionThreshold: Float = -100,
                attackTime: Float = 0.001, releaseTime: Float = 0.05,
                overallGain: Float = 0) {
        self.threshold = threshold; self.headRoom = headRoom
        self.expansionRatio = expansionRatio; self.expansionThreshold = expansionThreshold
        self.attackTime = attackTime; self.releaseTime = releaseTime
        self.overallGain = overallGain
    }
}

/// Settings for Apple's peak limiter (`kAudioUnitSubType_PeakLimiter`).
public struct PeakLimiterSettings: Sendable, Codable, Equatable {
    /// Attack time, in seconds (`0.001…0.03`).
    public var attackTime: Float = 0.012
    /// Decay time, in seconds (`0.001…0.06`).
    public var decayTime: Float = 0.024
    /// Pre-gain, in decibels (`-40…40`).
    public var preGain: Float = 0

    public init(attackTime: Float = 0.012, decayTime: Float = 0.024, preGain: Float = 0) {
        self.attackTime = attackTime; self.decayTime = decayTime; self.preGain = preGain
    }
}

/// Settings for Apple's graphic EQ (`kAudioUnitSubType_GraphicEQ`) —
/// 10 or 31 ISO bands.
public struct GraphicEQSettings: Sendable, Codable, Equatable {
    /// `true` for 31 bands, `false` for 10.
    public var use31Bands: Bool = false
    /// Per-band gains in decibels (`-20…20`), low to high. Extra entries
    /// are ignored; missing entries stay flat.
    public var bandGains: [Float] = []

    public init(use31Bands: Bool = false, bandGains: [Float] = []) {
        self.use31Bands = use31Bands; self.bandGains = bandGains
    }
}

/// Settings for Apple's 4-band multiband compressor
/// (`kAudioUnitSubType_MultiBandCompressor`).
public struct MultibandCompressorSettings: Sendable, Codable, Equatable {
    /// Gain before compression, in decibels (`-40…40`).
    public var preGain: Float = 0
    /// Gain after compression, in decibels (`-40…40`).
    public var postGain: Float = 0
    /// The three crossover frequencies, in hertz (defaults 120/700/3000).
    public var crossovers: [Float] = [120, 700, 3000]
    /// Per-band thresholds, in decibels (`-100…0`).
    public var thresholds: [Float] = [-22, -32, -33, -36]
    /// Per-band headrooms, in decibels (`0.1…40`, lower = harder).
    public var headrooms: [Float] = [5, 12, 5, 7.5]
    /// Per-band make-up EQ, in decibels (`-20…20`).
    public var eqGains: [Float] = [0, 0, 0, 0]
    /// Attack time, in seconds (`0.001…0.2`).
    public var attackTime: Float = 0.08
    /// Release time, in seconds (`0.01…3`).
    public var releaseTime: Float = 0.12

    public init() {}
}

// MARK: - The rack unit

/// One Apple audio processing unit with its full parameter set — the
/// complete palette, usable in any order via ``EffectRack``.
///
/// ```swift
/// let rack: [AppleEffect] = [
///     .eq(EQSettings(bands: [
///         EQBandSettings(type: .highPass, frequency: 60),
///         EQBandSettings(type: .parametric, frequency: 2400, bandwidth: 0.7, gain: 3),
///     ])),
///     .distortion(DistortionSettings(preset: .multiDecimated2, wetDryMix: 25)),
///     .reverb(ReverbSettings(preset: .largeHall2, wetDryMix: 45)),
///     .dynamics(DynamicsProcessorSettings(threshold: -18, headRoom: 3)),
///     .peakLimiter(PeakLimiterSettings()),
/// ]
/// let mastered = EffectRack.bake(buffer, effects: rack)
/// ```
public enum AppleEffect: Sendable, Codable, Equatable {
    case reverb(ReverbSettings)
    case delay(DelaySettings)
    case distortion(DistortionSettings)
    case eq(EQSettings)
    case timePitch(TimePitchSettings)
    case varispeed(VarispeedSettings)
    case dynamics(DynamicsProcessorSettings)
    case peakLimiter(PeakLimiterSettings)
    case graphicEQ(GraphicEQSettings)
    case multibandCompressor(MultibandCompressorSettings)
}

#endif  // !os(watchOS)
