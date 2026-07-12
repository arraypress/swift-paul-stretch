//
//  EffectStackBaker.swift
//  SwiftPaulStretch
//
//  Bakes an EffectStack in device order: pure-DSP devices run as stages,
//  consecutive Apple devices group into a single offline rack pass.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// Renders audio through an ``EffectStack``, honouring device order exactly.
///
/// The library's pure-DSP devices process sample-by-sample; Apple devices
/// need an offline `AVAudioEngine` pass, so consecutive ones are grouped
/// into a single ``EffectRack`` render (an EQ → compressor → limiter run
/// costs one pass, not three). Order across the boundary is preserved:
/// `eq → shimmer → eq` really does bake the first EQ, then the shimmer,
/// then the second EQ.
public enum EffectStackBaker {

    /// Bakes a stack into a buffer.
    ///
    /// Disabled devices are skipped; an empty (or fully bypassed) stack
    /// returns the input untouched. Effect tails (reverb blooms past the
    /// input's end) are preserved, so the result may be longer than the
    /// input.
    ///
    /// - Parameters:
    ///   - input: The dry audio.
    ///   - stack: The devices, in processing order.
    /// - Returns: The processed audio.
    public static func bake(_ input: StereoBuffer, stack: EffectStack) -> StereoBuffer {
        guard input.frameCount > 0, !stack.isTransparent else { return input }
        var out = input
        var pendingApple: [AppleEffect] = []

        func flushApple() {
            guard !pendingApple.isEmpty else { return }
            out = EffectRack.bake(out, effects: pendingApple)
            pendingApple = []
        }

        for device in stack.activeDevices {
            if case .apple(let effect) = device.kind {
                pendingApple.append(effect)
            } else if let stage = makeStage(for: device.kind,
                                            sampleRate: out.sampleRate,
                                            totalFrames: out.frameCount) {
                flushApple()
                out = runPureStages([stage], input: out)
            }
        }
        flushApple()
        return out
    }

    /// Builds the pure-DSP stage for a device kind (`nil` for `.apple`,
    /// which is handled by the rack path).
    static func makeStage(for kind: EffectDevice.Kind,
                          sampleRate: Double,
                          totalFrames: Int?) -> PureStage? {
        switch kind {
        case .shimmer(let s):
            var fx = EffectsParameters()
            fx.shimmerEnabled = true
            fx.shimmerMix = s.mix
            fx.shimmerPitch = s.pitchSemitones
            fx.shimmerFeedback = s.feedback
            fx.shimmerSize = s.size
            fx.shimmerDamping = s.damping
            fx.shimmerClimbSeconds = s.climbSeconds
            return ShimmerReverb(sampleRate: sampleRate, parameters: fx)

        case .convolutionReverb(let s):
            if let data = s.customIRData,
               let impulse = AudioFileIO.decodeStereo(data, sampleRate: sampleRate) {
                return ConvolutionReverb(sampleRate: sampleRate,
                                         impulse: impulse,
                                         mix: s.mix,
                                         mixLane: s.mixLane,
                                         totalFrames: totalFrames)
            }
            return ConvolutionReverb(sampleRate: sampleRate,
                                     profile: s.profile,
                                     decaySeconds: Double(s.decaySeconds),
                                     mix: s.mix,
                                     mixLane: s.mixLane,
                                     totalFrames: totalFrames)

        case .sweepFilter(let s):
            return SweepFilter(sampleRate: sampleRate,
                               shape: s.shape,
                               cutoff: s.cutoff,
                               resonance: s.resonance,
                               bassCut: s.bassCut,
                               lfoPeriodSeconds: s.lfoPeriodSeconds,
                               lfoDepthOctaves: s.lfoDepthOctaves,
                               cutoffLane: s.cutoffLane,
                               resonanceLane: s.resonanceLane,
                               totalFrames: totalFrames)

        case .wowFlutter(let s):
            return WowFlutter(sampleRate: sampleRate,
                              amount: s.amount,
                              rateHz: s.rateHz,
                              amountLane: s.amountLane,
                              rateLane: s.rateLane,
                              totalFrames: totalFrames)

        case .breathingPump(let s):
            return BreathingPump(sampleRate: sampleRate,
                                 depth: s.depth,
                                 rateHz: s.rateHz,
                                 depthLane: s.depthLane,
                                 rateLane: s.rateLane,
                                 totalFrames: totalFrames)

        case .autoPan(let s):
            return AutoPan(sampleRate: sampleRate,
                           depth: s.depth,
                           rateHz: s.rateHz,
                           depthLane: s.depthLane,
                           rateLane: s.rateLane,
                           totalFrames: totalFrames)

        case .apple:
            return nil
        }
    }
}

#endif  // !os(watchOS)
