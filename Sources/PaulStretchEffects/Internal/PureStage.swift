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
}

extension ShimmerReverb: PureStage {}

/// Builds the enabled pure-DSP stages in their fixed chain order:
/// wow → sweep filter → pump → auto-pan → shimmer → convolution reverb.
/// (Movement first, colour next, space last.)
///
/// `totalFrames` is the full dry length the stages will see — the time base
/// for ``AutomationLane`` evaluation. Pass `nil` when no lanes are bound.
func makePureStages(sampleRate: Double,
                    effects fx: EffectsParameters,
                    totalFrames: Int?) -> [PureStage] {
    var stages: [PureStage] = []
    let lanes = fx.parameterLanes
    let total = totalFrames

    if fx.wowEnabled {
        stages.append(WowFlutter(sampleRate: sampleRate,
                                 amount: fx.wowAmount,
                                 rateHz: fx.wowRateHz,
                                 amountLane: lanes["wow.amount"],
                                 rateLane: lanes["wow.rate"],
                                 totalFrames: total))
    }
    if fx.sweepFilterEnabled {
        stages.append(SweepFilter(sampleRate: sampleRate,
                                  shape: fx.sweepFilterShape,
                                  cutoff: fx.sweepFilterCutoff,
                                  resonance: fx.sweepFilterResonance,
                                  bassCut: fx.sweepFilterBassCut,
                                  lfoPeriodSeconds: fx.sweepFilterLFOPeriod,
                                  lfoDepthOctaves: fx.sweepFilterLFODepth,
                                  cutoffLane: lanes["sweepFilter.cutoff"],
                                  resonanceLane: lanes["sweepFilter.resonance"],
                                  totalFrames: total))
    }
    if fx.pumpEnabled {
        stages.append(BreathingPump(sampleRate: sampleRate,
                                    depth: fx.pumpDepth,
                                    rateHz: fx.pumpRateHz,
                                    depthLane: lanes["pump.depth"],
                                    rateLane: lanes["pump.rate"],
                                    totalFrames: total))
    }
    if fx.autoPanEnabled {
        stages.append(AutoPan(sampleRate: sampleRate,
                              depth: fx.autoPanDepth,
                              rateHz: fx.autoPanRateHz,
                              depthLane: lanes["autoPan.depth"],
                              rateLane: lanes["autoPan.rate"],
                              totalFrames: total))
    }
    if fx.shimmerEnabled {
        stages.append(ShimmerReverb(sampleRate: sampleRate, parameters: fx))
    }
    if fx.convolutionReverbEnabled {
        stages.append(ConvolutionReverb(sampleRate: sampleRate,
                                        profile: fx.convolutionReverbProfile,
                                        decaySeconds: Double(fx.convolutionReverbDecaySeconds),
                                        mix: fx.convolutionReverbMix,
                                        mixLane: lanes["convolutionReverb.mix"],
                                        totalFrames: total))
    }
    return stages
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
