//
//  BreathingPump.swift
//  SwiftPaulStretch
//
//  Slow amplitude breathing — tidal gain movement at slower-than-breath
//  rates, phase-offset across the stereo field.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// Slow amplitude breathing: a sine gain swell of up to ±25 %, deliberately
/// slower than human breathing (default 0.05 Hz — a 20-second tide), with
/// left and right phase-offset so the swell feels like air moving across
/// the room rather than a centre-panned tremolo. Peaks are soft-clipped so
/// full-scale drones can't fizz on the up-swing.
public final class BreathingPump: PureStage {

    /// Swell depth, slewed toward `targetDepth` — it scales the gain swing
    /// directly, so a stepped knob move would otherwise zipper.
    private var depth: Double
    private var targetDepth: Double
    /// Applied instantly on retune: the phases accumulate incrementally, so
    /// a new rate only changes the increment — phase-continuous.
    private var rateHz: Double
    private let sampleRate: Double
    /// One-pole coefficient for the ~30 ms parameter slew.
    private let paramSlew: Double
    private let depthLane: AutomationLane?
    private let rateLane: AutomationLane?
    private let totalFrames: Int?

    private var phaseL = 0.0
    private var phaseR = 0.7   // air moving across the room
    private var position = 0

    /// Creates a breathing pump.
    ///
    /// - Parameters:
    ///   - sampleRate: The stream's sample rate, in hertz.
    ///   - depth: Swell depth `0…1` (`1` = ±25 % gain).
    ///   - rateHz: The breath rate (`0.02…14 Hz` — tidal at the bottom,
    ///     tremolo at the top).
    ///   - depthLane: Optional depth automation (multiplies; drives
    ///     directly when `depth` is `0`).
    ///   - rateLane: Optional rate automation (`0…1` → `0.02…0.5 Hz`,
    ///     phase-integrated).
    ///   - totalFrames: The full dry length (the lanes' time base).
    public init(sampleRate: Double,
                depth: Float,
                rateHz: Float = 0.05,
                depthLane: AutomationLane? = nil,
                rateLane: AutomationLane? = nil,
                totalFrames: Int? = nil) {
        self.sampleRate = sampleRate
        let d = Double(min(max(depth, 0), 1))
        self.depth = d
        self.targetDepth = d
        self.rateHz = Double(min(max(rateHz, 0.02), 14))
        // One-pole reaching ~63 % of a step in 30 ms.
        self.paramSlew = 1 - exp(-1 / (0.03 * sampleRate))
        self.depthLane = depthLane
        self.rateLane = rateLane
        self.totalFrames = totalFrames
    }

    public func process(l: [Float], r: [Float]) -> (l: [Float], r: [Float]) {
        let n = min(l.count, r.count)
        // Identity bypass is safe here (unlike wow, there is no buffer to
        // keep fed): the phases simply stand still until a retune arrives.
        if depth <= 0 && targetDepth <= 0 && depthLane == nil { return (l: l, r: r) }
        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        let twoPiOverSr = 2 * Double.pi / sampleRate

        for i in 0..<n {
            let frame = position + i
            depth += (targetDepth - depth) * paramSlew
            let baseDepth = depth > 0 ? 0.25 * depth : 0.25
            let hz: Double
            if let lane = rateLane, let total = totalFrames, total > 1 {
                hz = 0.02 + lane.value(at: Double(frame) / Double(total - 1)) * 0.48
            } else {
                hz = rateHz
            }
            phaseL += hz * twoPiOverSr
            phaseR += hz * twoPiOverSr

            let laneV = laneValue(depthLane, frame: frame, total: totalFrames, fallback: 1)
            let d = baseDepth * laneV
            let gL = 1 + d * sin(phaseL)
            let gR = 1 + d * sin(phaseR)
            // Transparent below the knee; only the up-swing's overshoot is
            // rounded (an unconditional tanh would colour everything).
            outL[i] = Self.kneeClip(Float(Double(l[i]) * gL))
            outR[i] = Self.kneeClip(Float(Double(r[i]) * gR))
        }
        position += n
        return (outL, outR)
    }

    public func tail() -> (l: [Float], r: [Float]) { ([], []) }

    /// Retunes depth and rate in place. Depth is a target the per-sample slew
    /// chases; rate lands instantly because the phases are integrated. Runs
    /// on the audio thread — plain stored writes only. Clamps match the
    /// initialiser's.
    func update(from fx: EffectsParameters) {
        targetDepth = Double(min(max(fx.pumpDepth, 0), 1))
        rateHz = Double(min(max(fx.pumpRateHz, 0.02), 14))
    }

    /// Identity below ±0.9; the overshoot is folded through a tanh that
    /// asymptotes at ±1.0. Bit-transparent for everything under the knee.
    @inline(__always)
    static func kneeClip(_ x: Float) -> Float {
        let knee: Float = 0.9
        let a = abs(x)
        if a <= knee { return x }
        let excess = (a - knee) / 0.1
        let clipped = knee + 0.1 * tanhf(excess)
        return x < 0 ? -clipped : clipped
    }
}

#endif  // !os(watchOS)
