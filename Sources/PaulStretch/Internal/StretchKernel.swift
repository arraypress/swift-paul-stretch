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
private func randomizePhases(_ real: UnsafeMutablePointer<Float>,
                             _ imag: UnsafeMutablePointer<Float>,
                             _ n: Int,
                             _ amount: Double,
                             _ rng: inout FastRNG) {
    let half = n >> 1
    if amount >= 1 {
        for k in 1..<half {
            let re = Double(real[k]); let im = Double(imag[k])
            let mag = (re * re + im * im).squareRoot()
            let angle = rng.unit() * 2 * .pi
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
         seed: UInt64) {
        let sr = input.sampleRate
        self.inL = input.l
        self.inR = input.r
        self.inputLen = input.frameCount
        self.phaseRandomness = min(max(phaseRandomness, 0), 1)
        self.onsetSensitivity = min(max(onsetSensitivity, 0), 1)
        self.pitchFactor = pow(2.0, pitchSemitones / 12.0)
        self.doPitch = abs(pitchFactor - 1) > 0.001
        self.seed = seed

        let windowSize = nextPow2(Int(windowSeconds * sr))
        self.windowSize = windowSize
        self.halfWindow = windowSize >> 1
        self.outputStride = (windowSize >> 1) >> 1
        self.inputStride = Double((windowSize >> 1) >> 1) / ratio
        self.outputLength = max(windowSize, Int(Double(input.frameCount) * ratio))
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
                let inputStart = Int(Double(b) * inputStride)

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
                randomizePhases(realL, imagL, windowSize, effRandomness, &rng)
                randomizePhases(realR, imagR, windowSize, effRandomness, &rng)

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
