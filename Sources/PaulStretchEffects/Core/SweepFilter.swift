//
//  SweepFilter.swift
//  SwiftPaulStretch
//
//  A slowly-breathing resonant filter: TPT state-variable core (stable
//  under fast modulation), a bass-cut high-pass companion, a sine LFO that
//  sweeps the cutoff in octaves, and automation lanes for cutoff/resonance.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// A modulated resonant filter designed for drones: low/high/band-pass from
/// one state-variable topology, an optional bass-cut high-pass in front,
/// and a slow sine LFO sweeping the cutoff in **octaves** — a filter that
/// breathes over tens of seconds is half of what makes a wash feel alive.
///
/// The core is a TPT (topology-preserving transform) state-variable filter,
/// chosen over swept biquads because its coefficients can move every sample
/// without zipper noise or instability. Cutoff and resonance accept
/// ``AutomationLane``s (absolute: `0…1` maps log-scaled to `40…18k Hz` and
/// linearly to `Q 0.5…12`), which replace the static value and the LFO.
public final class SweepFilter: PureStage {

    private let sampleRate: Double
    private let shape: FilterShape
    private let cutoff: Double
    private let q: Double
    private let bassCut: Double
    private let lfoPeriod: Double
    private let lfoDepth: Double
    private let cutoffLane: AutomationLane?
    private let resonanceLane: AutomationLane?
    private let totalFrames: Int?

    // TPT SVF state, per channel (main filter + bass-cut high-pass).
    private var ic1 = [Double](repeating: 0, count: 2)
    private var ic2 = [Double](repeating: 0, count: 2)
    private var bassIc1 = [Double](repeating: 0, count: 2)
    private var bassIc2 = [Double](repeating: 0, count: 2)
    private var position = 0

    /// Lane cutoff mapping, log-scaled (matches the original's absolute lane).
    static let laneMinHz = 40.0
    static let laneMaxHz = 18_000.0

    /// Creates a sweep filter.
    ///
    /// - Parameters:
    ///   - sampleRate: The stream's sample rate, in hertz.
    ///   - shape: The response shape.
    ///   - cutoff: Static cutoff, in hertz (`20…20k`).
    ///   - resonance: Q (`0.5…12`).
    ///   - bassCut: A companion high-pass ahead of the main filter, in
    ///     hertz; `0` disables it. Keeps swept low-pass drones from
    ///     ballooning in the sub range.
    ///   - lfoPeriodSeconds: The sweep period (`1…120 s`).
    ///   - lfoDepthOctaves: Sweep depth in ± octaves around the cutoff
    ///     (`0` disables the LFO).
    ///   - cutoffLane: Optional absolute cutoff automation (replaces the
    ///     static cutoff *and* the LFO — whatever the knob says, the lane
    ///     wins).
    ///   - resonanceLane: Optional absolute resonance automation.
    ///   - totalFrames: The full dry length (the lanes' time base).
    public init(sampleRate: Double,
                shape: FilterShape,
                cutoff: Float,
                resonance: Float,
                bassCut: Float = 0,
                lfoPeriodSeconds: Float = 20,
                lfoDepthOctaves: Float = 0,
                cutoffLane: AutomationLane? = nil,
                resonanceLane: AutomationLane? = nil,
                totalFrames: Int? = nil) {
        self.sampleRate = sampleRate
        self.shape = shape
        self.cutoff = Double(min(max(cutoff, 20), 20_000))
        self.q = Double(min(max(resonance, 0.5), 12))
        self.bassCut = Double(max(0, min(bassCut, 2_000)))
        self.lfoPeriod = Double(max(1, lfoPeriodSeconds))
        self.lfoDepth = Double(max(0, min(lfoDepthOctaves, 4)))
        self.cutoffLane = cutoffLane
        self.resonanceLane = resonanceLane
        self.totalFrames = totalFrames
    }

    public func process(l: [Float], r: [Float]) -> (l: [Float], r: [Float]) {
        let n = min(l.count, r.count)
        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        let nyquistGuard = sampleRate * 0.45

        for i in 0..<n {
            let frame = position + i
            // Cutoff: lane (absolute, log-mapped) wins over LFO over static.
            var fc = cutoff
            if let lane = cutoffLane, let total = totalFrames, total > 1 {
                let v = lane.value(at: Double(frame) / Double(total - 1))
                fc = Self.laneMinHz * pow(Self.laneMaxHz / Self.laneMinHz, min(max(v, 0), 1))
            } else if lfoDepth > 0 {
                let phase = (Double(frame) / sampleRate / lfoPeriod) * 2 * Double.pi
                fc = cutoff * pow(2, sin(phase) * lfoDepth)
            }
            fc = min(max(fc, 20), nyquistGuard)

            var effQ = q
            if let lane = resonanceLane, let total = totalFrames, total > 1 {
                let v = lane.value(at: Double(frame) / Double(total - 1))
                effQ = 0.5 + min(max(v, 0), 1) * 11.5
            }

            let g = tan(Double.pi * fc / sampleRate)
            let k = 1.0 / effQ
            let a1 = 1.0 / (1.0 + g * (g + k))

            // Bass-cut companion: Butterworth-Q high-pass (k = √2).
            let kBass = 1.4142135623730951
            let gBass = bassCut > 0 ? tan(Double.pi * min(bassCut, nyquistGuard) / sampleRate) : 0
            let a1Bass = bassCut > 0 ? 1.0 / (1.0 + gBass * (gBass + kBass)) : 0

            for ch in 0..<2 {
                var x = ch == 0 ? Double(l[i]) : Double(r[i])
                if bassCut > 0 {
                    let v1 = a1Bass * (bassIc1[ch] + gBass * (x - bassIc2[ch]))
                    let v2 = bassIc2[ch] + gBass * v1
                    bassIc1[ch] = 2 * v1 - bassIc1[ch]
                    bassIc2[ch] = 2 * v2 - bassIc2[ch]
                    x = x - kBass * v1 - v2
                }
                let v1 = a1 * (ic1[ch] + g * (x - ic2[ch]))
                let v2 = ic2[ch] + g * v1
                ic1[ch] = 2 * v1 - ic1[ch]
                ic2[ch] = 2 * v2 - ic2[ch]
                let y: Double
                switch shape {
                case .lowPass:  y = v2
                case .bandPass: y = v1
                case .highPass: y = x - k * v1 - v2
                }
                if ch == 0 { outL[i] = Float(y) } else { outR[i] = Float(y) }
            }
        }
        position += n
        return (outL, outR)
    }

    public func tail() -> (l: [Float], r: [Float]) { ([], []) }
}

#endif  // !os(watchOS)
