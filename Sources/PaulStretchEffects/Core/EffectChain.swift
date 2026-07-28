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
    public let eq = AVAudioUnitEQ(numberOfBands: EQBand.defaultBands.count)

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

    /// The presets currently loaded, so they are not reloaded on every apply.
    ///
    /// `loadFactoryPreset` rebuilds the unit's internal state. `apply` runs on
    /// every parameter change, and automation calls it thirty times a second —
    /// so an automated reverb mix was tearing down and rebuilding the reverb at
    /// 30 Hz, which is both wasteful and audible as the tail restarting.
    private var loadedReverbPreset: ReverbPreset?
    private var loadedDistortionPreset: DistortionPreset?

    /// Creates a chain with all nodes unattached.
    public init() {}

    /// The node for a slot, or `nil` for slots this chain does not own.
    private func node(for slot: EffectSlot) -> AVAudioNode? {
        switch slot {
        case .filter:     return filter
        case .eq:         return eq
        case .distortion: return distortion
        case .delay:      return delay
        case .reverb:     return reverb
        case .compressor: return dynamics
        case .limiter:    return limiter
        default:          return nil
        }
    }

    /// How the chain is currently wired, so a reorder knows whether it has
    /// anything to do and can rewire without being told the graph again.
    private var wiring: (engine: AVAudioEngine, source: AVAudioNode,
                         dest: AVAudioNode, format: AVAudioFormat, order: [EffectSlot])?

    /// The units currently WIRED IN, as opposed to merely attached.
    ///
    /// A bypassed `AVAudioUnit` is not free: the engine still pulls a buffer
    /// through it every quantum. Wiring all seven regardless meant a project
    /// with no effects at all still rendered through fourteen units on two
    /// layers plus seven on the master — measurable CPU for nothing.
    private var activeUnits: Set<EffectSlot> = []

    /// Attaches every node to `engine` and wires them in series between
    /// `source` and `dest`.
    ///
    /// - Parameters:
    ///   - engine: The engine to attach to.
    ///   - source: The upstream node (typically an `AVAudioPlayerNode`).
    ///   - dest: The downstream node (typically the main mixer).
    ///   - format: The connection format.
    ///   - order: The running order. Defaults to the sequence the chain has
    ///     always used.
    public func install(in engine: AVAudioEngine, from source: AVAudioNode,
                        to dest: AVAudioNode, format: AVAudioFormat,
                        order: [EffectSlot] = EffectSlot.naturalOrder,
                        active: Set<EffectSlot> = []) {
        for n in [filter, eq, distortion, delay, reverb, dynamics, limiter] as [AVAudioNode] {
            engine.attach(n)
        }
        activeUnits = active
        connect(in: engine, from: source, to: dest, format: format, order: order)
    }

    /// Rewires so only the switched-on units are in the path.
    ///
    /// Called from ``apply(_:)`` when the enabled set changes, which is a
    /// deliberate act — switching a unit on or off — rather than something a
    /// knob does.
    private func updateActiveUnits(_ fx: EffectsParameters) {
        let wanted = Set(EffectSlot.allCases.filter { $0.isStockUnit && fx.isEnabled($0) })
        guard wanted != activeUnits, let w = wiring else {
            activeUnits = wanted
            return
        }
        activeUnits = wanted
        connect(in: w.engine, from: w.source, to: w.dest, format: w.format, order: w.order)
    }

    /// Rewires the chain into a new order.
    ///
    /// Safe to call while the engine runs, but not free: `AVAudioEngine`
    /// rebuilds the graph, which can cost a buffer. Reordering is a deliberate
    /// act, not something to drive from a knob.
    ///
    /// - Parameter order: The new running order.
    public func reorder(to order: [EffectSlot]) {
        guard let w = wiring else { return }
        let wanted = EffectSlot.completed(order).filter(\.isStockUnit)
        guard wanted != w.order.filter(\.isStockUnit) else { return }
        connect(in: w.engine, from: w.source, to: w.dest, format: w.format, order: wanted)
    }

    /// Wires `source → …units… → dest` in the given order.
    private func connect(in engine: AVAudioEngine, from source: AVAudioNode,
                         to dest: AVAudioNode, format: AVAudioFormat,
                         order: [EffectSlot]) {
        // Rewiring a RUNNING engine silences the path.
        //
        // Switching a unit on changes this chain's topology, and an
        // `AVAudioUnit` that was attached but never connected has not been
        // prepared — connecting it into a live graph leaves the layer mute
        // until the engine is restarted. Adding an EQ mid-playback did exactly
        // that: the layer went silent and stayed silent.
        //
        // Stopping and restarting around the change costs a buffer, which is
        // the correct price for a deliberate act like adding a device.
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        defer {
            if wasRunning {
                engine.prepare()
                try? engine.start()
            }
        }

        // Only the units that are ON. Everything else stays attached but out
        // of the path, so it costs nothing until it is switched on.
        let units = EffectSlot.completed(order)
            .filter { activeUnits.contains($0) }
            .compactMap(node(for:))
        // Break the old wiring first. Reconnecting a node that still has an
        // output leaves the engine holding both edges, and the stale one wins.
        for n in units { engine.disconnectNodeOutput(n) }
        engine.disconnectNodeOutput(source)

        var upstream = source
        for n in units {
            engine.connect(upstream, to: n, format: format)
            upstream = n
        }
        engine.connect(upstream, to: dest, format: format)
        wiring = (engine, source, dest, format, EffectSlot.completed(order))
    }

    /// Pushes a parameter set into the chain. Safe to call while audio runs.
    ///
    /// - Parameter fx: The settings to apply.
    public func apply(_ fx: EffectsParameters) {
        updateActiveUnits(fx)
        // Filter (1-band resonant low-pass)
        let fb = filter.bands[0]
        fb.filterType = fx.filterResonance > 0.1 ? .resonantLowPass : .lowPass
        fb.frequency = max(20, min(fx.filterCutoff, 20000))
        fb.gain = fx.filterResonance          // peak gain for resonant LP
        fb.bypass = !fx.filterEnabled
        filter.bypass = !fx.filterEnabled

        // Parametric EQ — one AVAudioUnitEQ band per EQBand.
        for (i, node) in eq.bands.enumerated() {
            guard i < fx.eqBands.count else { node.bypass = true; continue }
            let b = fx.eqBands[i]
            node.filterType = b.type.avFilterType
            node.frequency = max(20, min(b.frequency, 20000))
            node.gain = b.type.usesGain ? max(-24, min(b.gain, 24)) : 0
            node.bandwidth = max(0.05, min(b.bandwidth, 5))
            node.bypass = !(fx.eqEnabled && b.enabled)
        }
        eq.bypass = !fx.eqEnabled

        // Delay
        delay.delayTime = TimeInterval(max(0, fx.delayTime))
        delay.feedback = max(-100, min(fx.delayFeedback, 100))
        delay.lowPassCutoff = max(10, min(fx.delayLowPassCutoff, 22_050))
        delay.wetDryMix = fx.delayEnabled ? max(0, min(fx.delayMix, 100)) : 0
        delay.bypass = !fx.delayEnabled

        // Distortion
        if loadedDistortionPreset != fx.distortionPreset {
            distortion.loadFactoryPreset(fx.distortionPreset.avPreset)
            loadedDistortionPreset = fx.distortionPreset
        }
        distortion.preGain = max(-80, min(fx.distortionPreGain, 20))
        distortion.wetDryMix = fx.distortionEnabled ? max(0, min(fx.distortionMix, 100)) : 0
        distortion.bypass = !fx.distortionEnabled

        // Reverb
        if loadedReverbPreset != fx.reverbPreset {
            reverb.loadFactoryPreset(fx.reverbPreset.avPreset)
            loadedReverbPreset = fx.reverbPreset
        }
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
