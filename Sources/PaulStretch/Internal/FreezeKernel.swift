//
//  FreezeKernel.swift
//  SwiftPaulStretch
//
//  The spectral-freeze inner loop: a magnitude spectrum captured once at
//  plan time, resynthesised with fresh random phase per hop for any output
//  frame range. Same range-render structure as StretchKernel.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import Accelerate

/// Precomputed state for a spectral freeze: the captured (optionally
/// smeared) magnitude spectrum, window and hop geometry, and the seed.
///
/// Rendering is pure resynthesis — every hop gets brand-new random phases
/// from its per-hop seed, so, exactly like ``StretchKernel``, any output
/// range can be rendered independently with bit-identical results.
struct FreezeKernel {
    let magL: [Float]
    let magR: [Float]
    let windowSize: Int
    let half: Int
    let hop: Int
    let outputLength: Int
    let lastBlock: Int
    let windowBlocks: Int
    let hann: [Float]
    let seed: UInt64

    /// The number of hops a full render processes (progress accounting).
    var totalBlocks: Int { lastBlock + 1 }

    /// Captures the magnitude spectrum of `input` at `positionNorm` and
    /// prepares resynthesis state, or returns `nil` when the input is too
    /// short to window (under 32 frames).
    ///
    /// - Parameters:
    ///   - input: The source to freeze.
    ///   - positionNorm: The capture point, `0…1` through the source.
    ///   - smear: Magnitude box-blur amount, `0…1` (radius ≈ `smear × 50`
    ///     bins — deliberately small so tonal peaks survive).
    ///   - targetSeconds: The duration to resynthesise.
    ///   - windowSeconds: The STFT window length, in seconds.
    ///   - seed: The render seed.
    init?(input: StereoBuffer,
          positionNorm: Double,
          smear: Double,
          targetSeconds: Double,
          windowSeconds: Double,
          seed: UInt64) {
        let sr = input.sampleRate
        let inputLen = input.frameCount
        if inputLen < 32 { return nil }

        let windowSize = nextPow2(Int(windowSeconds * sr))
        self.windowSize = windowSize
        self.half = windowSize >> 1
        self.hop = windowSize >> 2
        self.outputLength = max(windowSize, Int(targetSeconds * sr))
        self.lastBlock = (outputLength - (windowSize >> 1) - 1) / (windowSize >> 2)
        self.windowBlocks = windowSize / (windowSize >> 2) + 1
        self.seed = seed

        var hann = [Float](repeating: 0, count: windowSize)
        for i in 0..<windowSize {
            hann[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(windowSize - 1)))
        }
        self.hann = hann

        // --- Capture the magnitude spectrum at positionNorm ---
        let center = Int(positionNorm * Double(max(0, inputLen - windowSize)))
        var magL = [Float](repeating: 0, count: windowSize)
        var magR = [Float](repeating: 0, count: windowSize)
        if let ft = PSFFT(n: windowSize) {
            var rL = [Float](repeating: 0, count: windowSize), iL = [Float](repeating: 0, count: windowSize)
            var rR = [Float](repeating: 0, count: windowSize), iR = [Float](repeating: 0, count: windowSize)
            for i in 0..<windowSize {
                let idx = center + i
                let w = hann[i]
                if idx >= 0 && idx < inputLen { rL[i] = input.l[idx] * w; rR[i] = input.r[idx] * w }
            }
            rL.withUnsafeMutableBufferPointer { rp in iL.withUnsafeMutableBufferPointer { ip in ft.forward(rp.baseAddress!, ip.baseAddress!) } }
            rR.withUnsafeMutableBufferPointer { rp in iR.withUnsafeMutableBufferPointer { ip in ft.forward(rp.baseAddress!, ip.baseAddress!) } }
            for k in 0..<windowSize {
                magL[k] = (rL[k] * rL[k] + iL[k] * iL[k]).squareRoot()
                magR[k] = (rR[k] * rR[k] + iR[k] * iR[k]).squareRoot()
            }
        }
        if smear > 0.01 {
            // Gentle: a few bins at low smear (keeps tonal peaks), up to
            // ~50 bins at full smear (washy). A radius proportional to the
            // window would flatten the whole spectrum into white noise.
            let radius = max(1, Int(smear * 50))
            magL = boxBlur(magL, half: half, radius: radius)
            magR = boxBlur(magR, half: half, radius: radius)
        }
        self.magL = magL
        self.magR = magR
    }

    /// Resynthesises output frames `[rangeStart, rangeEnd)` into local
    /// buffers whose index `0` is absolute frame `rangeStart`.
    ///
    /// Same contract as ``StretchKernel/renderRange(_:_:outL:outR:isCancelled:onBlocksDone:)``:
    /// contributions are added into zeroed buffers, hops are processed in
    /// ascending order clipped to the range, and each hop's phases come from
    /// its own mixed seed — so the result is independent of partitioning.
    func renderRange(_ rangeStart: Int,
                     _ rangeEnd: Int,
                     outL: UnsafeMutablePointer<Float>,
                     outR: UnsafeMutablePointer<Float>,
                     isCancelled: () -> Bool,
                     onBlocksDone: ((Int) -> Void)?) {
        guard let ft = PSFFT(n: windowSize) else { return }
        let bStart = max(0, rangeStart / hop - windowBlocks)
        let bEnd = min(lastBlock, (rangeEnd - 1) / hop)
        if bStart > bEnd { return }

        let rL = UnsafeMutablePointer<Float>.allocate(capacity: windowSize)
        let iL = UnsafeMutablePointer<Float>.allocate(capacity: windowSize)
        let rR = UnsafeMutablePointer<Float>.allocate(capacity: windowSize)
        let iR = UnsafeMutablePointer<Float>.allocate(capacity: windowSize)
        defer { rL.deallocate(); iL.deallocate(); rR.deallocate(); iR.deallocate() }

        magL.withUnsafeBufferPointer { mLP in
        magR.withUnsafeBufferPointer { mRP in
        hann.withUnsafeBufferPointer { hP in
            let mL = mLP.baseAddress!, mR = mRP.baseAddress!, win = hP.baseAddress!

            var localDone = 0
            for b in bStart...bEnd {
                if (b & 63) == 0 && isCancelled() { return }
                let outputPos = b * hop
                // Fresh random phase per hop (seeded per-hop → partition-safe).
                var rng = FastRNG(seed: blockSeed(seed, b))
                rL[0] = mL[0]; iL[0] = 0; rR[0] = mR[0]; iR[0] = 0
                for k in 1..<half {
                    let aL = rng.unit() * 2 * Double.pi
                    let aR = rng.unit() * 2 * Double.pi
                    let vL = mL[k], vR = mR[k]
                    rL[k] = vL * Float(cos(aL)); iL[k] = vL * Float(sin(aL))
                    rR[k] = vR * Float(cos(aR)); iR[k] = vR * Float(sin(aR))
                    rL[windowSize - k] = rL[k]; iL[windowSize - k] = -iL[k]
                    rR[windowSize - k] = rR[k]; iR[windowSize - k] = -iR[k]
                }
                rL[half] = 0; iL[half] = 0; rR[half] = 0; iR[half] = 0
                ft.inverse(rL, iL)
                ft.inverse(rR, iR)

                var i = max(0, rangeStart - outputPos)
                let iEnd = min(windowSize, rangeEnd - outputPos)
                while i < iEnd {
                    let dest = outputPos + i
                    let ww = win[i]
                    outL[dest - rangeStart] += rL[i] * ww
                    outR[dest - rangeStart] += rR[i] * ww
                    i += 1
                }

                localDone += 1
                if localDone & 63 == 0 { onBlocksDone?(64) }
            }
        }}}
    }

    /// Resynthesises `[rangeStart, rangeEnd)` split across CPU cores, with
    /// the same disjoint-segment strategy as
    /// ``StretchKernel/renderRangeParallel(_:_:outL:outR:isCancelled:onBlocksDone:)``.
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

/// Moving-average blur of the lower-half magnitude spectrum (washes tonal
/// peaks toward noise).
private func boxBlur(_ a: [Float], half: Int, radius: Int) -> [Float] {
    var out = a
    for k in 1..<half {
        let lo = max(1, k - radius), hi = min(half - 1, k + radius)
        var s: Float = 0
        for j in lo...hi { s += a[j] }
        out[k] = s / Float(hi - lo + 1)
    }
    return out
}
