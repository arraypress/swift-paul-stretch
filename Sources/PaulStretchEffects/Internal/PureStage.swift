//
//  PureStage.swift
//  SwiftPaulStretch
//
//  The shared shape of the library's own (non-AVAudioUnit) streaming
//  effects, plus the builder that assembles the enabled ones in chain
//  order from an EffectsParameters value.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// A stateful, chunk-sequential stereo processor — the common surface of
/// the library's pure-DSP effects (shimmer, convolution reverb, sweep
/// filter, wow, pump, auto-pan).
protocol PureStage: AnyObject {
    /// Runs one chunk (timeline order; state carries across calls) and
    /// returns the frames finalised so far — usually the same count, but a
    /// stage may withhold frames it can't finalise yet (the convolver holds
    /// up to one block) and release them in a later call or ``tail()``.
    func process(l: [Float], r: [Float]) -> (l: [Float], r: [Float])
    /// Flushes any ring-out after the input ends (empty for tail-less
    /// effects). Called once.
    func tail() -> (l: [Float], r: [Float])
    /// Retunes the stage's CONTINUOUS parameters in place, keeping all state —
    /// delay lines, tanks, phases — so a knob move or an automation tick never
    /// truncates a tail. Structural settings (voice counts, tank sizes,
    /// impulse responses) are ignored here; when one of those changes the host
    /// must rebuild via ``makePureStages`` — compare
    /// ``EffectsParameters/pureDSPStructureSignature`` to know which is needed.
    ///
    /// Called from the render callback, so implementations must not allocate;
    /// stages slew audibly-sensitive values over ~30 ms internally so a step
    /// arrives as a short glide, not a zipper.
    func update(from fx: EffectsParameters)
}

extension PureStage {
    /// Stages opt in; a stage with no continuous parameters ignores updates.
    func update(from fx: EffectsParameters) {}
}

extension ShimmerReverb: PureStage {}

/// Builds the enabled pure-DSP stages in their fixed chain order:
/// wow → sweep filter → trance gate → pump → auto-pan → shimmer →
/// convolution reverb → placement.
/// (Movement first, colour next, space after, stereo placement last.)
///
/// The gate sits *before* the reverbs on purpose: gating after them chops
/// the tail and undoes the space, where gating into them lets each pulse
/// ring out.
///
/// `totalFrames` is the full dry length the stages will see — the time base
/// for ``AutomationLane`` evaluation. Pass `nil` when no lanes are bound.
func makePureStages(sampleRate: Double,
                    effects fx: EffectsParameters,
                    totalFrames: Int?) -> [PureStage] {
    var stages: [PureStage] = []
    let lanes = fx.parameterLanes
    let total = totalFrames

    func buildWow() -> PureStage {
        WowFlutter(sampleRate: sampleRate,
                   amount: fx.wowAmount,
                   rateHz: fx.wowRateHz,
                   amountLane: lanes["wow.amount"],
                   rateLane: lanes["wow.rate"],
                   totalFrames: total)
    }
    func buildSweep() -> PureStage {
        SweepFilter(sampleRate: sampleRate,
                    shape: fx.sweepFilterShape,
                    cutoff: fx.sweepFilterCutoff,
                    resonance: fx.sweepFilterResonance,
                    bassCut: fx.sweepFilterBassCut,
                    lfoPeriodSeconds: fx.sweepFilterLFOPeriod,
                    lfoDepthOctaves: fx.sweepFilterLFODepth,
                    cutoffLane: lanes["sweepFilter.cutoff"],
                    resonanceLane: lanes["sweepFilter.resonance"],
                    totalFrames: total)
    }
    func buildGate() -> PureStage {
        TranceGate(sampleRate: sampleRate,
                   rateHz: fx.tranceGateRateHz,
                   depth: fx.tranceGateDepth,
                   smoothingMs: fx.tranceGateSmoothingMs,
                   pattern: fx.tranceGatePattern,
                   stereoOffset: fx.tranceGateStereoOffset)
    }
    func buildPump() -> PureStage {
        BreathingPump(sampleRate: sampleRate,
                      depth: fx.pumpDepth,
                      rateHz: fx.pumpRateHz,
                      depthLane: lanes["pump.depth"],
                      rateLane: lanes["pump.rate"],
                      totalFrames: total)
    }
    func buildAutoPan() -> PureStage {
        AutoPan(sampleRate: sampleRate,
                depth: fx.autoPanDepth,
                rateHz: fx.autoPanRateHz,
                depthLane: lanes["autoPan.depth"],
                rateLane: lanes["autoPan.rate"],
                totalFrames: total)
    }
    func buildShimmer() -> PureStage {
        ShimmerReverb(sampleRate: sampleRate, parameters: fx)
    }
    func buildSpace() -> PureStage {
        // A custom impulse (decoded from the embedded bytes) replaces the
        // generated profile; decode failures fall back to the profile.
        if let data = fx.convolutionReverbCustomIRData,
           let impulse = decodeImpulse(data, sampleRate: sampleRate) {
            return ConvolutionReverb(sampleRate: sampleRate,
                                     impulse: impulse,
                                     mix: fx.convolutionReverbMix,
                                     mixLane: lanes["convolutionReverb.mix"],
                                     totalFrames: total)
        }
        return ConvolutionReverb(sampleRate: sampleRate,
                                 profile: fx.convolutionReverbProfile,
                                 decaySeconds: Double(fx.convolutionReverbDecaySeconds),
                                 mix: fx.convolutionReverbMix,
                                 mixLane: lanes["convolutionReverb.mix"],
                                 totalFrames: total)
    }
    func buildPitch() -> PureStage {
        PitchVoices(sampleRate: sampleRate,
                    semitones: Double(fx.pitchSemitones),
                    cents: Double(fx.pitchCents),
                    spread: Double(fx.pitchSpread),
                    voiceCount: fx.pitchVoices,
                    mix: Double(fx.pitchMix))
    }
    func buildPlacement() -> PureStage {
        StereoPlacement(sampleRate: sampleRate, pan: fx.placementPan, width: fx.placementWidth)
    }

    /// Builds one slot's stage, or nothing if that unit is off.
    ///
    /// The ladder below used to run in source order, which made the chain's
    /// sequence an implementation detail. It is driven by `fx.chainOrder` now,
    /// so a host can put the gate before the shimmer or after it.
    func stage(for slot: EffectSlot) -> PureStage? {
        switch slot {
        case .wow:         return fx.wowEnabled ? buildWow() : nil
        case .sweepFilter: return fx.sweepFilterEnabled ? buildSweep() : nil
        case .gate:        return fx.tranceGateEnabled ? buildGate() : nil
        case .pump:        return fx.pumpEnabled ? buildPump() : nil
        case .autoPan:     return fx.autoPanEnabled ? buildAutoPan() : nil
        case .shimmer:     return fx.shimmerEnabled ? buildShimmer() : nil
        case .space:       return fx.convolutionReverbEnabled ? buildSpace() : nil
        case .placement:   return fx.placementEnabled ? buildPlacement() : nil
        case .pitch:       return fx.pitchEnabled ? buildPitch() : nil
        default:           return nil          // stock units are not built here
        }
    }

    for slot in fx.pureOrder {
        if let s = stage(for: slot) { stages.append(s) }
    }
    return stages
}

/// Decodes embedded impulse-response bytes at the stream's sample rate.
func decodeImpulse(_ data: Data, sampleRate: Double) -> StereoBuffer? {
    AudioFileIO.decodeStereo(data, sampleRate: sampleRate)
}

/// Runs a whole buffer through a stage list, appending each stage's
/// ring-out so downstream stages hear it — the whole-buffer counterpart of
/// the streaming cascade.
func runPureStages(_ stages: [PureStage], input: StereoBuffer) -> StereoBuffer {
    var l = input.l
    var r = input.r
    for stage in stages {
        let wet = stage.process(l: l, r: r)
        let ring = stage.tail()
        l = wet.l + ring.l
        r = wet.r + ring.r
    }
    return StereoBuffer(l: l, r: r, sampleRate: input.sampleRate)
}

/// Per-sample lane evaluation helper: samples a lane against an absolute
/// frame position over a known total, or returns `fallback` when either is
/// missing.
@inline(__always)
func laneValue(_ lane: AutomationLane?, frame: Int, total: Int?, fallback: Double) -> Double {
    guard let lane, let total, total > 1 else { return fallback }
    return lane.value(at: Double(frame) / Double(total - 1))
}

#endif  // !os(watchOS)
