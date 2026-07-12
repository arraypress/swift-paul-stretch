//
//  EffectDevice.swift
//  SwiftPaulStretch
//
//  One effect in an EffectStack — a single device with its own settings and
//  bypass, freely orderable and duplicable like a channel-strip insert.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

// MARK: - Per-device settings

/// Settings for a shimmer-reverb device (octave-climbing pitched feedback).
public struct ShimmerSettings: Sendable, Codable, Equatable {
    /// Wet blend, `0…100`.
    public var mix: Float = 30
    /// The interval the tail climbs per pass, in semitones (`+12` = octave).
    public var pitchSemitones: Float = 12
    /// Pitched-tail feedback, `0…95`.
    public var feedback: Float = 45
    /// The shimmer's own room size, `0…100`.
    public var size: Float = 80
    /// High rolloff on the tail, `0…100`.
    public var damping: Float = 40
    /// Pre-delay before each climb step blooms, in seconds (`0` = classic).
    public var climbSeconds: Float = 0
    /// Creates default shimmer settings.
    public init() {}
}

/// Settings for a convolution-reverb device (generated or custom impulse).
public struct ConvolutionReverbSettings: Sendable, Codable, Equatable {
    /// The generated impulse character (ignored when a custom IR is set).
    public var profile: ReverbProfile = .hall
    /// The generated impulse decay, in seconds (`0.5…30`).
    public var decaySeconds: Float = 6
    /// Wet blend, `0…100`.
    public var mix: Float = 35
    /// Encoded audio bytes of a custom impulse response (replaces `profile`).
    public var customIRData: Data? = nil
    /// Display name of the custom impulse.
    public var customIRName: String? = nil
    /// Optional wet-blend automation over the processed audio's length.
    public var mixLane: AutomationLane? = nil
    /// Creates default convolution settings.
    public init() {}
}

/// Settings for a sweep-filter device (TPT state-variable filter + LFO).
public struct SweepFilterSettings: Sendable, Codable, Equatable {
    /// The filter shape.
    public var shape: FilterShape = .lowPass
    /// Centre frequency, in hertz.
    public var cutoff: Float = 1200
    /// Resonance at the cutoff, `0.5…12`.
    public var resonance: Float = 2
    /// Companion high-pass frequency, in hertz (`0` = off).
    public var bassCut: Float = 0
    /// One full LFO breath, in seconds.
    public var lfoPeriodSeconds: Float = 20
    /// LFO sweep depth, in octaves (`0` = still).
    public var lfoDepthOctaves: Float = 0
    /// Optional cutoff automation (log-mapped 40 Hz…18 kHz).
    public var cutoffLane: AutomationLane? = nil
    /// Optional resonance automation (mapped Q 0.5…12).
    public var resonanceLane: AutomationLane? = nil
    /// Creates default sweep-filter settings.
    public init() {}
}

/// Settings for a wow/flutter device (tape transport wobble).
public struct WowFlutterSettings: Sendable, Codable, Equatable {
    /// Wobble intensity, `0…1` (±0.5 % pitch at full).
    public var amount: Float = 0.5
    /// Wow rate, in hertz (flutter rides at 10×).
    public var rateHz: Float = 0.6
    /// Optional amount automation.
    public var amountLane: AutomationLane? = nil
    /// Optional rate automation.
    public var rateLane: AutomationLane? = nil
    /// Creates default wow settings.
    public init() {}
}

/// Settings for a breathing-pump device (slow tidal gain swell).
public struct BreathingPumpSettings: Sendable, Codable, Equatable {
    /// Swell depth, `0…1` (±25 % gain at full).
    public var depth: Float = 0.5
    /// Breath rate, in hertz (tidal at the bottom).
    public var rateHz: Float = 0.05
    /// Optional depth automation.
    public var depthLane: AutomationLane? = nil
    /// Optional rate automation.
    public var rateLane: AutomationLane? = nil
    /// Creates default pump settings.
    public init() {}
}

/// Settings for an auto-pan device (slow stereo drift).
public struct AutoPanSettings: Sendable, Codable, Equatable {
    /// Swing width, `0…1`.
    public var depth: Float = 0.6
    /// Crossing rate, in hertz.
    public var rateHz: Float = 0.03
    /// Optional depth automation.
    public var depthLane: AutomationLane? = nil
    /// Optional rate automation.
    public var rateLane: AutomationLane? = nil
    /// Creates default auto-pan settings.
    public init() {}
}

// MARK: - Device

/// One insert in an ``EffectStack``: a single effect with its own settings
/// and bypass toggle.
///
/// Devices stack channel-strip style — any order, any count, duplicates
/// welcome (two sweep filters cascade into a steeper slope; shimmer → space
/// → shimmer blooms the bloom). The library's pure-DSP effects and the
/// whole Apple palette (via ``AppleEffect``) share the one stack.
public struct EffectDevice: Sendable, Codable, Equatable, Identifiable {

    /// The available device kinds.
    public enum Kind: Sendable, Codable, Equatable {
        /// Shimmer reverb (pure DSP, baked path).
        case shimmer(ShimmerSettings)
        /// Convolution reverb (pure DSP, baked path).
        case convolutionReverb(ConvolutionReverbSettings)
        /// Sweep filter (pure DSP, baked path).
        case sweepFilter(SweepFilterSettings)
        /// Tape wow/flutter (pure DSP, baked path).
        case wowFlutter(WowFlutterSettings)
        /// Breathing pump (pure DSP, baked path).
        case breathingPump(BreathingPumpSettings)
        /// Auto-pan (pure DSP, baked path).
        case autoPan(AutoPanSettings)
        /// Any Apple `AVAudioUnit` effect (can also run live on a graph).
        case apple(AppleEffect)
    }

    /// Stable identity (for reordering UI and Codable round trips).
    public var id: UUID

    /// `false` bypasses the device without removing it from the stack.
    public var isEnabled: Bool

    /// Which effect this device is, with its settings.
    public var kind: Kind

    /// Creates a device.
    ///
    /// - Parameters:
    ///   - kind: The effect and its settings.
    ///   - isEnabled: Whether the device processes audio. Defaults to `true`.
    ///   - id: A stable identity. Defaults to a fresh `UUID`.
    public init(_ kind: Kind, isEnabled: Bool = true, id: UUID = UUID()) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.id = id
    }

    /// `true` for devices that must be baked (the library's own pure-DSP
    /// effects); `false` for Apple units that can also run live on a graph.
    public var isPureDSP: Bool {
        if case .apple = kind { return false }
        return true
    }

    /// A short human-readable name for stack UIs.
    public var displayName: String {
        switch kind {
        case .shimmer: return "Shimmer"
        case .convolutionReverb: return "Space"
        case .sweepFilter: return "Sweep Filter"
        case .wowFlutter: return "Wow"
        case .breathingPump: return "Breathe"
        case .autoPan: return "Drift"
        case .apple(let effect):
            switch effect {
            case .reverb: return "Reverb"
            case .delay: return "Echo"
            case .distortion: return "Distortion"
            case .eq: return "EQ"
            case .timePitch: return "Time / Pitch"
            case .varispeed: return "Varispeed"
            case .dynamics: return "Compressor"
            case .peakLimiter: return "Limiter"
            case .graphicEQ: return "Graphic EQ"
            case .multibandCompressor: return "Multiband"
            }
        }
    }
}

#endif  // !os(watchOS)
