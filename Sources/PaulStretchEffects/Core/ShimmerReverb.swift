//
//  ShimmerReverb.swift
//  SwiftPaulStretch
//
//  A shimmer reverb in pure Swift DSP: a Freeverb-style tank whose output
//  is pitch-shifted (crossfaded dual-tap transposer) and fed back into the
//  tank, so the wash climbs in octaves. Streaming, stateful, headless-safe.
//
//  The tank's delay lines live in flat, manually-managed buffers and the
//  per-sample crossfade gain comes from a complex-phasor recurrence rather
//  than a cos() call — this stage measured as the single most expensive
//  effect (scalar Swift, ~2.5x the convolution reverb), and the cost was
//  bounds/exclusivity checks on array-of-array delay lines plus transcendental
//  calls per sample, not the arithmetic itself.
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

    // Resolved parameters — slewed toward their targets per sample so a knob
    // move retunes the running tank instead of forcing a rebuild that would
    // truncate the bloom. Dry is derived from wet each sample so the pair
    // always sums to unity mid-glide.
    private var wet: Float
    private var dry: Float
    private var feedback: Float
    /// Slewed as a RATIO, not semitones: the ratio is the transposer's read
    /// speed, so easing it toward its target is a glide by construction.
    private var pitchRatio: Double
    private var combFeedback: Float
    private var damp: Float
    private var targetWet: Float
    private var targetFeedback: Float
    private var targetPitchRatio: Double
    private var targetCombFeedback: Float
    private var targetDamp: Float
    /// One-pole coefficients for the ~30 ms parameter slew.
    private let paramSlew: Float
    private let paramSlewD: Double

    // MARK: Freeverb tank (stereo: right channel detuned by a fixed spread)

    private static let combTunings = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allpassTunings = [556, 441, 341, 225]
    private static let stereoSpread = 23
    private static let fixedGain: Float = 0.03

    /// The tank's 12 delay lines per channel (8 combs then 4 allpasses),
    /// flattened into ONE manually-managed buffer per channel. The old
    /// array-of-arrays needed `&combL[c]` inout subscripts in the per-sample
    /// loop, and each one paid exclusivity + bounds checks; a flat pointer
    /// with precomputed offsets pays neither.
    private let tankL: UnsafeMutablePointer<Float>
    private let tankR: UnsafeMutablePointer<Float>
    /// Per-unit start offsets and lengths into the tank buffers (12 each:
    /// combs 0..7, allpasses 8..11), and the per-unit ring indices.
    private let offL: UnsafeMutablePointer<Int>
    private let lenL: UnsafeMutablePointer<Int>
    private let offR: UnsafeMutablePointer<Int>
    private let lenR: UnsafeMutablePointer<Int>
    private let idxL: UnsafeMutablePointer<Int>
    private let idxR: UnsafeMutablePointer<Int>
    /// Comb damping one-pole states (8 per channel).
    private let lpL: UnsafeMutablePointer<Float>
    private let lpR: UnsafeMutablePointer<Float>

    // MARK: Feedback climb pre-delay

    /// Delay line in the pitched feedback path — sets how long each octave
    /// step waits before re-entering the tank (`shimmerClimbSeconds`).
    private let climbL: UnsafeMutablePointer<Float>
    private let climbR: UnsafeMutablePointer<Float>
    private var climbIdx = 0
    private let climbFrames: Int

    // MARK: Pitch transposer (dual crossfaded taps over a ~93 ms window)

    private let psWindow: Int
    private let psL: UnsafeMutablePointer<Float>
    private let psR: UnsafeMutablePointer<Float>
    private var psWrite = 0
    private var psPhase = 0.0

    /// Crossfade-gain phasor: `gainC/gainS` hold cos/sin of the transposer's
    /// crossfade angle, advanced by the fixed per-sample rotation
    /// `rotC/rotS` while the pitch ratio is settled — two multiplies instead
    /// of a `cos()` per sample. Re-seeded from exact trig every
    /// `phasorResyncFrames` samples (float drift over that span is ~1e-13,
    /// far below audibility), and invalidated whenever the ratio is slewing
    /// (the rotation would be wrong, so those samples fall back to `cos()`).
    /// The resync counter is stream-persistent state, NOT per-chunk, so any
    /// chunking of the same stream stays bit-identical.
    private var gainC = 1.0
    private var gainS = 0.0
    private var rotC = 1.0
    private var rotS = 0.0
    private var phasorValid = false
    private var phasorAge = 0
    private let phasorResyncFrames = 4096

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
        self.targetWet = mix
        // Cap loop gain well below unity — the pitched feedback re-enters a
        // resonant tank, so stability headroom matters.
        let fb = min(max(fx.shimmerFeedback, 0), 100) / 100 * 0.8
        self.feedback = fb
        self.targetFeedback = fb
        let ratio = pow(2.0, Double(min(max(fx.shimmerPitch, -24), 24)) / 12.0)
        self.pitchRatio = ratio
        self.targetPitchRatio = ratio
        let comb = 0.78 + min(max(fx.shimmerSize, 0), 100) / 100 * 0.2
        self.combFeedback = comb
        self.targetCombFeedback = comb
        let dampVal = min(max(fx.shimmerDamping, 0), 100) / 100 * 0.6
        self.damp = dampVal
        self.targetDamp = dampVal
        // One-pole reaching ~63 % of a step in 30 ms.
        self.paramSlewD = 1 - exp(-1 / (0.03 * sampleRate))
        self.paramSlew = Float(paramSlewD)
        self.climbFrames = Int(Double(min(max(fx.shimmerClimbSeconds, 0), 8)) * sampleRate)
        let climbAlloc = max(1, climbFrames)
        self.climbL = .allocate(capacity: climbAlloc)
        self.climbR = .allocate(capacity: climbAlloc)
        climbL.initialize(repeating: 0, count: climbAlloc)
        climbR.initialize(repeating: 0, count: climbAlloc)

        // Lay the 12 delay lines out back-to-back per channel.
        var offsL = [Int](), lensL = [Int](), offsR = [Int](), lensR = [Int]()
        var totalL = 0, totalR = 0
        for t in Self.combTunings + Self.allpassTunings {
            let lL = max(2, Int(Double(t) * scale))
            let lR = max(2, Int(Double(t + Self.stereoSpread) * scale))
            offsL.append(totalL); lensL.append(lL); totalL += lL
            offsR.append(totalR); lensR.append(lR); totalR += lR
        }
        self.tankL = .allocate(capacity: totalL)
        self.tankR = .allocate(capacity: totalR)
        tankL.initialize(repeating: 0, count: totalL)
        tankR.initialize(repeating: 0, count: totalR)
        self.offL = .allocate(capacity: 12)
        self.lenL = .allocate(capacity: 12)
        self.offR = .allocate(capacity: 12)
        self.lenR = .allocate(capacity: 12)
        self.idxL = .allocate(capacity: 12)
        self.idxR = .allocate(capacity: 12)
        for u in 0..<12 {
            offL[u] = offsL[u]; lenL[u] = lensL[u]
            offR[u] = offsR[u]; lenR[u] = lensR[u]
            idxL[u] = 0; idxR[u] = 0
        }
        self.lpL = .allocate(capacity: 8)
        self.lpR = .allocate(capacity: 8)
        lpL.initialize(repeating: 0, count: 8)
        lpR.initialize(repeating: 0, count: 8)

        self.psWindow = max(1024, nextPowerOfTwo(Int(0.093 * sampleRate)))
        self.psL = .allocate(capacity: psWindow)
        self.psR = .allocate(capacity: psWindow)
        psL.initialize(repeating: 0, count: psWindow)
        psR.initialize(repeating: 0, count: psWindow)
    }

    deinit {
        tankL.deallocate(); tankR.deallocate()
        offL.deallocate(); lenL.deallocate(); offR.deallocate(); lenR.deallocate()
        idxL.deallocate(); idxR.deallocate()
        lpL.deallocate(); lpR.deallocate()
        climbL.deallocate(); climbR.deallocate()
        psL.deallocate(); psR.deallocate()
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
        guard n > 0 else { return (outL, outR) }
        let mask = psWindow - 1
        let winD = Double(psWindow)
        let halfWin = winD / 2
        let thetaScale = 2 * Double.pi / winD

        // Hoist all mutable state into locals for the hot loop — property
        // access through `self` re-checks exclusivity per touch; locals
        // don't. Written back below.
        var wet = self.wet, dry = self.dry, feedback = self.feedback
        var combFeedback = self.combFeedback, damp = self.damp
        var pitchRatio = self.pitchRatio
        var psPhase = self.psPhase, psWrite = self.psWrite
        var climbIdx = self.climbIdx
        var gainC = self.gainC, gainS = self.gainS
        var rotC = self.rotC, rotS = self.rotS
        var phasorValid = self.phasorValid, phasorAge = self.phasorAge
        let targetWet = self.targetWet, targetFeedback = self.targetFeedback
        let targetCombFeedback = self.targetCombFeedback, targetDamp = self.targetDamp
        let targetPitchRatio = self.targetPitchRatio
        let paramSlew = self.paramSlew, paramSlewD = self.paramSlewD
        let climbFrames = self.climbFrames, phasorResyncFrames = self.phasorResyncFrames
        let tankL = self.tankL, tankR = self.tankR
        let offL = self.offL, lenL = self.lenL, offR = self.offR, lenR = self.lenR
        let idxL = self.idxL, idxR = self.idxR
        let lpL = self.lpL, lpR = self.lpR
        let climbL = self.climbL, climbR = self.climbR
        let psL = self.psL, psR = self.psR

        l.withUnsafeBufferPointer { lIn in
        r.withUnsafeBufferPointer { rIn in
        outL.withUnsafeMutableBufferPointer { oL in
        outR.withUnsafeMutableBufferPointer { oR in
            for i in 0..<n {
                // --- Chase the retune targets (a no-op once settled — the
                // adds land on their own values). The tank, transposer and
                // climb buffers are untouched, so the bloom rides through a
                // retune.
                wet += (targetWet - wet) * paramSlew
                dry = 1 - wet
                feedback += (targetFeedback - feedback) * paramSlew
                combFeedback += (targetCombFeedback - combFeedback) * paramSlew
                damp += (targetDamp - damp) * paramSlew
                if pitchRatio != targetPitchRatio {
                    pitchRatio += (targetPitchRatio - pitchRatio) * paramSlewD
                    // Snap when the one-pole has effectively landed — it
                    // only asymptotes on its own, and the fast crossfade
                    // path below needs a settled ratio to re-arm.
                    if abs(targetPitchRatio - pitchRatio) < 1e-12 {
                        pitchRatio = targetPitchRatio
                    }
                    phasorValid = false
                }

                // --- Pitch-shifted feedback: two taps crossfaded over the
                // window. (A 4-tap variant was tried and measurably DILUTED
                // the octave bloom — three simultaneously-active taps
                // comb-filter the pitched content. The real upgrade here is
                // a grain-based shifter; until then the dual-tap's character
                // stands.)
                psPhase += 1 - pitchRatio
                psPhase -= winD * (psPhase / winD).rounded(.down)
                let dA = psPhase
                var dB = psPhase + halfWin
                if dB >= winD { dB -= winD }
                // Raised-cosine crossfade gain, via the phasor recurrence
                // while the ratio is settled, exact cos() while it slews.
                let gA: Float
                if phasorValid {
                    if phasorAge >= phasorResyncFrames {
                        gainC = cos(thetaScale * psPhase)
                        gainS = sin(thetaScale * psPhase)
                        phasorAge = 0
                    } else {
                        let c = gainC * rotC - gainS * rotS
                        let s = gainS * rotC + gainC * rotS
                        gainC = c; gainS = s
                        phasorAge += 1
                    }
                    gA = Float(0.5 - 0.5 * gainC)
                } else {
                    gA = Float(0.5 - 0.5 * cos(thetaScale * dA))
                    if pitchRatio == targetPitchRatio {
                        // Settled: seed the phasor at the current angle and
                        // precompute the per-sample rotation.
                        let delta = thetaScale * (1 - pitchRatio)
                        rotC = cos(delta); rotS = sin(delta)
                        gainC = cos(thetaScale * psPhase)
                        gainS = sin(thetaScale * psPhase)
                        phasorAge = 0
                        phasorValid = true
                    }
                }
                let gB = 1 - gA
                var shiftedL = tapRead(psL, delay: dA, mask: mask, write: psWrite) * gA
                             + tapRead(psL, delay: dB, mask: mask, write: psWrite) * gB
                var shiftedR = tapRead(psR, delay: dA, mask: mask, write: psWrite) * gA
                             + tapRead(psR, delay: dB, mask: mask, write: psWrite) * gB

                // --- Climb pre-delay: hold each pitched pass back so the
                // bloom steps up at a controlled rate instead of instantly.
                if climbFrames > 0 {
                    let delayedL = climbL[climbIdx]
                    let delayedR = climbR[climbIdx]
                    climbL[climbIdx] = shiftedL
                    climbR[climbIdx] = shiftedR
                    climbIdx += 1
                    if climbIdx >= climbFrames { climbIdx = 0 }
                    shiftedL = delayedL
                    shiftedR = delayedR
                }

                // --- Tank input: dry mono + soft-clipped pitched feedback.
                let fbSig = tanhf((shiftedL + shiftedR) * 0.5 * feedback)
                let tankIn = (lIn[i] + rIn[i]) * 0.5 * Self.fixedGain + fbSig * Self.fixedGain

                // --- Freeverb: 8 parallel damped combs, 4 series allpasses,
                // inlined against the flat tank buffers.
                var revL: Float = 0
                var revR: Float = 0
                for c in 0..<8 {
                    let baseL = tankL + offL[c]
                    var iL = idxL[c]
                    let outCL = baseL[iL]
                    let lpNewL = outCL * (1 - damp) + lpL[c] * damp
                    lpL[c] = lpNewL
                    baseL[iL] = tankIn + lpNewL * combFeedback
                    iL += 1
                    if iL >= lenL[c] { iL = 0 }
                    idxL[c] = iL
                    revL += outCL

                    let baseR = tankR + offR[c]
                    var iR = idxR[c]
                    let outCR = baseR[iR]
                    let lpNewR = outCR * (1 - damp) + lpR[c] * damp
                    lpR[c] = lpNewR
                    baseR[iR] = tankIn + lpNewR * combFeedback
                    iR += 1
                    if iR >= lenR[c] { iR = 0 }
                    idxR[c] = iR
                    revR += outCR
                }
                for a in 8..<12 {
                    let baseL = tankL + offL[a]
                    var iL = idxL[a]
                    let bufOutL = baseL[iL]
                    baseL[iL] = revL + bufOutL * 0.5
                    iL += 1
                    if iL >= lenL[a] { iL = 0 }
                    idxL[a] = iL
                    revL = bufOutL - revL

                    let baseR = tankR + offR[a]
                    var iR = idxR[a]
                    let bufOutR = baseR[iR]
                    baseR[iR] = revR + bufOutR * 0.5
                    iR += 1
                    if iR >= lenR[a] { iR = 0 }
                    idxR[a] = iR
                    revR = bufOutR - revR
                }

                // --- Feed the tank's output into the transposer for next
                // passes.
                psL[psWrite] = revL
                psR[psWrite] = revR
                psWrite = (psWrite + 1) & mask

                oL[i] = lIn[i] * dry + revL * wet
                oR[i] = rIn[i] * dry + revR * wet
            }
        }}}}

        self.wet = wet; self.dry = dry; self.feedback = feedback
        self.combFeedback = combFeedback; self.damp = damp
        self.pitchRatio = pitchRatio
        self.psPhase = psPhase; self.psWrite = psWrite
        self.climbIdx = climbIdx
        self.gainC = gainC; self.gainS = gainS
        self.rotC = rotC; self.rotS = rotS
        self.phasorValid = phasorValid; self.phasorAge = phasorAge
        return (outL, outR)
    }

    /// Renders the ring-out tail (``tailSeconds`` of the loop decaying with
    /// no input). Call once after the last ``process(l:r:)``.
    public func tail() -> (l: [Float], r: [Float]) {
        let n = Int(Self.tailSeconds * sampleRate)
        let zeros = [Float](repeating: 0, count: n)
        return process(l: zeros, r: zeros)
    }

    /// Retunes mix, feedback, pitch, size and damping in place — CLIMB
    /// SECONDS is structural (it sizes the pre-delay line) and is ignored
    /// here; changing it must rebuild the stage. Pitch becomes a ratio
    /// before slewing, so a semitone step arrives as a portamento in the
    /// transposer's read speed. Runs on the audio thread — plain stored
    /// writes only. Clamps match the initialiser's, including the 0.8
    /// feedback cap that keeps the pitched loop stable.
    func update(from fx: EffectsParameters) {
        targetWet = min(max(fx.shimmerMix, 0), 100) / 100
        targetFeedback = min(max(fx.shimmerFeedback, 0), 100) / 100 * 0.8
        targetPitchRatio = pow(2.0, Double(min(max(fx.shimmerPitch, -24), 24)) / 12.0)
        targetCombFeedback = 0.78 + min(max(fx.shimmerSize, 0), 100) / 100 * 0.2
        targetDamp = min(max(fx.shimmerDamping, 0), 100) / 100 * 0.6
    }

    // MARK: - Primitives

    @inline(__always)
    private func tapRead(_ buf: UnsafePointer<Float>, delay: Double, mask: Int, write: Int) -> Float {
        let d0 = Int(delay)
        let frac = Float(delay - Double(d0))
        let i0 = (write - 1 - d0) & mask
        let i1 = (i0 - 1) & mask
        return buf[i0] * (1 - frac) + buf[i1] * frac
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
