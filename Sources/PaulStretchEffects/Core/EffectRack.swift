//
//  EffectRack.swift
//  SwiftPaulStretch
//
//  Turns [AppleEffect] values into live AVAudioUnit chains and offline
//  bakes — the full Apple processing palette in any order.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation
import AudioToolbox
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// An ordered chain of ``AppleEffect`` units — live on a playback graph or
/// baked offline.
///
/// Unlike the fixed ``EffectChain`` (which mirrors ``EffectsParameters``),
/// a rack is arbitrary: any units, any order, duplicates allowed. Time
/// units (``AppleEffect/timePitch(_:)``, ``AppleEffect/varispeed(_:)``)
/// work in both paths; baking with them scales the output duration by the
/// product of their rates.
public final class EffectRack {

    /// The units in processing order (set at creation; the topology is
    /// fixed — build a new rack to change it).
    public let effects: [AppleEffect]

    /// The instantiated audio units, in order.
    public private(set) var nodes: [AVAudioUnit] = []

    /// Creates a rack, instantiating one audio unit per effect.
    public init(effects: [AppleEffect]) {
        self.effects = effects
        self.nodes = effects.map { $0.makeUnit() }
        for (effect, node) in zip(effects, nodes) { effect.apply(to: node) }
    }

    /// Attaches every unit to `engine` and wires
    /// `source → unit₀ → unit₁ → … → dest`.
    ///
    /// - Parameters:
    ///   - engine: The engine to attach to.
    ///   - source: The upstream node.
    ///   - dest: The downstream node.
    ///   - format: The connection format.
    public func install(in engine: AVAudioEngine, from source: AVAudioNode,
                        to dest: AVAudioNode, format: AVAudioFormat) {
        for node in nodes { engine.attach(node) }
        var previous: AVAudioNode = source
        for node in nodes {
            engine.connect(previous, to: node, format: format)
            previous = node
        }
        engine.connect(previous, to: dest, format: format)
    }

    /// Re-applies parameters position-by-position. The new list must have
    /// the same unit types in the same order (parameter changes only);
    /// returns `false` without touching anything if the topology differs.
    @discardableResult
    public func updateParameters(_ newEffects: [AppleEffect]) -> Bool {
        guard newEffects.count == effects.count else { return false }
        for (new, old) in zip(newEffects, effects) where !new.sameUnitType(as: old) {
            return false
        }
        for (effect, node) in zip(newEffects, nodes) { effect.apply(to: node) }
        return true
    }

    /// The product of the rack's time-unit rates — baked output duration is
    /// the input duration divided by this.
    public static func rateProduct(of effects: [AppleEffect]) -> Double {
        effects.reduce(1.0) { product, effect in
            switch effect {
            case .timePitch(let s): return product * Double(max(1.0 / 32, min(s.rate, 32)))
            case .varispeed(let s): return product * Double(max(0.25, min(s.rate, 4)))
            default: return product
            }
        }
    }

    /// Bakes the rack into a buffer offline (manual rendering — headless
    /// safe, faster than realtime).
    ///
    /// Time units scale the output length by `1/rateProduct`; a decay tail
    /// is appended when reverb or delay units are present. An empty rack —
    /// or an engine that fails to configure — returns the input untouched.
    ///
    /// - Parameters:
    ///   - input: The dry audio.
    ///   - effects: The units to apply, in order.
    ///   - tailSeconds: The decay tail appended when reverb/delay are
    ///     present. Defaults to ``EffectsBaker/tailSeconds``.
    /// - Returns: The processed audio.
    public static func bake(_ input: StereoBuffer,
                            effects: [AppleEffect],
                            tailSeconds: Double = EffectsBaker.tailSeconds) -> StereoBuffer {
        guard !effects.isEmpty, input.frameCount > 0 else { return input }
        let sr = input.sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2),
              let inBuf = AudioFileIO.makePCMBuffer(input, format: format) else { return input }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let rack = EffectRack(effects: effects)
        rack.install(in: engine, from: player, to: engine.mainMixerNode, format: format)

        let hasTail = effects.contains { effect in
            if case .reverb = effect { return true }
            if case .delay = effect { return true }
            return false
        }
        let rate = rateProduct(of: effects)
        let stretched = Int((Double(input.frameCount) / rate).rounded(.up))
        let total = AVAudioFrameCount(stretched + (hasTail ? Int(sr * tailSeconds) : 0))

        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            player.scheduleBuffer(inBuf, at: nil, options: [], completionHandler: nil)
            try engine.start()
            player.play()
        } catch {
            return input
        }

        guard let outChunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else {
            engine.stop(); return input
        }
        var outL = [Float](); outL.reserveCapacity(Int(total))
        var outR = [Float](); outR.reserveCapacity(Int(total))
        var rendered: AVAudioFrameCount = 0
        while rendered < total {
            let frames = min(4096, total - rendered)
            do {
                let status = try engine.renderOffline(frames, to: outChunk)
                guard status == .success else { break }
            } catch { break }
            let n = Int(outChunk.frameLength)
            if n == 0 { break }
            if let ch = outChunk.floatChannelData {
                outL.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
                outR.append(contentsOf: UnsafeBufferPointer(start: ch[1], count: n))
            }
            rendered += outChunk.frameLength
        }
        engine.stop()
        if outL.isEmpty { return input }
        return StereoBuffer(l: outL, r: outR, sampleRate: sr)
    }
}

// MARK: - Unit factory + parameter application

extension AppleEffect {

    /// `true` when both values are the same unit type (parameters may differ).
    func sameUnitType(as other: AppleEffect) -> Bool {
        switch (self, other) {
        case (.reverb, .reverb), (.delay, .delay), (.distortion, .distortion),
             (.eq, .eq), (.timePitch, .timePitch), (.varispeed, .varispeed),
             (.dynamics, .dynamics), (.peakLimiter, .peakLimiter),
             (.graphicEQ, .graphicEQ), (.multibandCompressor, .multibandCompressor):
            return true
        default:
            return false
        }
    }

    /// Instantiates the matching audio unit.
    func makeUnit() -> AVAudioUnit {
        switch self {
        case .reverb:     return AVAudioUnitReverb()
        case .delay:      return AVAudioUnitDelay()
        case .distortion: return AVAudioUnitDistortion()
        case .eq(let s):  return AVAudioUnitEQ(numberOfBands: max(1, s.bands.count))
        case .timePitch:  return AVAudioUnitTimePitch()
        case .varispeed:  return AVAudioUnitVarispeed()
        case .dynamics:
            return EffectChain.makeAudioToolboxEffect(kAudioUnitSubType_DynamicsProcessor)
        case .peakLimiter:
            return EffectChain.makeAudioToolboxEffect(kAudioUnitSubType_PeakLimiter)
        case .graphicEQ:
            return EffectChain.makeAudioToolboxEffect(kAudioUnitSubType_GraphicEQ)
        case .multibandCompressor:
            return EffectChain.makeAudioToolboxEffect(kAudioUnitSubType_MultiBandCompressor)
        }
    }

    /// Pushes this effect's parameters into `unit` (created by
    /// ``makeUnit()``). Safe to call while audio runs.
    func apply(to unit: AVAudioUnit) {
        switch self {
        case .reverb(let s):
            guard let node = unit as? AVAudioUnitReverb else { return }
            node.loadFactoryPreset(s.preset.avPreset)
            node.wetDryMix = max(0, min(s.wetDryMix, 100))

        case .delay(let s):
            guard let node = unit as? AVAudioUnitDelay else { return }
            node.delayTime = TimeInterval(max(0, min(s.delayTime, 2)))
            node.feedback = max(-100, min(s.feedback, 100))
            node.lowPassCutoff = max(10, min(s.lowPassCutoff, 22_050))
            node.wetDryMix = max(0, min(s.wetDryMix, 100))

        case .distortion(let s):
            guard let node = unit as? AVAudioUnitDistortion else { return }
            node.loadFactoryPreset(s.preset.avPreset)
            node.preGain = max(-80, min(s.preGain, 20))
            node.wetDryMix = max(0, min(s.wetDryMix, 100))

        case .eq(let s):
            guard let node = unit as? AVAudioUnitEQ else { return }
            node.globalGain = max(-96, min(s.globalGain, 24))
            for (i, band) in s.bands.enumerated() where i < node.bands.count {
                let b = node.bands[i]
                b.filterType = band.type.avType
                b.frequency = max(20, min(band.frequency, 22_050))
                b.bandwidth = max(0.05, min(band.bandwidth, 5))
                b.gain = max(-96, min(band.gain, 24))
                b.bypass = band.bypass
            }

        case .timePitch(let s):
            guard let node = unit as? AVAudioUnitTimePitch else { return }
            node.rate = max(1.0 / 32, min(s.rate, 32))
            node.pitch = max(-2400, min(s.pitchCents, 2400))
            node.overlap = max(3, min(s.overlap, 32))

        case .varispeed(let s):
            guard let node = unit as? AVAudioUnitVarispeed else { return }
            node.rate = max(0.25, min(s.rate, 4))

        case .dynamics(let s):
            guard let node = unit as? AVAudioUnitEffect else { return }
            EffectChain.setParameter(node, kDynamicsProcessorParam_Threshold, max(-40, min(s.threshold, 20)))
            EffectChain.setParameter(node, kDynamicsProcessorParam_HeadRoom, max(0.1, min(s.headRoom, 40)))
            EffectChain.setParameter(node, kDynamicsProcessorParam_ExpansionRatio, max(1, min(s.expansionRatio, 50)))
            EffectChain.setParameter(node, kDynamicsProcessorParam_ExpansionThreshold, s.expansionThreshold)
            EffectChain.setParameter(node, kDynamicsProcessorParam_AttackTime, max(0.0001, min(s.attackTime, 0.2)))
            EffectChain.setParameter(node, kDynamicsProcessorParam_ReleaseTime, max(0.01, min(s.releaseTime, 3)))
            EffectChain.setParameter(node, kDynamicsProcessorParam_OverallGain, max(-40, min(s.overallGain, 40)))

        case .peakLimiter(let s):
            guard let node = unit as? AVAudioUnitEffect else { return }
            EffectChain.setParameter(node, kLimiterParam_AttackTime, max(0.001, min(s.attackTime, 0.03)))
            EffectChain.setParameter(node, kLimiterParam_DecayTime, max(0.001, min(s.decayTime, 0.06)))
            EffectChain.setParameter(node, kLimiterParam_PreGain, max(-40, min(s.preGain, 40)))

        case .graphicEQ(let s):
            guard let node = unit as? AVAudioUnitEffect else { return }
            EffectChain.setParameter(node, kGraphicEQParam_NumberOfBands, s.use31Bands ? 1 : 0)
            let count = s.use31Bands ? 31 : 10
            for i in 0..<count {
                let gain = i < s.bandGains.count ? max(-20, min(s.bandGains[i], 20)) : 0
                EffectChain.setParameter(node, AudioUnitParameterID(i), gain)
            }

        case .multibandCompressor(let s):
            guard let node = unit as? AVAudioUnitEffect else { return }
            EffectChain.setParameter(node, kMultibandCompressorParam_Pregain, max(-40, min(s.preGain, 40)))
            EffectChain.setParameter(node, kMultibandCompressorParam_Postgain, max(-40, min(s.postGain, 40)))
            let xo = [kMultibandCompressorParam_Crossover1,
                      kMultibandCompressorParam_Crossover2,
                      kMultibandCompressorParam_Crossover3]
            for (i, id) in xo.enumerated() where i < s.crossovers.count {
                EffectChain.setParameter(node, id, max(20, min(s.crossovers[i], 22_050)))
            }
            let th = [kMultibandCompressorParam_Threshold1, kMultibandCompressorParam_Threshold2,
                      kMultibandCompressorParam_Threshold3, kMultibandCompressorParam_Threshold4]
            for (i, id) in th.enumerated() where i < s.thresholds.count {
                EffectChain.setParameter(node, id, max(-100, min(s.thresholds[i], 0)))
            }
            let hr = [kMultibandCompressorParam_Headroom1, kMultibandCompressorParam_Headroom2,
                      kMultibandCompressorParam_Headroom3, kMultibandCompressorParam_Headroom4]
            for (i, id) in hr.enumerated() where i < s.headrooms.count {
                EffectChain.setParameter(node, id, max(0.1, min(s.headrooms[i], 40)))
            }
            let eq = [kMultibandCompressorParam_EQ1, kMultibandCompressorParam_EQ2,
                      kMultibandCompressorParam_EQ3, kMultibandCompressorParam_EQ4]
            for (i, id) in eq.enumerated() where i < s.eqGains.count {
                EffectChain.setParameter(node, id, max(-20, min(s.eqGains[i], 20)))
            }
            EffectChain.setParameter(node, kMultibandCompressorParam_AttackTime, max(0.001, min(s.attackTime, 0.2)))
            EffectChain.setParameter(node, kMultibandCompressorParam_ReleaseTime, max(0.01, min(s.releaseTime, 3)))
        }
    }
}

#endif  // !os(watchOS)
