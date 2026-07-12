//
//  EffectChain.swift
//  SwiftPaulStretch
//
//  A fixed chain of Apple AVAudioUnit effects for live playback graphs:
//  Filter → EQ → Delay → Reverb, always attached, transparent when off.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation
#if canImport(AudioToolbox)
import AudioToolbox
#endif
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// A fixed chain of stock `AVAudioUnit` effects: Filter → EQ → Delay → Reverb.
///
/// Install the chain once between a source node and its destination; after
/// that, ``apply(_:)`` updates every parameter live. Nodes stay attached
/// permanently — an effect that is "off" is made transparent (bypassed,
/// wet/dry `0`) instead of being disconnected, so the graph never needs
/// rewiring while audio runs.
///
/// ```swift
/// let chain = EffectChain()
/// chain.install(in: engine, from: playerNode, to: engine.mainMixerNode, format: format)
/// chain.apply(effects)          // live, any time
/// ```
public final class EffectChain {

    /// 1-band resonant low-pass filter.
    public let filter = AVAudioUnitEQ(numberOfBands: 1)

    /// 3-band EQ (low shelf 120 Hz, parametric 1 kHz, high shelf 6 kHz).
    public let eq = AVAudioUnitEQ(numberOfBands: 3)

    /// Stereo delay.
    public let delay = AVAudioUnitDelay()

    /// Distortion (factory presets — see ``DistortionPreset``).
    public let distortion = AVAudioUnitDistortion()

    /// Reverb (factory presets — see ``ReverbPreset``).
    public let reverb = AVAudioUnitReverb()

    /// Apple's dynamics processor (compressor/expander), wrapped from
    /// AudioToolbox — AVFAudio has no native class for it.
    public let dynamics = EffectChain.makeAudioToolboxEffect(kAudioUnitSubType_DynamicsProcessor)

    /// Apple's peak limiter, wrapped from AudioToolbox.
    public let limiter = EffectChain.makeAudioToolboxEffect(kAudioUnitSubType_PeakLimiter)

    /// Instantiates an Apple AudioToolbox effect by subtype.
    static func makeAudioToolboxEffect(_ subType: OSType) -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
    }

    /// Sets a global-scope parameter on an AudioToolbox-backed unit.
    static func setParameter(_ unit: AVAudioUnitEffect, _ id: AudioUnitParameterID, _ value: Float) {
        AudioUnitSetParameter(unit.audioUnit, id, kAudioUnitScope_Global, 0, value, 0)
    }

    /// Creates a chain with all nodes unattached.
    public init() {}

    /// Attaches every node to `engine` and wires
    /// `source → filter → eq → delay → reverb → dest`.
    ///
    /// - Parameters:
    ///   - engine: The engine to attach to.
    ///   - source: The upstream node (typically an `AVAudioPlayerNode`).
    ///   - dest: The downstream node (typically the main mixer).
    ///   - format: The connection format.
    public func install(in engine: AVAudioEngine, from source: AVAudioNode,
                        to dest: AVAudioNode, format: AVAudioFormat) {
        for n in [filter, eq, distortion, delay, reverb, dynamics, limiter] as [AVAudioNode] {
            engine.attach(n)
        }
        engine.connect(source, to: filter, format: format)
        engine.connect(filter, to: eq, format: format)
        engine.connect(eq, to: distortion, format: format)
        engine.connect(distortion, to: delay, format: format)
        engine.connect(delay, to: reverb, format: format)
        engine.connect(reverb, to: dynamics, format: format)
        engine.connect(dynamics, to: limiter, format: format)
        engine.connect(limiter, to: dest, format: format)
    }

    /// Pushes a parameter set into the chain. Safe to call while audio runs.
    ///
    /// - Parameter fx: The settings to apply.
    public func apply(_ fx: EffectsParameters) {
        // Filter (1-band resonant low-pass)
        let fb = filter.bands[0]
        fb.filterType = fx.filterResonance > 0.1 ? .resonantLowPass : .lowPass
        fb.frequency = max(20, min(fx.filterCutoff, 20000))
        fb.gain = fx.filterResonance          // peak gain for resonant LP
        fb.bypass = !fx.filterEnabled
        filter.bypass = !fx.filterEnabled

        // 3-band EQ
        let lo = eq.bands[0], mid = eq.bands[1], hi = eq.bands[2]
        lo.filterType = .lowShelf;  lo.frequency = 120;  lo.gain = fx.eqLowGain;  lo.bypass = !fx.eqEnabled
        mid.filterType = .parametric; mid.frequency = 1000; mid.bandwidth = 1.0; mid.gain = fx.eqMidGain; mid.bypass = !fx.eqEnabled
        hi.filterType = .highShelf; hi.frequency = 6000; hi.gain = fx.eqHighGain; hi.bypass = !fx.eqEnabled
        eq.bypass = !fx.eqEnabled

        // Delay
        delay.delayTime = TimeInterval(max(0, fx.delayTime))
        delay.feedback = max(-100, min(fx.delayFeedback, 100))
        delay.lowPassCutoff = max(10, min(fx.delayLowPassCutoff, 22_050))
        delay.wetDryMix = fx.delayEnabled ? max(0, min(fx.delayMix, 100)) : 0
        delay.bypass = !fx.delayEnabled

        // Distortion
        distortion.loadFactoryPreset(fx.distortionPreset.avPreset)
        distortion.preGain = max(-80, min(fx.distortionPreGain, 20))
        distortion.wetDryMix = fx.distortionEnabled ? max(0, min(fx.distortionMix, 100)) : 0
        distortion.bypass = !fx.distortionEnabled

        // Reverb
        reverb.loadFactoryPreset(fx.reverbPreset.avPreset)
        reverb.wetDryMix = fx.reverbEnabled ? max(0, min(fx.reverbMix, 100)) : 0
        reverb.bypass = !fx.reverbEnabled

        // Dynamics processor (parameter IDs from AudioUnitParameters.h)
        Self.setParameter(dynamics, kDynamicsProcessorParam_Threshold, max(-40, min(fx.compressorThreshold, 20)))
        Self.setParameter(dynamics, kDynamicsProcessorParam_HeadRoom, max(0.1, min(fx.compressorHeadroom, 40)))
        Self.setParameter(dynamics, kDynamicsProcessorParam_ExpansionRatio, max(1, min(fx.compressorExpansionRatio, 50)))
        Self.setParameter(dynamics, kDynamicsProcessorParam_ExpansionThreshold, fx.compressorExpansionThreshold)
        Self.setParameter(dynamics, kDynamicsProcessorParam_AttackTime, max(0.0001, min(fx.compressorAttack, 0.2)))
        Self.setParameter(dynamics, kDynamicsProcessorParam_ReleaseTime, max(0.01, min(fx.compressorRelease, 3)))
        Self.setParameter(dynamics, kDynamicsProcessorParam_OverallGain, max(-40, min(fx.compressorGain, 40)))
        dynamics.bypass = !fx.compressorEnabled

        // Peak limiter
        Self.setParameter(limiter, kLimiterParam_AttackTime, max(0.001, min(fx.limiterAttack, 0.03)))
        Self.setParameter(limiter, kLimiterParam_DecayTime, max(0.001, min(fx.limiterDecay, 0.06)))
        Self.setParameter(limiter, kLimiterParam_PreGain, max(-40, min(fx.limiterPreGain, 40)))
        limiter.bypass = !fx.limiterEnabled
    }
}

#endif  // !os(watchOS)
