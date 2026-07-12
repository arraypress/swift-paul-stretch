//
//  ShimmerReverb.swift
//  SwiftPaulStretch
//
//  A shimmer reverb in pure Swift DSP: a Freeverb-style tank whose output
//  is pitch-shifted (crossfaded dual-tap transposer) and fed back into the
//  tank, so the wash climbs in octaves. Streaming, stateful, headless-safe.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// The classic "shimmer" reverb: `input → reverb tank → pitch-up →
/// feedback into the tank`, so each pass through the loop climbs another
/// interval and the tail blooms into an ethereal choir.
///
/// This is the library's own DSP (a Schroeder/Freeverb tank plus a
/// crossfaded dual-tap pitch transposer) rather than Apple audio units,
/// because `AVAudioEngine` graphs cannot contain the feedback cycle shimmer
/// requires. It processes chunks statefully, so it slots straight into the
/// baked/streamed export paths — see
/// ``EffectsBaker/bake(_:effects:)`` and ``StreamingEffectsBaker``, which
/// apply it automatically when ``EffectsParameters/shimmerEnabled`` is set.
///
/// ```swift
/// var fx = EffectsParameters()
/// fx.shimmerEnabled = true
/// fx.shimmerPitch = 12          // octave-up bloom
/// fx.shimmerFeedback = 55
/// let halo = EffectsBaker.bake(drone, effects: fx)
/// ```
public final class ShimmerReverb {

    /// The tail rendered after the input ends so the feedback bloom can
    /// ring out, in seconds.
    public static let tailSeconds = 8.0

    /// The stream's sample rate, in hertz.
    public let sampleRate: Double

    // Resolved parameters.
    private let wet: Float
    private let dry: Float
    private let feedback: Float
    private let pitchRatio: Double
    private let combFeedback: Float
    private let damp: Float

    // MARK: Freeverb tank (stereo: right channel detuned by a fixed spread)

    private static let combTunings = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allpassTunings = [556, 441, 341, 225]
    private static let stereoSpread = 23
    private static let fixedGain: Float = 0.03

    private var combL: [[Float]] = []
    private var combR: [[Float]] = []
    private var combIdxL = [Int](repeating: 0, count: 8)
    private var combIdxR = [Int](repeating: 0, count: 8)
    private var combLPL = [Float](repeating: 0, count: 8)
    private var combLPR = [Float](repeating: 0, count: 8)
    private var apL: [[Float]] = []
    private var apR: [[Float]] = []
    private var apIdxL = [Int](repeating: 0, count: 4)
    private var apIdxR = [Int](repeating: 0, count: 4)

    // MARK: Feedback climb pre-delay

    /// Delay line in the pitched feedback path — sets how long each octave
    /// step waits before re-entering the tank (`shimmerClimbSeconds`).
    private var climbBufL: [Float] = []
    private var climbBufR: [Float] = []
    private var climbIdx = 0
    private let climbFrames: Int

    // MARK: Pitch transposer (dual crossfaded taps over a ~93 ms window)

    private let psWindow: Int
    private var psBufL: [Float]
    private var psBufR: [Float]
    private var psWrite = 0
    private var psPhase = 0.0

    /// Creates a shimmer processor for a stream at `sampleRate`, resolving
    /// the `shimmer…` fields of `parameters` (tank tunings scale with the
    /// sample rate).
    ///
    /// - Parameters:
    ///   - sampleRate: The stream's sample rate, in hertz.
    ///   - parameters: The effect settings (only the shimmer fields are read).
    public init(sampleRate: Double, parameters fx: EffectsParameters) {
        self.sampleRate = sampleRate
        let scale = sampleRate / 44_100.0

        let mix = min(max(fx.shimmerMix, 0), 100) / 100
        self.wet = mix
        self.dry = 1 - mix
        // Cap loop gain well below unity — the pitched feedback re-enters a
        // resonant tank, so stability headroom matters.
        self.feedback = min(max(fx.shimmerFeedback, 0), 100) / 100 * 0.8
        self.pitchRatio = pow(2.0, Double(min(max(fx.shimmerPitch, -24), 24)) / 12.0)
        self.combFeedback = 0.78 + min(max(fx.shimmerSize, 0), 100) / 100 * 0.2
        self.damp = min(max(fx.shimmerDamping, 0), 100) / 100 * 0.6
        self.climbFrames = Int(Double(min(max(fx.shimmerClimbSeconds, 0), 8)) * sampleRate)
        if climbFrames > 0 {
            climbBufL = [Float](repeating: 0, count: climbFrames)
            climbBufR = [Float](repeating: 0, count: climbFrames)
        }

        for t in Self.combTunings {
            combL.append([Float](repeating: 0, count: max(2, Int(Double(t) * scale))))
            combR.append([Float](repeating: 0, count: max(2, Int(Double(t + Self.stereoSpread) * scale))))
        }
        for t in Self.allpassTunings {
            apL.append([Float](repeating: 0, count: max(2, Int(Double(t) * scale))))
            apR.append([Float](repeating: 0, count: max(2, Int(Double(t + Self.stereoSpread) * scale))))
        }

        self.psWindow = max(1024, nextPowerOfTwo(Int(0.093 * sampleRate)))
        self.psBufL = [Float](repeating: 0, count: psWindow)
        self.psBufR = [Float](repeating: 0, count: psWindow)
    }

    /// Runs one chunk through the shimmer and returns the same number of
    /// frames. Chunks must arrive in timeline order — tank and feedback
    /// state flow from one chunk into the next.
    ///
    /// - Parameters:
    ///   - l: Left-channel dry samples.
    ///   - r: Right-channel dry samples.
    /// - Returns: The wet chunk.
    public func process(l: [Float], r: [Float]) -> (l: [Float], r: [Float]) {
        let n = min(l.count, r.count)
        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        let mask = psWindow - 1

        for i in 0..<n {
            // --- Pitch-shifted feedback: two taps crossfaded over the
            // window. (A 4-tap variant was tried and measurably DILUTED the
            // octave bloom — three simultaneously-active taps comb-filter
            // the pitched content. The real upgrade here is a grain-based
            // shifter; until then the dual-tap's character stands.)
            psPhase += 1 - pitchRatio
            psPhase -= Double(psWindow) * (psPhase / Double(psWindow)).rounded(.down)
            let dA = psPhase
            var dB = psPhase + Double(psWindow) / 2
            if dB >= Double(psWindow) { dB -= Double(psWindow) }
            let gA = Float(0.5 - 0.5 * cos(2 * Double.pi * dA / Double(psWindow)))
            let gB = 1 - gA
            var shiftedL = tapRead(psBufL, delay: dA, mask: mask) * gA
                         + tapRead(psBufL, delay: dB, mask: mask) * gB
            var shiftedR = tapRead(psBufR, delay: dA, mask: mask) * gA
                         + tapRead(psBufR, delay: dB, mask: mask) * gB

            // --- Climb pre-delay: hold each pitched pass back so the bloom
            // steps up at a controlled rate instead of instantly.
            if climbFrames > 0 {
                let delayedL = climbBufL[climbIdx]
                let delayedR = climbBufR[climbIdx]
                climbBufL[climbIdx] = shiftedL
                climbBufR[climbIdx] = shiftedR
                climbIdx += 1
                if climbIdx >= climbFrames { climbIdx = 0 }
                shiftedL = delayedL
                shiftedR = delayedR
            }

            // --- Tank input: dry mono + soft-clipped pitched feedback.
            let fbSig = tanhf((shiftedL + shiftedR) * 0.5 * feedback)
            let tankIn = (l[i] + r[i]) * 0.5 * Self.fixedGain + fbSig * Self.fixedGain

            // --- Freeverb: 8 parallel damped combs, 4 series allpasses.
            var revL: Float = 0
            var revR: Float = 0
            for c in 0..<8 {
                revL += combStep(&combL[c], &combIdxL[c], &combLPL[c], tankIn)
                revR += combStep(&combR[c], &combIdxR[c], &combLPR[c], tankIn)
            }
            for a in 0..<4 {
                revL = allpassStep(&apL[a], &apIdxL[a], revL)
                revR = allpassStep(&apR[a], &apIdxR[a], revR)
            }

            // --- Feed the tank's output into the transposer for next passes.
            psBufL[psWrite] = revL
            psBufR[psWrite] = revR
            psWrite = (psWrite + 1) & mask

            outL[i] = l[i] * dry + revL * wet
            outR[i] = r[i] * dry + revR * wet
        }
        return (outL, outR)
    }

    /// Renders the ring-out tail (``tailSeconds`` of the loop decaying with
    /// no input). Call once after the last ``process(l:r:)``.
    public func tail() -> (l: [Float], r: [Float]) {
        let n = Int(Self.tailSeconds * sampleRate)
        let zeros = [Float](repeating: 0, count: n)
        return process(l: zeros, r: zeros)
    }

    // MARK: - Primitives

    @inline(__always)
    private func tapRead(_ buf: [Float], delay: Double, mask: Int) -> Float {
        let d0 = Int(delay)
        let frac = Float(delay - Double(d0))
        let i0 = (psWrite - 1 - d0) & mask
        let i1 = (i0 - 1) & mask
        return buf[i0] * (1 - frac) + buf[i1] * frac
    }

    @inline(__always)
    private func combStep(_ buf: inout [Float], _ idx: inout Int, _ lp: inout Float, _ input: Float) -> Float {
        let out = buf[idx]
        lp = out * (1 - damp) + lp * damp
        buf[idx] = input + lp * combFeedback
        idx += 1
        if idx >= buf.count { idx = 0 }
        return out
    }

    @inline(__always)
    private func allpassStep(_ buf: inout [Float], _ idx: inout Int, _ input: Float) -> Float {
        let bufOut = buf[idx]
        buf[idx] = input + bufOut * 0.5
        idx += 1
        if idx >= buf.count { idx = 0 }
        return bufOut - input
    }
}

/// The smallest power of two `>= x` (local helper — the core's `nextPow2`
/// is internal to the PaulStretch module).
private func nextPowerOfTwo(_ x: Int) -> Int {
    var n = 1
    while n < x { n <<= 1 }
    return n
}

#endif  // !os(watchOS)
