//
//  PhaseVocoder.swift
//  SwiftPaulStretch
//
//  Classic phase-vocoder time stretch: phases are propagated between
//  windows (per-bin instantaneous-frequency estimation) instead of
//  randomised, preserving the source's structure. Phase accumulation makes
//  the algorithm inherently sequential, so it renders through stateful
//  streams rather than random-access ranges.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import Accelerate

/// Geometry and input for a phase-vocoder pass — the same STFT geometry as
/// ``StretchKernel`` (4× Hann overlap, `hop = W/4`, fractional input
/// stride), but windows keep coherent, propagated phases.
struct PVSpec {
    let inL: [Float]
    let inR: [Float]
    let inputLen: Int
    let sampleRate: Double
    let windowSize: Int
    let half: Int
    /// Synthesis hop (`windowSize / 4`).
    let outputStride: Int
    /// Analysis hop (`outputStride / ratio`, fractional).
    let inputStride: Double
    let outputLength: Int
    let lastBlock: Int
    let hann: [Float]
    let pitchFactor: Double
    let doPitch: Bool

    init(input: StereoBuffer,
         ratio: Double,
         windowSeconds: Double,
         pitchSemitones: Double) {
        let sr = input.sampleRate
        self.inL = input.l
        self.inR = input.r
        self.inputLen = input.frameCount
        self.sampleRate = sr
        let windowSize = nextPow2(Int(windowSeconds * sr))
        self.windowSize = windowSize
        self.half = windowSize >> 1
        self.outputStride = (windowSize >> 1) >> 1
        self.inputStride = Double((windowSize >> 1) >> 1) / ratio
        self.outputLength = max(windowSize, Int(Double(input.frameCount) * ratio))
        self.lastBlock = (outputLength - (windowSize >> 1) - 1) / ((windowSize >> 1) >> 1)
        self.pitchFactor = pow(2.0, pitchSemitones / 12.0)
        self.doPitch = abs(pitchFactor - 1) > 0.001

        var hann = [Float](repeating: 0, count: windowSize)
        for i in 0..<windowSize {
            hann[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(windowSize - 1)))
        }
        self.hann = hann
    }

    /// A fresh sequential renderer positioned at output frame 0.
    func makeStream() -> PVStream? { PVStream(spec: self) }
}

/// A stateful, strictly-sequential phase-vocoder renderer.
///
/// Emits the output timeline front to back; the accumulated output phases
/// and the previous window's input phases are the state. Two streams over
/// the same spec produce identical samples, so passes (peak scan, delivery,
/// loop-tail) each run their own stream and stay bit-consistent.
final class PVStream {
    private let spec: PVSpec
    private let ft: PSFFT

    /// Next window to process.
    private var b = 0
    /// Absolute output frames handed to the caller so far.
    private(set) var position = 0
    /// OLA accumulator covering `[b·hop, b·hop + windowSize)`.
    private var accL: [Float]
    private var accR: [Float]
    /// Frames of `acc` already emitted (within the current front hop).
    private var accEmitted = 0
    private var prevInputStart = 0
    private var prevPhaseL: [Double]
    private var prevPhaseR: [Double]
    private var outPhaseL: [Double]
    private var outPhaseR: [Double]

    // FFT scratch.
    private let realL, imagL, realR, imagR, tmpR, tmpI: UnsafeMutablePointer<Float>

    init?(spec: PVSpec) {
        guard let ft = PSFFT(n: spec.windowSize) else { return nil }
        self.spec = spec
        self.ft = ft
        self.accL = [Float](repeating: 0, count: spec.windowSize)
        self.accR = [Float](repeating: 0, count: spec.windowSize)
        self.prevPhaseL = [Double](repeating: 0, count: spec.half + 1)
        self.prevPhaseR = [Double](repeating: 0, count: spec.half + 1)
        self.outPhaseL = [Double](repeating: 0, count: spec.half + 1)
        self.outPhaseR = [Double](repeating: 0, count: spec.half + 1)
        self.realL = .allocate(capacity: spec.windowSize)
        self.imagL = .allocate(capacity: spec.windowSize)
        self.realR = .allocate(capacity: spec.windowSize)
        self.imagR = .allocate(capacity: spec.windowSize)
        self.tmpR = .allocate(capacity: spec.windowSize)
        self.tmpI = .allocate(capacity: spec.windowSize)
    }

    deinit {
        realL.deallocate(); imagL.deallocate()
        realR.deallocate(); imagR.deallocate()
        tmpR.deallocate(); tmpI.deallocate()
    }

    /// Wraps an angle to (−π, π].
    @inline(__always)
    private func princarg(_ x: Double) -> Double {
        var a = x.truncatingRemainder(dividingBy: 2 * Double.pi)
        if a > Double.pi { a -= 2 * Double.pi }
        if a <= -Double.pi { a += 2 * Double.pi }
        return a
    }

    /// Processes window `b`: analyse → propagate phases → resynthesise →
    /// overlap-add into the front of the accumulator.
    private func processBlock() {
        let W = spec.windowSize
        let half = spec.half
        let hop = spec.outputStride
        let inputStart = Int(Double(b) * spec.inputStride)

        spec.inL.withUnsafeBufferPointer { lp in
            spec.inR.withUnsafeBufferPointer { rp in
                spec.hann.withUnsafeBufferPointer { hp in
                    let srcL = lp.baseAddress!, srcR = rp.baseAddress!, win = hp.baseAddress!
                    for i in 0..<W {
                        let idx = inputStart + i
                        let w = win[i]
                        if idx >= 0 && idx < spec.inputLen {
                            realL[i] = srcL[idx] * w; realR[i] = srcR[idx] * w
                        } else {
                            realL[i] = 0; realR[i] = 0
                        }
                        imagL[i] = 0; imagR[i] = 0
                    }
                }
            }
        }
        ft.forward(realL, imagL)
        ft.forward(realR, imagR)

        // The actual analysis hop this window advanced by (integer, may be
        // 0 at extreme ratios — then only the expected phase advance applies).
        let haActual = Double(inputStart - prevInputStart)
        let first = (b == 0)

        for k in 0...half {
            let omega = 2 * Double.pi * Double(k) / Double(W)          // rad/sample
            let expectedOut = omega * Double(hop)                      // per synthesis hop

            let reL = Double(realL[k]), imL = Double(imagL[k])
            let magL = (reL * reL + imL * imL).squareRoot()
            let phL = atan2(imL, reL)
            let reR = Double(realR[k]), imR = Double(imagR[k])
            let magR = (reR * reR + imR * imR).squareRoot()
            let phR = atan2(imR, reR)

            if first {
                outPhaseL[k] = phL
                outPhaseR[k] = phR
            } else if haActual > 0 {
                let expectedIn = omega * haActual
                let dL = princarg(phL - prevPhaseL[k] - expectedIn)
                let dR = princarg(phR - prevPhaseR[k] - expectedIn)
                let scale = Double(hop) / haActual
                outPhaseL[k] = princarg(outPhaseL[k] + (expectedIn + dL) * scale)
                outPhaseR[k] = princarg(outPhaseR[k] + (expectedIn + dR) * scale)
            } else {
                outPhaseL[k] = princarg(outPhaseL[k] + expectedOut)
                outPhaseR[k] = princarg(outPhaseR[k] + expectedOut)
            }
            prevPhaseL[k] = phL
            prevPhaseR[k] = phR

            // Resynthesise the bin (conjugate-mirrored for a real IFFT).
            let rvL = Float(magL * cos(outPhaseL[k])), ivL = Float(magL * sin(outPhaseL[k]))
            let rvR = Float(magR * cos(outPhaseR[k])), ivR = Float(magR * sin(outPhaseR[k]))
            if k == 0 || k == half {
                realL[k] = rvL; imagL[k] = 0
                realR[k] = rvR; imagR[k] = 0
            } else {
                realL[k] = rvL; imagL[k] = ivL
                realL[W - k] = rvL; imagL[W - k] = -ivL
                realR[k] = rvR; imagR[k] = ivR
                realR[W - k] = rvR; imagR[W - k] = -ivR
            }
        }
        prevInputStart = inputStart

        if spec.doPitch {
            pvPitchShiftBins(realL, imagL, W, spec.pitchFactor, tmpR, tmpI)
            pvPitchShiftBins(realR, imagR, W, spec.pitchFactor, tmpR, tmpI)
        }

        ft.inverse(realL, imagL)
        ft.inverse(realR, imagR)

        // Overlap-add: window b spans [b·hop, b·hop + W); the accumulator's
        // index 0 is b·hop (everything earlier has been shifted out).
        accL.withUnsafeMutableBufferPointer { alp in
            accR.withUnsafeMutableBufferPointer { arp in
                spec.hann.withUnsafeBufferPointer { hp in
                    let aL = alp.baseAddress!, aR = arp.baseAddress!, win = hp.baseAddress!
                    for i in 0..<W {
                        aL[i] += realL[i] * win[i]
                        aR[i] += realR[i] * win[i]
                    }
                }
            }
        }
        b += 1
    }

    /// Shifts the accumulator forward one hop (its front hop has been
    /// fully emitted).
    private func shiftAccumulator() {
        let W = spec.windowSize
        let hop = spec.outputStride
        accL.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress!
            base.update(from: base + hop, count: W - hop)
            (base + (W - hop)).update(repeating: 0, count: hop)
        }
        accR.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress!
            base.update(from: base + hop, count: W - hop)
            (base + (W - hop)).update(repeating: 0, count: hop)
        }
        accEmitted = 0
    }

    /// Emits exactly `count` sequential output frames (zeros past the end
    /// of the timeline). Returns `false` if cancelled.
    @discardableResult
    func render(into outL: UnsafeMutablePointer<Float>,
                _ outR: UnsafeMutablePointer<Float>,
                count: Int,
                isCancelled: () -> Bool = { false }) -> Bool {
        let hop = spec.outputStride
        var produced = 0
        while produced < count {
            if isCancelled() { return false }
            if position >= spec.outputLength {
                // Past the end: silence.
                let n = count - produced
                (outL + produced).update(repeating: 0, count: n)
                (outR + produced).update(repeating: 0, count: n)
                produced += n
                break
            }
            // The front hop of the accumulator is final once window b
            // (starting at b·hop) has been processed past it.
            let frontEnd = b * hop
            if position < frontEnd || b > spec.lastBlock {
                // Emit from the accumulator front.
                let hopAvail = (b > spec.lastBlock)
                    ? spec.outputLength - position
                    : min(hop - accEmitted, frontEnd - position)
                let n = min(count - produced, hopAvail)
                accL.withUnsafeBufferPointer { p in
                    (outL + produced).update(from: p.baseAddress! + accEmitted, count: n)
                }
                accR.withUnsafeBufferPointer { p in
                    (outR + produced).update(from: p.baseAddress! + accEmitted, count: n)
                }
                produced += n
                position += n
                accEmitted += n
                if accEmitted == hop && b <= spec.lastBlock {
                    shiftAccumulator()
                }
            } else {
                processBlock()
            }
        }
        return true
    }

    /// Discards `count` sequential frames (used to fast-forward a stream to
    /// a later timeline position).
    @discardableResult
    func skip(_ count: Int, isCancelled: () -> Bool = { false }) -> Bool {
        guard count > 0 else { return true }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 65536)
        defer { scratch.deallocate() }
        var remaining = count
        while remaining > 0 {
            if isCancelled() { return false }
            let n = min(65536, remaining)
            if !render(into: scratch, scratch, count: n, isCancelled: isCancelled) { return false }
            remaining -= n
        }
        return true
    }
}

/// FFT-domain pitch shift (identical math to the PaulStretch kernel's,
/// duplicated here because that one is file-private).
private func pvPitchShiftBins(_ real: UnsafeMutablePointer<Float>,
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
