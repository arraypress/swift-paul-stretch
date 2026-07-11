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

    /// Reverb (factory presets — see ``ReverbPreset``).
    public let reverb = AVAudioUnitReverb()

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
        for n in [filter, eq, delay, reverb] as [AVAudioNode] { engine.attach(n) }
        engine.connect(source, to: filter, format: format)
        engine.connect(filter, to: eq, format: format)
        engine.connect(eq, to: delay, format: format)
        engine.connect(delay, to: reverb, format: format)
        engine.connect(reverb, to: dest, format: format)
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
        delay.lowPassCutoff = 8000
        delay.wetDryMix = fx.delayEnabled ? max(0, min(fx.delayMix, 100)) : 0
        delay.bypass = !fx.delayEnabled

        // Reverb
        reverb.loadFactoryPreset(fx.reverbPreset.avPreset)
        reverb.wetDryMix = fx.reverbEnabled ? max(0, min(fx.reverbMix, 100)) : 0
        reverb.bypass = !fx.reverbEnabled
    }
}

#endif  // !os(watchOS)
