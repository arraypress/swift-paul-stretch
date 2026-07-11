//
//  PaulStretcher.swift
//  SwiftPaulStretch
//
//  The raw PaulStretch algorithm: windowed STFT, per-window phase
//  randomisation, optional FFT-domain pitch shift, 4× Hann overlap-add.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import Accelerate

/// The raw PaulStretch algorithm — Paul Nasca's "extreme sound stretching".
///
/// Each analysis window is Hann-windowed, transformed, given randomised
/// phases (magnitudes untouched), inverse-transformed and overlap-added at a
/// quarter-window hop. Because phases are random, windows can be pulled from
/// the input far slower than they are laid down on the output, stretching
/// the sound by enormous ratios without pitch change — the result is the
/// characteristic smeared, choir-like wash.
///
/// This type is the single-pass primitive. For the full pipeline — target
/// durations, tiling, layering, loops and fades — use ``StretchRenderer``.
///
/// ```swift
/// let washed = PaulStretcher.stretch(source, ratio: 8)
/// ```
///
/// > Note: A bare stretch carries ~30 % amplitude flutter — that is inherent
/// > to PaulStretch's random phases (the reference implementations flutter
/// > identically), not a defect. Reverb is the traditional masker.
public enum PaulStretcher {

    /// The seed every render uses unless the caller supplies one.
    ///
    /// All randomness in the library is derived from the seed, so the same
    /// source, parameters and seed always reproduce bit-identical output.
    /// Pass different seeds (see ``StretchRenderer/variationSeed(_:from:)``)
    /// to get fresh variations of the same settings.
    public static let defaultSeed: UInt64 = 0x2545F4914F6CDD1D

    /// Stretches `input` by `ratio`, returning a buffer ~`ratio`× longer.
    ///
    /// Ratios of `1.001` or below return the input unchanged. The work is
    /// split across CPU cores; thanks to per-window seeding the multicore
    /// result is bit-identical to a single-threaded render.
    ///
    /// - Parameters:
    ///   - input: The source audio.
    ///   - ratio: The stretch factor (`8` → eight times longer).
    ///   - windowSeconds: The STFT window length, in seconds (rounded up to
    ///     a power-of-two frame count).
    ///   - phaseRandomness: Phase scramble amount, `0…1`. `1` is the classic
    ///     full wash.
    ///   - pitchSemitones: FFT-domain pitch shift in semitones, duration
    ///     preserved. `0` is off.
    ///   - onsetSensitivity: How strongly rising-energy moments ease off the
    ///     phase scramble, `0…1`.
    ///   - seed: The render seed. Defaults to ``defaultSeed``.
    ///   - isCancelled: Polled periodically; return `true` to stop early.
    ///   - progress: Called with the completed fraction, `0…1`, from worker
    ///     threads.
    /// - Returns: The stretched audio, peak-normalised to 0.92 — or an empty
    ///   buffer if the render was cancelled.
    public static func stretch(_ input: StereoBuffer,
                               ratio: Double,
                               windowSeconds: Double = 0.25,
                               phaseRandomness: Double = 1.0,
                               pitchSemitones: Double = 0,
                               onsetSensitivity: Double = 0,
                               seed: UInt64 = defaultSeed,
                               isCancelled: () -> Bool = { false },
                               progress: ((Double) -> Void)? = nil) -> StereoBuffer {
        if ratio <= 1.001 {
            progress?(1)
            return input
        }
        let kernel = StretchKernel(input: input,
                                   ratio: ratio,
                                   windowSeconds: windowSeconds,
                                   phaseRandomness: phaseRandomness,
                                   pitchSemitones: pitchSemitones,
                                   onsetSensitivity: onsetSensitivity,
                                   seed: seed)
        return renderFull(kernel, sampleRate: input.sampleRate,
                          isCancelled: isCancelled, progress: progress)
    }

    /// Renders a prepared kernel across all cores into a full buffer and
    /// peak-normalises it to 0.92 — the shared implementation behind
    /// ``stretch(_:ratio:windowSeconds:phaseRandomness:pitchSemitones:onsetSensitivity:seed:isCancelled:progress:)``
    /// and the pipeline's layer materialisation.
    static func renderFull(_ kernel: StretchKernel,
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

/// Scales both channels so the larger absolute peak lands on `target`
/// (no-op for silent buffers). vDSP throughout.
func normalizeToPeak(_ outL: inout [Float], _ outR: inout [Float], target: Float) {
    let n = outL.count
    guard n > 0 else { return }
    var peakL: Float = 0, peakR: Float = 0
    outL.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress!, 1, &peakL, vDSP_Length(n)) }
    outR.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress!, 1, &peakR, vDSP_Length(n)) }
    let peak = max(peakL, peakR)
    if peak > 0 {
        var gain = target / peak
        outL.withUnsafeMutableBufferPointer { vDSP_vsmul($0.baseAddress!, 1, &gain, $0.baseAddress!, 1, vDSP_Length(n)) }
        outR.withUnsafeMutableBufferPointer { vDSP_vsmul($0.baseAddress!, 1, &gain, $0.baseAddress!, 1, vDSP_Length(n)) }
    }
}
