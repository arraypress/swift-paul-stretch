//
//  GranularKernel.swift
//  SwiftPaulStretch
//
//  Granular cloud synthesis: dense Hann-windowed grains scattered from a
//  scrub position that advances through the source. Fully range-renderable
//  (every grain is a pure function of its index), like the other kernels.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// Precomputed state for a granular cloud pass.
///
/// Grains are laid on the output timeline at a fixed spacing
/// (`grainFrames / density`); each grain's source position, pitch and pan
/// come from a splitmix64-mixed per-grain seed, so any output range can be
/// rendered independently and bit-identically — the same invariant that
/// powers the multicore, chunked and realtime paths everywhere else in the
/// library.
struct GranularKernel {
    let inL: [Float]
    let inR: [Float]
    let inputLen: Int
    let sampleRate: Double
    /// The cloud's total length in frames (grains stop being scheduled here).
    let outputLength: Int
    let grainFrames: Int
    /// Frames between grain onsets (`grainFrames / density`).
    let spacing: Double
    /// Random source-position offset, in frames.
    let jitterFrames: Double
    /// Random per-grain pitch, in ± semitones.
    let pitchSpread: Double
    /// Pitch applied to every grain, in semitones.
    let basePitch: Double
    /// Random per-grain stereo position, `0…1`.
    let panSpread: Double
    let seed: UInt64
    /// Hann envelope, one grain long.
    let envelope: [Float]

    /// The number of grains a full render schedules (progress accounting).
    var totalGrains: Int { Int(Double(outputLength) / spacing) + 1 }

    init(input: StereoBuffer,
         outputLength: Int,
         grainSeconds: Double,
         density: Double,
         positionJitter: Double,
         pitchSpread: Double,
         basePitch: Double,
         panSpread: Double,
         seed: UInt64) {
        let sr = input.sampleRate
        self.inL = input.l
        self.inR = input.r
        self.inputLen = input.frameCount
        self.sampleRate = sr
        self.outputLength = outputLength
        self.grainFrames = max(64, Int(max(0.005, grainSeconds) * sr))
        self.spacing = Double(grainFrames) / max(1, density)
        self.jitterFrames = min(max(positionJitter, 0), 1) * Double(input.frameCount)
        self.pitchSpread = max(0, pitchSpread)
        self.basePitch = basePitch
        self.panSpread = min(max(panSpread, 0), 1)
        self.seed = seed

        var env = [Float](repeating: 0, count: grainFrames)
        for i in 0..<grainFrames {
            env[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(grainFrames - 1)))
        }
        self.envelope = env
    }

    /// Renders output frames `[rangeStart, rangeEnd)` into local buffers
    /// whose index `0` is absolute frame `rangeStart`.
    ///
    /// Same contract as the other kernels: contributions are **added** into
    /// zeroed buffers, grains are processed in ascending index order clipped
    /// to the range, so the result is independent of partitioning.
    func renderRange(_ rangeStart: Int,
                     _ rangeEnd: Int,
                     outL: UnsafeMutablePointer<Float>,
                     outR: UnsafeMutablePointer<Float>,
                     isCancelled: () -> Bool,
                     onGrainsDone: ((Int) -> Void)?) {
        guard rangeEnd > rangeStart, inputLen > 0 else { return }

        inL.withUnsafeBufferPointer { lp in
        inR.withUnsafeBufferPointer { rp in
        envelope.withUnsafeBufferPointer { ep in
            let srcL = lp.baseAddress!
            let srcR = rp.baseAddress!
            let env = ep.baseAddress!

            var g = max(0, Int((Double(rangeStart) - Double(grainFrames)) / spacing))
            var localDone = 0
            while true {
                let onset = Int(Double(g) * spacing)
                if onset >= rangeEnd || onset >= outputLength { break }
                if (g & 255) == 0 && isCancelled() { return }

                if onset + grainFrames > rangeStart {
                    // Per-grain randomness — fixed draw order: jitter, pitch, pan.
                    var rng = FastRNG(seed: blockSeed(seed, g))
                    let jitter = (rng.unit() * 2 - 1) * jitterFrames
                    let pitch = basePitch + (rng.unit() * 2 - 1) * pitchSpread
                    let pan = 0.5 + (rng.unit() * 2 - 1) * panSpread * 0.5
                    let rate = pow(2.0, pitch / 12.0)
                    let gainL = Float(cos(pan * Double.pi / 2))
                    let gainR = Float(sin(pan * Double.pi / 2))

                    // Scrub position advances through the source over the
                    // cloud; the grain is centred there (rate-compensated).
                    let scrub = outputLength > 1
                        ? Double(onset) / Double(outputLength) : 0
                    let srcCenter = scrub * Double(max(0, inputLen - 1)) + jitter
                    let srcStart = srcCenter - Double(grainFrames) * rate * 0.5

                    var i = max(0, rangeStart - onset)
                    let iEnd = min(grainFrames, rangeEnd - onset)
                    while i < iEnd {
                        let sp = srcStart + Double(i) * rate
                        let s0 = Int(sp.rounded(.down))
                        if s0 >= 0 && s0 < inputLen {
                            let frac = Float(sp - Double(s0))
                            let s1 = min(s0 + 1, inputLen - 1)
                            let e = env[i]
                            let vL = (srcL[s0] * (1 - frac) + srcL[s1] * frac) * e
                            let vR = (srcR[s0] * (1 - frac) + srcR[s1] * frac) * e
                            let dest = onset + i - rangeStart
                            outL[dest] += vL * gainL
                            outR[dest] += vR * gainR
                        }
                        i += 1
                    }

                    localDone += 1
                    if localDone & 255 == 0 { onGrainsDone?(256) }
                }
                g += 1
            }
        }}}
    }

    /// Renders `[rangeStart, rangeEnd)` split across CPU cores, with the
    /// same disjoint-segment strategy as the other kernels.
    func renderRangeParallel(_ rangeStart: Int,
                             _ rangeEnd: Int,
                             outL: UnsafeMutablePointer<Float>,
                             outR: UnsafeMutablePointer<Float>,
                             isCancelled: () -> Bool,
                             onGrainsDone: ((Int) -> Void)?) {
        let len = rangeEnd - rangeStart
        guard len > 0 else { return }
        let cores = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        let numWorkers = max(1, min(cores, len / max(1, grainFrames * 2) + 1))
        let segLen = (len + numWorkers - 1) / numWorkers

        DispatchQueue.concurrentPerform(iterations: numWorkers) { w in
            let segStart = rangeStart + w * segLen
            if segStart >= rangeEnd { return }
            let segEnd = min(rangeEnd, segStart + segLen)
            renderRange(segStart, segEnd,
                        outL: outL + (segStart - rangeStart),
                        outR: outR + (segStart - rangeStart),
                        isCancelled: isCancelled,
                        onGrainsDone: onGrainsDone)
        }
    }
}
