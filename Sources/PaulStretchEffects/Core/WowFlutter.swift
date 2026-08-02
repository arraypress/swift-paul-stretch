//
//  WowFlutter.swift
//  SwiftPaulStretch
//
//  Tape wow & flutter: slow pitch drift from transport-speed instability.
//  Fractional-delay read with a modulated delay centre — wow (~0.6 Hz,
//  ±0.5% pitch), flutter (10× rate, much smaller), plus a seeded random
//  drift so the wobble never repeats like a metronome.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// Tape wow & flutter — the gentle pitch instability of cassette and reel
/// transports.
///
/// A fractional-delay read pointer chases the write pointer at a slightly
/// varying distance: a slow sine (wow), a faster small sine at 10× the rate
/// (flutter), and a low-passed seeded noise walk (drift) so the wobble
/// stays organic. Left and right run phase-offset, like real tape. Reads
/// interpolate cubically (Catmull-Rom), which keeps highs cleaner than
/// linear interpolation under modulation.
///
/// Pairs beautifully with ``StretchMode/tapeSlow`` and the phase vocoder.
public final class WowFlutter: PureStage {

    private let sampleRate: Double
    /// Intensity, slewed toward `targetAmount` — it scales the modulation
    /// depths directly, so a stepped knob move would otherwise zipper.
    private var amount: Double
    private var targetAmount: Double
    /// Applied instantly on retune: the LFO phases accumulate incrementally,
    /// so a new rate only changes the increment — phase-continuous by
    /// construction.
    private var rateHz: Double
    /// One-pole coefficient for the ~30 ms parameter slew.
    private let paramSlew: Double
    private let amountLane: AutomationLane?
    private let rateLane: AutomationLane?
    private let totalFrames: Int?

    /// History ring (per channel) — the read pointer needs ~20 ms of past.
    private let ringSize: Int
    private var ringL: [Float]
    private var ringR: [Float]
    private var writeIdx = 0
    private var position = 0

    private let centreDelay: Double
    private let wowDepthBase: Double
    private let flutterDepthBase: Double
    private var phaseWowL = 0.0
    private var phaseWowR = 0.7          // small L/R offset — real tape drifts apart
    private var phaseFlutterL = 0.0
    private var phaseFlutterR = 1.3
    /// Seeded random-walk drift state (per channel).
    private var driftL = 0.0
    private var driftR = 0.0
    private var noiseState: UInt64 = 0x7E11_57AD_0BEE_F00D

    /// LFO phasors: sin/cos of each oscillator's phase, advanced by a
    /// complex rotation per sample instead of four `sin()` calls — those
    /// four transcendentals were most of this stage's cost. Only used when
    /// no rate lane is bound (a lane changes the increment every sample, so
    /// that path keeps the exact trig). Re-seeded from exact sin/cos every
    /// `phasorResyncFrames` samples; the counter is stream-persistent state
    /// so any chunking of the same stream stays bit-identical.
    private var sinWowL = 0.0, cosWowL = 1.0
    private var sinWowR = 0.0, cosWowR = 1.0
    private var sinFluL = 0.0, cosFluL = 1.0
    private var sinFluR = 0.0, cosFluR = 1.0
    private var phasorAge = 0
    private let phasorResyncFrames = 4096

    /// Creates a wow/flutter processor.
    ///
    /// - Parameters:
    ///   - sampleRate: The stream's sample rate, in hertz.
    ///   - amount: Intensity `0…1` — scales wow, flutter and drift together
    ///     (±0.5 % pitch deviation at `1`).
    ///   - rateHz: The wow rate (`0.05…8 Hz`); flutter runs at 10×.
    ///   - amountLane: Optional intensity automation (multiplies `amount`;
    ///     drives directly when `amount` is `0` so a "wow swells in" curve
    ///     works from silence).
    ///   - rateLane: Optional rate automation (`0…1` → `0.1…4 Hz`,
    ///     phase-integrated so sweeps never snap).
    ///   - totalFrames: The full dry length (the lanes' time base).
    public init(sampleRate: Double,
                amount: Float,
                rateHz: Float = 0.6,
                amountLane: AutomationLane? = nil,
                rateLane: AutomationLane? = nil,
                totalFrames: Int? = nil) {
        self.sampleRate = sampleRate
        let a = Double(min(max(amount, 0), 1))
        self.amount = a
        self.targetAmount = a
        self.rateHz = Double(min(max(rateHz, 0.05), 8))
        // One-pole reaching ~63 % of a step in 30 ms.
        self.paramSlew = 1 - exp(-1 / (0.03 * sampleRate))
        self.amountLane = amountLane
        self.rateLane = rateLane
        self.totalFrames = totalFrames
        self.centreDelay = sampleRate * 0.012          // 12 ms centre
        self.wowDepthBase = sampleRate * 0.005         // ±5 ms at full intensity
        self.flutterDepthBase = sampleRate * 0.0007    // ±0.7 ms at full intensity
        self.ringSize = 1 << Int(ceil(log2(sampleRate * 0.03 + 8)))
        self.ringL = [Float](repeating: 0, count: ringSize)
        self.ringR = [Float](repeating: 0, count: ringSize)
        // Seed the LFO phasors at the initial phases; a resync is forced on
        // the first processed sample anyway (phasorAge starts at the limit).
        self.sinWowL = sin(phaseWowL); self.cosWowL = cos(phaseWowL)
        self.sinWowR = sin(phaseWowR); self.cosWowR = cos(phaseWowR)
        self.sinFluL = sin(phaseFlutterL); self.cosFluL = cos(phaseFlutterL)
        self.sinFluR = sin(phaseFlutterR); self.cosFluR = cos(phaseFlutterR)
        self.phasorAge = phasorResyncFrames
    }

    @inline(__always)
    private func noise() -> Double {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 7
        noiseState ^= noiseState << 17
        return Double(noiseState >> 11) * (2.0 / 9007199254740992.0) - 1.0
    }

    @inline(__always)
    private func readCubic(_ ring: UnsafePointer<Float>, at readPos: Double, mask: Int) -> Float {
        let i1 = Int(readPos.rounded(.down))
        let frac = Float(readPos - Double(i1))
        let y0 = ring[(i1 - 1) & mask]
        let y1 = ring[i1 & mask]
        let y2 = ring[(i1 + 1) & mask]
        let y3 = ring[(i1 + 2) & mask]
        // Catmull-Rom cubic.
        let a = (y3 - y2) - (y0 - y1)
        let b = (y0 - y1) - a
        let c = y2 - y0
        return ((a * frac + b) * frac + c) * frac * 0.5 + y1
    }

    public func process(l: [Float], r: [Float]) -> (l: [Float], r: [Float]) {
        let n = min(l.count, r.count)
        let mask = ringSize - 1
        if amount <= 0 && targetAmount <= 0 && amountLane == nil {
            // Bypassed — but keep the history ring fed: a later retune reads
            // ~12 ms into the past, and an unfed ring would open with silence.
            for i in 0..<n {
                ringL[writeIdx & mask] = l[i]
                ringR[writeIdx & mask] = r[i]
                writeIdx += 1
            }
            position += n
            return (l: l, r: r)
        }
        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        let twoPiOverSr = 2 * Double.pi / sampleRate
        // Drift: one-pole low-passed noise, ~0.15 Hz corner.
        let driftAlpha = 1 - exp(-2 * Double.pi * 0.15 / sampleRate)

        // Hoist mutable state into locals — per-sample property access
        // through `self` pays an exclusivity check per touch. Written back
        // after the loop.
        var amount = self.amount
        var writeIdx = self.writeIdx
        var phaseWowL = self.phaseWowL, phaseWowR = self.phaseWowR
        var phaseFlutterL = self.phaseFlutterL, phaseFlutterR = self.phaseFlutterR
        var driftL = self.driftL, driftR = self.driftR
        var sinWowL = self.sinWowL, cosWowL = self.cosWowL
        var sinWowR = self.sinWowR, cosWowR = self.cosWowR
        var sinFluL = self.sinFluL, cosFluL = self.cosFluL
        var sinFluR = self.sinFluR, cosFluR = self.cosFluR
        var phasorAge = self.phasorAge
        let targetAmount = self.targetAmount
        let paramSlew = self.paramSlew
        let rateHz = self.rateHz
        let centreDelay = self.centreDelay
        let wowDepthBase = self.wowDepthBase
        let flutterDepthBase = self.flutterDepthBase
        let phasorResyncFrames = self.phasorResyncFrames
        var noiseState = self.noiseState
        // The rate is constant within a call when no lane drives it, so the
        // per-sample phasor rotation is a fixed complex multiply. (A bound
        // lane without a valid time base falls back to the static rate, just
        // as the original per-sample branch did.)
        let laneDrivesRate = rateLane != nil && (totalFrames ?? 0) > 1
        let usePhasors = !laneDrivesRate
        let wowInc = rateHz * twoPiOverSr
        let fluInc = rateHz * 10 * twoPiOverSr
        let cosWowInc = cos(wowInc), sinWowInc = sin(wowInc)
        let cosFluInc = cos(fluInc), sinFluInc = sin(fluInc)

        l.withUnsafeBufferPointer { lIn in
        r.withUnsafeBufferPointer { rIn in
        outL.withUnsafeMutableBufferPointer { oL in
        outR.withUnsafeMutableBufferPointer { oR in
        ringL.withUnsafeMutableBufferPointer { rgL in
        ringR.withUnsafeMutableBufferPointer { rgR in
        for i in 0..<n {
            let frame = position + i
            rgL[writeIdx & mask] = lIn[i]
            rgR[writeIdx & mask] = rIn[i]
            amount += (targetAmount - amount) * paramSlew
            let baseAmount = amount > 0 ? amount : 1

            let sWowL: Double, sWowR: Double, sFluL: Double, sFluR: Double
            if usePhasors {
                phaseWowL += wowInc
                phaseWowR += wowInc
                phaseFlutterL += fluInc
                phaseFlutterR += fluInc
                if phasorAge >= phasorResyncFrames {
                    sinWowL = sin(phaseWowL); cosWowL = cos(phaseWowL)
                    sinWowR = sin(phaseWowR); cosWowR = cos(phaseWowR)
                    sinFluL = sin(phaseFlutterL); cosFluL = cos(phaseFlutterL)
                    sinFluR = sin(phaseFlutterR); cosFluR = cos(phaseFlutterR)
                    phasorAge = 0
                } else {
                    var s = sinWowL * cosWowInc + cosWowL * sinWowInc
                    var c = cosWowL * cosWowInc - sinWowL * sinWowInc
                    sinWowL = s; cosWowL = c
                    s = sinWowR * cosWowInc + cosWowR * sinWowInc
                    c = cosWowR * cosWowInc - sinWowR * sinWowInc
                    sinWowR = s; cosWowR = c
                    s = sinFluL * cosFluInc + cosFluL * sinFluInc
                    c = cosFluL * cosFluInc - sinFluL * sinFluInc
                    sinFluL = s; cosFluL = c
                    s = sinFluR * cosFluInc + cosFluR * sinFluInc
                    c = cosFluR * cosFluInc - sinFluR * sinFluInc
                    sinFluR = s; cosFluR = c
                    phasorAge += 1
                }
                sWowL = sinWowL; sWowR = sinWowR
                sFluL = sinFluL; sFluR = sinFluR
            } else {
                // A rate lane changes the increment every sample — keep the
                // exact trig on that path. (`laneDrivesRate` guarantees the
                // lane and a valid total exist here.)
                let hz = 0.1 + rateLane!.value(at: Double(frame) / Double(totalFrames! - 1)) * 3.9
                phaseWowL += hz * twoPiOverSr
                phaseWowR += hz * twoPiOverSr
                phaseFlutterL += hz * 10 * twoPiOverSr
                phaseFlutterR += hz * 10 * twoPiOverSr
                sWowL = sin(phaseWowL); sWowR = sin(phaseWowR)
                sFluL = sin(phaseFlutterL); sFluR = sin(phaseFlutterR)
            }
            // Inlined xorshift noise (same sequence as `noise()`), against
            // the local state so the loop never touches `self`.
            noiseState ^= noiseState << 13
            noiseState ^= noiseState >> 7
            noiseState ^= noiseState << 17
            let noiseL = Double(noiseState >> 11) * (2.0 / 9007199254740992.0) - 1.0
            driftL += driftAlpha * (noiseL - driftL)
            noiseState ^= noiseState << 13
            noiseState ^= noiseState >> 7
            noiseState ^= noiseState << 17
            let noiseR = Double(noiseState >> 11) * (2.0 / 9007199254740992.0) - 1.0
            driftR += driftAlpha * (noiseR - driftR)

            let laneV = laneValue(amountLane, frame: frame, total: totalFrames, fallback: 1)
            let depth = baseAmount * laneV

            let delayL = centreDelay
                + wowDepthBase * depth * (sWowL + driftL * 0.6)
                + flutterDepthBase * depth * sFluL
            let delayR = centreDelay
                + wowDepthBase * depth * (sWowR + driftR * 0.6)
                + flutterDepthBase * depth * sFluR

            oL[i] = readCubic(rgL.baseAddress!, at: Double(writeIdx) - delayL, mask: mask)
            oR[i] = readCubic(rgR.baseAddress!, at: Double(writeIdx) - delayR, mask: mask)
            writeIdx += 1
        }
        }}}}}}

        self.noiseState = noiseState
        self.amount = amount
        self.writeIdx = writeIdx
        self.phaseWowL = phaseWowL; self.phaseWowR = phaseWowR
        self.phaseFlutterL = phaseFlutterL; self.phaseFlutterR = phaseFlutterR
        self.driftL = driftL; self.driftR = driftR
        self.sinWowL = sinWowL; self.cosWowL = cosWowL
        self.sinWowR = sinWowR; self.cosWowR = cosWowR
        self.sinFluL = sinFluL; self.cosFluL = cosFluL
        self.sinFluR = sinFluR; self.cosFluR = cosFluR
        self.phasorAge = phasorAge
        position += n
        return (outL, outR)
    }

    public func tail() -> (l: [Float], r: [Float]) { ([], []) }

    /// Retunes intensity and rate in place. Amount is a target the per-sample
    /// slew chases; rate lands instantly because the phases are integrated.
    /// Runs on the audio thread — plain stored writes only. Clamps match
    /// the initialiser's.
    func update(from fx: EffectsParameters) {
        targetAmount = Double(min(max(fx.wowAmount, 0), 1))
        rateHz = Double(min(max(fx.wowRateHz, 0.05), 8))
    }
}

#endif  // !os(watchOS)
