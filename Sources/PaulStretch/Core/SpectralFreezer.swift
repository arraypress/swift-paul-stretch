//
//  SpectralFreezer.swift
//  SwiftPaulStretch
//
//  Spectral freeze: capture one instant's magnitude spectrum and
//  resynthesise it forever with fresh random phase per hop.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import Accelerate

/// Spectral freeze — one frozen instant, sustained indefinitely.
///
/// The magnitude spectrum is captured at a single position in the source
/// and resynthesised for the requested duration with brand-new random
/// phases every hop: effectively PaulStretch with the input pinned to one
/// moment, yielding an endless, gently shimmering pad. A magnitude box-blur
/// ("smear") morphs the result from tonal toward coloured noise.
///
/// ```swift
/// let pad = SpectralFreezer.render(source, position: 0.5, smear: 0.3,
///                                  targetSeconds: 120)
/// ```
public enum SpectralFreezer {

    /// Freezes `input` at `position` and resynthesises `targetSeconds` of audio.
    ///
    /// - Parameters:
    ///   - input: The source audio. Sources shorter than 32 frames return an
    ///     empty buffer (nothing to window).
    ///   - position: The capture point, `0…1` through the source.
    ///   - smear: Magnitude blur amount, `0…1` — low keeps tonal peaks, high
    ///     washes toward noise.
    ///   - targetSeconds: The duration to synthesise, in seconds.
    ///   - windowSeconds: The STFT window length, in seconds (rounded up to
    ///     a power-of-two frame count).
    ///   - seed: The render seed. Defaults to ``PaulStretcher/defaultSeed``.
    ///   - isCancelled: Polled periodically; return `true` to stop early.
    ///   - progress: Called with the completed fraction, `0…1`, from worker
    ///     threads.
    /// - Returns: The frozen pad, peak-normalised to 0.92 — or an empty
    ///   buffer if the render was cancelled (or the input was too short).
    public static func render(_ input: StereoBuffer,
                              position: Double,
                              smear: Double,
                              targetSeconds: Double,
                              windowSeconds: Double = 0.25,
                              seed: UInt64 = PaulStretcher.defaultSeed,
                              isCancelled: () -> Bool = { false },
                              progress: ((Double) -> Void)? = nil) -> StereoBuffer {
        guard let kernel = FreezeKernel(input: input,
                                        positionNorm: position,
                                        smear: smear,
                                        targetSeconds: targetSeconds,
                                        windowSeconds: windowSeconds,
                                        seed: seed) else {
            return StereoBuffer(l: [], r: [], sampleRate: input.sampleRate)
        }
        return renderFull(kernel, sampleRate: input.sampleRate,
                          isCancelled: isCancelled, progress: progress)
    }

    /// Renders a prepared freeze kernel across all cores into a full buffer
    /// and peak-normalises it to 0.92.
    static func renderFull(_ kernel: FreezeKernel,
                           sampleRate: Double,
                           isCancelled: () -> Bool,
                           progress: ((Double) -> Void)?) -> StereoBuffer {
        let outputLength = kernel.outputLength
        var outL = [Float](repeating: 0, count: outputLength)
        var outR = [Float](repeating: 0, count: outputLength)

        if kernel.lastBlock < 0 {
            progress?(1)
            return StereoBuffer(l: outL, r: outR, sampleRate: sampleRate)
        }

        let counter = BlockProgress(total: kernel.totalBlocks, callback: progress)
        outL.withUnsafeMutableBufferPointer { lp in
            outR.withUnsafeMutableBufferPointer { rp in
                kernel.renderRangeParallel(0, outputLength,
                                           outL: lp.baseAddress!, outR: rp.baseAddress!,
                                           isCancelled: isCancelled,
                                           onBlocksDone: { counter.add($0) })
            }
        }

        if isCancelled() { return StereoBuffer(l: [], r: [], sampleRate: sampleRate) }

        normalizeToPeak(&outL, &outR, target: 0.92)
        progress?(1)
        return StereoBuffer(l: outL, r: outR, sampleRate: sampleRate)
    }
}
