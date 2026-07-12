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
    private let amount: Double
    private let rateHz: Double
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
        self.amount = Double(min(max(amount, 0), 1))
        self.rateHz = Double(min(max(rateHz, 0.05), 8))
        self.amountLane = amountLane
        self.rateLane = rateLane
        self.totalFrames = totalFrames
        self.centreDelay = sampleRate * 0.012          // 12 ms centre
        self.wowDepthBase = sampleRate * 0.005         // ±5 ms at full intensity
        self.flutterDepthBase = sampleRate * 0.0007    // ±0.7 ms at full intensity
        self.ringSize = 1 << Int(ceil(log2(sampleRate * 0.03 + 8)))
        self.ringL = [Float](repeating: 0, count: ringSize)
        self.ringR = [Float](repeating: 0, count: ringSize)
    }

    @inline(__always)
    private func noise() -> Double {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 7
        noiseState ^= noiseState << 17
        return Double(noiseState >> 11) * (2.0 / 9007199254740992.0) - 1.0
    }

    @inline(__always)
    private func readCubic(_ ring: [Float], at readPos: Double, mask: Int) -> Float {
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
        if amount <= 0 && amountLane == nil { return (l: l, r: r) }
        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        let mask = ringSize - 1
        let twoPiOverSr = 2 * Double.pi / sampleRate
        // Drift: one-pole low-passed noise, ~0.15 Hz corner.
        let driftAlpha = 1 - exp(-2 * Double.pi * 0.15 / sampleRate)
        let baseAmount = amount > 0 ? amount : 1

        for i in 0..<n {
            let frame = position + i
            ringL[writeIdx & mask] = l[i]
            ringR[writeIdx & mask] = r[i]

            let hz: Double
            if let lane = rateLane, let total = totalFrames, total > 1 {
                hz = 0.1 + lane.value(at: Double(frame) / Double(total - 1)) * 3.9
            } else {
                hz = rateHz
            }
            phaseWowL += hz * twoPiOverSr
            phaseWowR += hz * twoPiOverSr
            phaseFlutterL += hz * 10 * twoPiOverSr
            phaseFlutterR += hz * 10 * twoPiOverSr
            driftL += driftAlpha * (noise() - driftL)
            driftR += driftAlpha * (noise() - driftR)

            let laneV = laneValue(amountLane, frame: frame, total: totalFrames, fallback: 1)
            let depth = baseAmount * laneV

            let delayL = centreDelay
                + wowDepthBase * depth * (sin(phaseWowL) + driftL * 0.6)
                + flutterDepthBase * depth * sin(phaseFlutterL)
            let delayR = centreDelay
                + wowDepthBase * depth * (sin(phaseWowR) + driftR * 0.6)
                + flutterDepthBase * depth * sin(phaseFlutterR)

            outL[i] = readCubic(ringL, at: Double(writeIdx) - delayL, mask: mask)
            outR[i] = readCubic(ringR, at: Double(writeIdx) - delayR, mask: mask)
            writeIdx += 1
        }
        position += n
        return (outL, outR)
    }

    public func tail() -> (l: [Float], r: [Float]) { ([], []) }
}

#endif  // !os(watchOS)
