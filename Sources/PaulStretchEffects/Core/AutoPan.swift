//
//  AutoPan.swift
//  SwiftPaulStretch
//
//  Slow equal-power stereo drift — the moving cousin of a static width
//  control.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// Slow auto-pan: the stereo image drifts left and right on a sine at
/// tidal rates (default 0.03 Hz — a half-minute crossing), with an
/// equal-power balance law so the overall loudness holds steady. The LFO
/// phase is integrated per sample, so a rate lane can sweep it without
/// snapping.
public final class AutoPan: PureStage {

    private let depth: Double
    private let rateHz: Double
    private let sampleRate: Double
    private let depthLane: AutomationLane?
    private let rateLane: AutomationLane?
    private let totalFrames: Int?

    private var phase = 0.0
    private var position = 0

    /// Creates an auto-pan.
    ///
    /// - Parameters:
    ///   - sampleRate: The stream's sample rate, in hertz.
    ///   - depth: Sweep width `0…1` (`1` swings fully hard-left ↔ hard-right).
    ///   - rateHz: The sweep rate (`0.01…8 Hz`).
    ///   - depthLane: Optional depth automation (multiplies; drives directly
    ///     when `depth` is `0`).
    ///   - rateLane: Optional rate automation (`0…1` → `0.01…2 Hz`).
    ///   - totalFrames: The full dry length (the lanes' time base).
    public init(sampleRate: Double,
                depth: Float,
                rateHz: Float = 0.03,
                depthLane: AutomationLane? = nil,
                rateLane: AutomationLane? = nil,
                totalFrames: Int? = nil) {
        self.sampleRate = sampleRate
        self.depth = Double(min(max(depth, 0), 1))
        self.rateHz = Double(min(max(rateHz, 0.01), 8))
        self.depthLane = depthLane
        self.rateLane = rateLane
        self.totalFrames = totalFrames
    }

    public func process(l: [Float], r: [Float]) -> (l: [Float], r: [Float]) {
        let n = min(l.count, r.count)
        if depth <= 0 && depthLane == nil { return (l: l, r: r) }
        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        let twoPiOverSr = 2 * Double.pi / sampleRate
        let baseDepth = depth > 0 ? depth : 1
        let quarterPi = Double.pi / 4

        for i in 0..<n {
            let frame = position + i
            let hz: Double
            if let lane = rateLane, let total = totalFrames, total > 1 {
                hz = 0.01 + lane.value(at: Double(frame) / Double(total - 1)) * 1.99
            } else {
                hz = rateHz
            }
            phase += hz * twoPiOverSr

            let laneV = laneValue(depthLane, frame: frame, total: totalFrames, fallback: 1)
            let pan = baseDepth * laneV * sin(phase)          // −1 … +1
            // Stereo balance law: unity at centre, cosine attenuation of
            // the far side only (no level bump, no clipping headroom cost).
            let gL = pan > 0 ? Float(cos(pan * 2 * quarterPi)) : 1
            let gR = pan < 0 ? Float(cos(-pan * 2 * quarterPi)) : 1
            outL[i] = l[i] * gL
            outR[i] = r[i] * gR
        }
        position += n
        return (outL, outR)
    }

    public func tail() -> (l: [Float], r: [Float]) { ([], []) }
}

#endif  // !os(watchOS)
