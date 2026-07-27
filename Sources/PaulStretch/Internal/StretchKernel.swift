//
//  StretchKernel.swift
//  SwiftPaulStretch
//
//  The PaulStretch inner loop, factored so any output frame range can be
//  rendered independently and deterministically. Both the in-memory renderer
//  (which partitions the full timeline across cores) and the chunked
//  renderer (which partitions it across time) drive this one kernel, so
//  their outputs are bit-identical by construction.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import Accelerate

// MARK: - Phase randomisation

/// `amount = 1` → fully random phase (the classic wash); `0` → untouched;
/// between → rotate each bin by a random delta in `±π·amount`. Magnitudes
/// are preserved and bins conjugate-mirrored so the IFFT stays real.
/// Wraps a phase difference to `(-pi, pi]` so blending takes the short way
/// round rather than sweeping the long arc.
@inline(__always)
private func wrapPi(_ x: Double) -> Double {
    var a = x.truncatingRemainder(dividingBy: 2 * .pi)
    if a > .pi { a -= 2 * .pi }
    if a <= -.pi { a += 2 * .pi }
    return a
}

private func randomizePhases(_ real: UnsafeMutablePointer<Float>,
                             _ imag: UnsafeMutablePointer<Float>,
                             _ n: Int,
                             _ amount: Double,
                             _ rng: inout FastRNG,
                             _ prevRng: inout FastRNG?,
                             _ continuity: Double = 0) {
    let half = n >> 1
    if amount >= 1 {
        for k in 1..<half {
            let re = Double(real[k]); let im = Double(imag[k])
            let mag = (re * re + im * im).squareRoot()
            var angle = rng.unit() * 2 * .pi
            // Carry a fraction of the previous window's phase for this bin.
            // `prevRng` replays window b-1's stream in lockstep, so no state
            // is stored and any range can still be rendered independently.
            if continuity > 0, prevRng != nil {
                let prev = prevRng!.unit() * 2 * .pi
                angle = prev + (1 - continuity) * wrapPi(angle - prev)
            }
            let rv = Float(mag * cos(angle)); let iv = Float(mag * sin(angle))
            real[k] = rv; imag[k] = iv
            real[n - k] = rv; imag[n - k] = -iv
        }
    } else if amount > 0 {
        let maxDelta = Double.pi * amount
        for k in 1..<half {
            let re = Double(real[k]); let im = Double(imag[k])
            let mag = (re * re + im * im).squareRoot()
            let oldAngle = atan2(im, re)
            // Keep the streams aligned even though partial randomisation is
            // already anchored to the source phase and needs no continuity.
            if prevRng != nil { _ = prevRng!.unit() }
            let delta = (rng.unit() * 2 - 1) * maxDelta
            let na = oldAngle + delta
            let rv = Float(mag * cos(na)); let iv = Float(mag * sin(na))
            real[k] = rv; imag[k] = iv
            real[n - k] = rv; imag[n - k] = -iv
        }
    }
    imag[0] = 0
    imag[half] = 0
}

// MARK: - Read position

extension StretchKernel {

    /// The analysis start frame for window `b`.
    ///
    /// Linear when ``spectralDrift`` is `0` (bit-identical to the classic
    /// algorithm). Otherwise the linear position is offset by three
    /// sinusoids whose rates are in golden-ratio proportion — chosen so the
    /// components are mutually irrational and the combined motion has no
    /// audible period over an hour-long render.
    func readPosition(_ b: Int) -> Int {
        let linear = Double(b) * inputStride
        guard spectralDrift > 0, lastBlock > 0, inputLen > 0 else { return Int(linear) }
        let phi = 1.618033988749895
        let tau = Double(b) / Double(lastBlock)          // 0…1 through the render
        let w = (sin(2 * .pi * phi * tau)
               + sin(2 * .pi * phi * phi * tau)
               + sin(2 * .pi * phi * phi * phi * tau)) / 3
        // +-30 % of the source at full drift, matching the reference range.
        let offset = w * spectralDrift * 0.30 * Double(inputLen)
        return Int((linear + offset).rounded(.down))
    }
}

// MARK: - Resampling

extension StretchKernel {

    /// Resamples a buffer, changing its length by `by` and its pitch by `1/by`.
    ///
    /// Catmull-Rom rather than linear: linear interpolation of a waveform is a
    /// lowpass whose corner moves with the fractional offset, which is its own
    /// source of shimmer — precisely the class of artefact this is here to
    /// remove.
    ///
    /// Decimation (`by < 1`, i.e. shifting UP) is pre-filtered with a short
    /// moving average, because taking every 1/by-th sample of full-band audio
    /// folds everything above the new Nyquist back down as aliasing.
    ///
    /// - Parameters:
    ///   - input: The audio to resample.
    ///   - by: Length multiplier. `0.5` halves the length and raises pitch an
    ///     octave; `2` doubles it and drops an octave.
    /// - Returns: The resampled audio, at the same sample rate.
    static func resampled(_ input: StereoBuffer, by by: Double) -> StereoBuffer {
        let n = input.frameCount
        guard n > 3, by > 0, abs(by - 1) > 0.0001 else { return input }
        let outCount = max(4, Int((Double(n) * by).rounded()))

        /// A moving average wide enough to cover the new sample spacing.
        func prefiltered(_ x: [Float]) -> [Float] {
            guard by < 1 else { return x }
            let width = max(2, Int((1 / by).rounded()))
            guard width > 1 else { return x }
            var out = [Float](repeating: 0, count: x.count)
            var running: Float = 0
            for i in 0..<x.count {
                running += x[i]
                if i >= width { running -= x[i - width] }
                out[i] = running / Float(min(i + 1, width))
            }
            return out
        }

        func resample(_ x: [Float]) -> [Float] {
            let src = prefiltered(x)
            var out = [Float](repeating: 0, count: outCount)
            let step = Double(n - 1) / Double(outCount - 1)
            for i in 0..<outCount {
                let pos = Double(i) * step
                let k = Int(pos)
                let t = Float(pos - Double(k))
                let p0 = src[max(k - 1, 0)]
                let p1 = src[min(k, n - 1)]
                let p2 = src[min(k + 1, n - 1)]
                let p3 = src[min(k + 2, n - 1)]
                out[i] = 0.5 * ((2 * p1)
                              + (-p0 + p2) * t
                              + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                              + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t)
            }
            return out
        }

        return StereoBuffer(l: resample(input.l), r: resample(input.r),
                            sampleRate: input.sampleRate)
    }
}

// MARK: - FFT-domain pitch shift

/// Output bin `K` reads from source bin `K/factor` (linear interpolation).
/// `factor > 1` shifts up, `< 1` down; duration is preserved.
private func pitchShiftBins(_ real: UnsafeMutablePointer<Float>,
                            _ imag: UnsafeMutablePointer<Float>,
                            _ n: Int,
                            _ factor: Double,
                            _ tmpR: UnsafeMutablePointer<Float>,
                            _ tmpI: UnsafeMutablePointer<Float>) {
    let half = n >> 1
    tmpR[0] = real[0]; tmpI[0] = 0
    for k in 1..<half {
        let sourceK = Double(k) / factor
        let lo = Int(sourceK.rounded(.down))
        let hi = lo + 1
        if lo < 1 || hi >= half {
            tmpR[k] = 0; tmpI[k] = 0
        } else {
            let frac = Float(sourceK - Double(lo))
            tmpR[k] = real[lo] * (1 - frac) + real[hi] * frac
            tmpI[k] = imag[lo] * (1 - frac) + imag[hi] * frac
        }
        tmpR[n - k] = tmpR[k]
        tmpI[n - k] = -tmpI[k]
    }
    tmpR[half] = 0; tmpI[half] = 0
    for i in 0..<n { real[i] = tmpR[i]; imag[i] = tmpI[i] }
}

// MARK: - Kernel

/// Precomputed state for one PaulStretch pass: window, strides, onset curve
/// and seed. Renders any output frame range on demand.
///
/// The STFT windows are mutually independent — each window's phases come
/// from a splitmix64-mixed per-window seed (see `blockSeed`), so any two
/// callers rendering ranges that share a boundary window compute identical
/// samples for it. That single property enables lock-free multicore
/// rendering *and* memory-bounded chunked rendering.
struct StretchKernel {
    let inL: [Float]
    let inR: [Float]
    let inputLen: Int
    let windowSize: Int
    let halfWindow: Int
    /// Output hop between windows (`windowSize / 4` — 4× Hann overlap).
    let outputStride: Int
    /// Input hop between windows (`outputStride / ratio`).
    let inputStride: Double
    /// Total raw output length: `max(windowSize, inputLen × ratio)`.
    let outputLength: Int
    /// Index of the last window whose full extent fits the output.
    let lastBlock: Int
    /// How many windows can overlap one output frame (+1 safety margin).
    let windowBlocks: Int
    let hann: [Float]
    let onsetCurve: [Float]?
    let phaseRandomness: Double
    let onsetSensitivity: Double
    let pitchFactor: Double
    let doPitch: Bool
    let seed: UInt64
    /// How far the analysis read head wanders from its linear position,
    /// as a fraction of the input (`0` = classic linear reads).
    ///
    /// A linear read makes a very long render statistically static: the same
    /// stretch ratio walks the source at a constant rate, so after a minute
    /// there is nothing new happening. Drifting the read position keeps
    /// re-approaching the material from different places, which is what
    /// keeps hour-long output alive. The drift is a sum of three sinusoids
    /// at golden-ratio-related rates, so the components never share a period
    /// and the motion doesn't audibly repeat.
    ///
    /// Position is a pure function of the window index, so range-independent
    /// rendering (multicore, chunked) still holds.
    let spectralDrift: Double
    /// How much of the previous window's phase is carried into this one,
    /// `0…1` (`0` = fully independent random phase, the classic behaviour).
    ///
    /// Pure per-window randomness is what gives PaulStretch its grain. A
    /// little continuity keeps the drone character but takes the digital
    /// edge off. The previous window's phases are *recomputed* from its own
    /// seed rather than remembered, so this stays range-independent too.
    let phaseContinuity: Double
    /// Read the input circularly instead of zero-padding past its ends.
    ///
    /// Used by seamless-loop renders: without it, the analysis window
    /// progressively empties as the read head passes the input's end, so
    /// the final `windowSize / inputLen` fraction of the output decays to
    /// silence — glaring when the input is short relative to the window.
    let wrapInput: Bool

    /// The number of windows a full render processes (progress accounting).
    var totalBlocks: Int { lastBlock + 1 }

    /// Builds a kernel for stretching `input` by `ratio`.
    ///
    /// The caller is responsible for the `ratio <= 1.001` passthrough case —
    /// the kernel requires a real stretch.
    init(input: StereoBuffer,
         ratio: Double,
         windowSeconds: Double,
         phaseRandomness: Double,
         pitchSemitones: Double,
         onsetSensitivity: Double,
         seed: UInt64,
         spectralDrift: Double = 0,
         phaseContinuity: Double = 0,
         wrapInput: Bool = false) {
        let sr = input.sampleRate
        // Pitch by RESAMPLING THE INPUT, not by remapping FFT bins.
        //
        // Bin remapping interpolated complex values linearly, which is not
        // phase-coherent: adjacent bins of a windowed sinusoid have a fixed
        // phase relationship and interpolation destroys it by an amount that
        // depends on where the fractional bin position falls. Shifting UP reads
        // source positions less than a bin apart, so consecutive output bins
        // interpolated repeatedly within the same pair and the error varied
        // window to window — audible as flutter, and measurably worse upward
        // than downward.
        //
        // Resampling is what PaulStretch itself does. Reading the source
        // 1/factor times as fast raises its pitch by `factor`; the stretch
        // ratio is scaled to compensate, so the OUTPUT LENGTH is unchanged and
        // every caller that depends on it still gets what it asked for.
        let factor = pow(2.0, pitchSemitones / 12.0)
        let shifting = abs(factor - 1) > 0.001
        let source = shifting ? StretchKernel.resampled(input, by: 1 / factor) : input
        let ratio = shifting ? ratio * factor : ratio

        self.inL = source.l
        self.inR = source.r
        self.inputLen = source.frameCount
        self.wrapInput = wrapInput && source.frameCount > 0
        self.phaseRandomness = min(max(phaseRandomness, 0), 1)
        self.onsetSensitivity = min(max(onsetSensitivity, 0), 1)
        self.pitchFactor = factor
        // The bin-domain shift is off: the pitch is already in the resampled
        // source. Doing both would shift twice.
        self.doPitch = false
        self.spectralDrift = min(max(spectralDrift, 0), 1)
        self.phaseContinuity = min(max(phaseContinuity, 0), 1)
        self.seed = seed

        let windowSize = nextPow2(Int(windowSeconds * sr))
        self.windowSize = windowSize
        self.halfWindow = windowSize >> 1
        self.outputStride = (windowSize >> 1) >> 1
        self.inputStride = Double((windowSize >> 1) >> 1) / ratio
        self.outputLength = max(windowSize, Int(Double(source.frameCount) * ratio))
        self.lastBlock = (outputLength - (windowSize >> 1) - 1) / ((windowSize >> 1) >> 1)
        self.windowBlocks = windowSize / ((windowSize >> 1) >> 1) + 1

        var hann = [Float](repeating: 0, count: windowSize)
        for i in 0..<windowSize {
            hann[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(windowSize - 1)))
        }
        self.hann = hann

        self.onsetCurve = self.onsetSensitivity > 0
            ? computeOnsetCurve(input.l, input.r, onsetFrameSize) : nil
    }

    /// Renders output frames `[rangeStart, rangeEnd)` into local buffers
    /// whose index `0` is absolute frame `rangeStart`.
    ///
    /// Contributions are **added** (overlap-add), so the buffers must be
    /// zeroed by the caller. Every window overlapping the range is processed
    /// in ascending order and its overlap-add is clipped to the range, which
    /// keeps per-sample accumulation order — and therefore the exact float
    /// result — independent of how the timeline is partitioned.
    ///
    /// - Parameters:
    ///   - rangeStart: First absolute output frame to produce.
    ///   - rangeEnd: One past the last absolute output frame to produce.
    ///   - outL: Left output base pointer (local index 0 = `rangeStart`).
    ///   - outR: Right output base pointer.
    ///   - isCancelled: Polled every 64 windows; when `true` the render
    ///     stops early, leaving the buffers incomplete.
    ///   - onBlocksDone: Progress callback, invoked with a window count
    ///     every 64 windows. Must be thread-safe.
    func renderRange(_ rangeStart: Int,
                     _ rangeEnd: Int,
                     outL: UnsafeMutablePointer<Float>,
                     outR: UnsafeMutablePointer<Float>,
                     isCancelled: () -> Bool,
                     onBlocksDone: ((Int) -> Void)?) {
        guard let ft = PSFFT(n: windowSize) else { return }
        let bStart = max(0, rangeStart / outputStride - windowBlocks)
        let bEnd = min(lastBlock, (rangeEnd - 1) / outputStride)
        if bStart > bEnd { return }

        let realL = UnsafeMutablePointer<Float>.allocate(capacity: windowSize)
        let imagL = UnsafeMutablePointer<Float>.allocate(capacity: windowSize)
        let realR = UnsafeMutablePointer<Float>.allocate(capacity: windowSize)
        let imagR = UnsafeMutablePointer<Float>.allocate(capacity: windowSize)
        let tmpR  = UnsafeMutablePointer<Float>.allocate(capacity: windowSize)
        let tmpI  = UnsafeMutablePointer<Float>.allocate(capacity: windowSize)
        defer { realL.deallocate(); imagL.deallocate(); realR.deallocate()
                imagR.deallocate(); tmpR.deallocate(); tmpI.deallocate() }

        inL.withUnsafeBufferPointer { inLP in
        inR.withUnsafeBufferPointer { inRP in
        hann.withUnsafeBufferPointer { hannP in
            let inLp = inLP.baseAddress!
            let inRp = inRP.baseAddress!
            let win = hannP.baseAddress!

            var localDone = 0
            for b in bStart...bEnd {
                if (b & 63) == 0 && isCancelled() { return }
                let outputPos = b * outputStride
                let inputStart = readPosition(b)

                if wrapInput {
                    for i in 0..<windowSize {
                        let idx = (inputStart + i) % inputLen
                        let ww = win[i]
                        realL[i] = inLp[idx] * ww; realR[i] = inRp[idx] * ww
                        imagL[i] = 0; imagR[i] = 0
                    }
                } else {
                    for i in 0..<windowSize {
                        let idx = inputStart + i
                        let ww = win[i]
                        if idx >= 0 && idx < inputLen {
                            realL[i] = inLp[idx] * ww; realR[i] = inRp[idx] * ww
                        } else {
                            realL[i] = 0; realR[i] = 0
                        }
                        imagL[i] = 0; imagR[i] = 0
                    }
                }

                ft.forward(realL, imagL)
                ft.forward(realR, imagR)

                var effRandomness = phaseRandomness
                if let oc = onsetCurve {
                    let frameIdx = max(0, min(oc.count - 1, inputStart / onsetFrameSize))
                    effRandomness = phaseRandomness * (1 - onsetSensitivity * Double(oc[frameIdx]))
                }
                // Per-window seed → any caller computing window b gets
                // identical phases, wherever the range boundaries fall.
                var rng = FastRNG(seed: blockSeed(seed, b))
                // Window 0 has no predecessor, so it stays fully random.
                var prevRng: FastRNG? = (phaseContinuity > 0 && b > 0)
                    ? FastRNG(seed: blockSeed(seed, b - 1)) : nil
                randomizePhases(realL, imagL, windowSize, effRandomness, &rng, &prevRng, phaseContinuity)
                randomizePhases(realR, imagR, windowSize, effRandomness, &rng, &prevRng, phaseContinuity)

                if doPitch {
                    pitchShiftBins(realL, imagL, windowSize, pitchFactor, tmpR, tmpI)
                    pitchShiftBins(realR, imagR, windowSize, pitchFactor, tmpR, tmpI)
                }

                ft.inverse(realL, imagL)
                ft.inverse(realR, imagR)

                // Overlap-add clipped to [rangeStart, rangeEnd) → race-free
                // under any partitioning.
                var i = max(0, rangeStart - outputPos)
                let iEnd = min(windowSize, rangeEnd - outputPos)
                while i < iEnd {
                    let dest = outputPos + i
                    let ww = win[i]
                    outL[dest - rangeStart] += realL[i] * ww
                    outR[dest - rangeStart] += realR[i] * ww
                    i += 1
                }

                localDone += 1
                if localDone & 63 == 0 { onBlocksDone?(64) }
            }
        }}}
    }

    /// Renders `[rangeStart, rangeEnd)` split across CPU cores.
    ///
    /// The range is partitioned into contiguous segments, one per worker;
    /// each worker owns a disjoint slice of the output (no locks) and
    /// processes every window overlapping it. Because windows are seeded
    /// individually, boundary windows computed by two workers come out
    /// identical, and the assembled result matches a single-threaded render
    /// bit for bit.
    func renderRangeParallel(_ rangeStart: Int,
                             _ rangeEnd: Int,
                             outL: UnsafeMutablePointer<Float>,
                             outR: UnsafeMutablePointer<Float>,
                             isCancelled: () -> Bool,
                             onBlocksDone: ((Int) -> Void)?) {
        let len = rangeEnd - rangeStart
        guard len > 0 else { return }
        let cores = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        let numWorkers = max(1, min(cores, len / max(1, windowSize * 2) + 1))
        let segLen = (len + numWorkers - 1) / numWorkers

        DispatchQueue.concurrentPerform(iterations: numWorkers) { w in
            let segStart = rangeStart + w * segLen
            if segStart >= rangeEnd { return }
            let segEnd = min(rangeEnd, segStart + segLen)
            renderRange(segStart, segEnd,
                        outL: outL + (segStart - rangeStart),
                        outR: outR + (segStart - rangeStart),
                        isCancelled: isCancelled,
                        onBlocksDone: onBlocksDone)
        }
    }
}
