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
    /// Switched instantly on retune: the SVF integrator state is valid for
    /// every response — only the output mix formula changes.
    private var shape: FilterShape
    /// Cutoff, slewed in log2 domain — equal glide time per octave, so a
    /// 200→400 Hz move sounds like an 8k→16k one. Linear-Hz slew spends
    /// nearly all its time in the top octave.
    private var cutoffLog2: Double
    private var targetCutoffLog2: Double
    private var q: Double
    private var targetQ: Double
    private var bassCut: Double
    private var targetBassCut: Double
    /// Applied instantly on retune: the LFO phase accumulates incrementally,
    /// so a new period only changes the increment — phase-continuous.
    private var lfoPeriod: Double
    private var lfoDepth: Double
    private var targetLfoDepth: Double
    private var lfoPhase = 0.0
    /// One-pole coefficient for the ~30 ms parameter slew.
    private let paramSlew: Double
    private let cutoffLane: AutomationLane?
    private let resonanceLane: AutomationLane?
    private let totalFrames: Int?

    // TPT SVF state, per channel (main filter + bass-cut high-pass) —
    // scalars, not arrays: per-sample array subscripts through `self` pay
    // bounds and exclusivity checks that dominated this stage's remaining
    // cost once the tan() was hoisted.
    private var ic1L = 0.0, ic1R = 0.0
    private var ic2L = 0.0, ic2R = 0.0
    private var bassIc1L = 0.0, bassIc1R = 0.0
    private var bassIc2L = 0.0, bassIc2R = 0.0
    private var position = 0

    // Cached coefficients, recomputed only when their inputs move. The
    // slewed cutoff/Q/bassCut are constant in floating point once settled
    // (the one-pole's increment underflows), so the `tan()`/`exp2()` per
    // sample — which dominated this stage's cost — collapse to a compare
    // except while a knob, lane or LFO is actually moving. Keyed on the
    // exact input values, so results are bit-identical to recomputing.
    private var coeffFc = Double.nan
    private var coeffQ = Double.nan
    private var coeffG = 0.0
    private var coeffK = 0.0
    private var coeffA1 = 0.0
    private var coeffBassCut = Double.nan
    private var coeffGBass = 0.0
    private var coeffA1Bass = 0.0
    private var baseFcLog2 = Double.nan
    private var baseFc = 0.0

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
        let fcLog = log2(Double(min(max(cutoff, 20), 20_000)))
        self.cutoffLog2 = fcLog
        self.targetCutoffLog2 = fcLog
        let qq = Double(min(max(resonance, 0.5), 12))
        self.q = qq
        self.targetQ = qq
        let bass = Double(max(0, min(bassCut, 2_000)))
        self.bassCut = bass
        self.targetBassCut = bass
        self.lfoPeriod = Double(max(1, lfoPeriodSeconds))
        let depth = Double(max(0, min(lfoDepthOctaves, 4)))
        self.lfoDepth = depth
        self.targetLfoDepth = depth
        // One-pole reaching ~63 % of a step in 30 ms.
        self.paramSlew = 1 - exp(-1 / (0.03 * sampleRate))
        self.cutoffLane = cutoffLane
        self.resonanceLane = resonanceLane
        self.totalFrames = totalFrames
    }

    public func process(l: [Float], r: [Float]) -> (l: [Float], r: [Float]) {
        let n = min(l.count, r.count)
        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        let nyquistGuard = sampleRate * 0.45

        // Hoist mutable state into locals — per-sample property access
        // through `self` pays an exclusivity check per touch. Written back
        // after the loop.
        var cutoffLog2 = self.cutoffLog2
        var q = self.q
        var lfoDepth = self.lfoDepth
        var bassCut = self.bassCut
        var lfoPhase = self.lfoPhase
        var ic1L = self.ic1L, ic1R = self.ic1R
        var ic2L = self.ic2L, ic2R = self.ic2R
        var bassIc1L = self.bassIc1L, bassIc1R = self.bassIc1R
        var bassIc2L = self.bassIc2L, bassIc2R = self.bassIc2R
        let targetCutoffLog2 = self.targetCutoffLog2
        let targetQ = self.targetQ
        let targetLfoDepth = self.targetLfoDepth
        let targetBassCut = self.targetBassCut
        let paramSlew = self.paramSlew
        let lfoPeriod = self.lfoPeriod
        let shape = self.shape
        var baseFcLog2 = self.baseFcLog2
        var baseFc = self.baseFc
        var coeffFc = self.coeffFc, coeffQ = self.coeffQ
        var coeffG = self.coeffG, coeffK = self.coeffK, coeffA1 = self.coeffA1
        var coeffBassCut = self.coeffBassCut
        var coeffGBass = self.coeffGBass, coeffA1Bass = self.coeffA1Bass

        l.withUnsafeBufferPointer { lIn in
        r.withUnsafeBufferPointer { rIn in
        outL.withUnsafeMutableBufferPointer { oL in
        outR.withUnsafeMutableBufferPointer { oR in
        for i in 0..<n {
            let frame = position + i
            // Chase the retune targets. Snapping when close lets bassCut
            // actually REACH zero — a one-pole only approaches it, and the
            // companion filter's on/off branch tests `> 0`.
            cutoffLog2 += (targetCutoffLog2 - cutoffLog2) * paramSlew
            q += (targetQ - q) * paramSlew
            lfoDepth += (targetLfoDepth - lfoDepth) * paramSlew
            bassCut += (targetBassCut - bassCut) * paramSlew
            if abs(targetBassCut - bassCut) < 1e-3 { bassCut = targetBassCut }

            // Cutoff: lane (absolute, log-mapped) wins over LFO over static.
            // The static exp2 is cached against cutoffLog2 — it only changes
            // while the slew is actually moving.
            if cutoffLog2 != baseFcLog2 {
                baseFc = exp2(cutoffLog2)
                baseFcLog2 = cutoffLog2
            }
            var fc = baseFc
            if let lane = cutoffLane, let total = totalFrames, total > 1 {
                let v = lane.value(at: Double(frame) / Double(total - 1))
                fc = Self.laneMinHz * pow(Self.laneMaxHz / Self.laneMinHz, min(max(v, 0), 1))
            } else if lfoDepth > 0 {
                fc = exp2(cutoffLog2 + sin(lfoPhase) * lfoDepth)
            }
            fc = min(max(fc, 20), nyquistGuard)
            // The LFO integrates its phase (advanced after use, so the first
            // sample sees phase zero exactly as the absolute-time form did) —
            // a period retune bends the sweep's speed without snapping its
            // position, which computing phase from the frame index cannot do.
            lfoPhase += 2 * Double.pi / (sampleRate * lfoPeriod)
            if lfoPhase >= 2 * Double.pi { lfoPhase -= 2 * Double.pi }

            var effQ = q
            if let lane = resonanceLane, let total = totalFrames, total > 1 {
                let v = lane.value(at: Double(frame) / Double(total - 1))
                effQ = 0.5 + min(max(v, 0), 1) * 11.5
            }

            // Main SVF coefficients — the tan() is the expensive part, so it
            // runs only when the effective cutoff or Q actually changed.
            if fc != coeffFc || effQ != coeffQ {
                coeffG = tan(Double.pi * fc / sampleRate)
                coeffK = 1.0 / effQ
                coeffA1 = 1.0 / (1.0 + coeffG * (coeffG + coeffK))
                coeffFc = fc
                coeffQ = effQ
            }
            let g = coeffG
            let k = coeffK
            let a1 = coeffA1

            // Bass-cut companion: Butterworth-Q high-pass (k = √2). Its
            // coefficients move only while bassCut itself is slewing.
            let kBass = 1.4142135623730951
            if bassCut != coeffBassCut {
                coeffGBass = bassCut > 0 ? tan(Double.pi * min(bassCut, nyquistGuard) / sampleRate) : 0
                coeffA1Bass = bassCut > 0 ? 1.0 / (1.0 + coeffGBass * (coeffGBass + kBass)) : 0
                coeffBassCut = bassCut
            }
            let gBass = coeffGBass
            let a1Bass = coeffA1Bass

            // Both channels, unrolled (identical arithmetic, scalar state).
            var xL = Double(lIn[i])
            var xR = Double(rIn[i])
            if bassCut > 0 {
                let v1L = a1Bass * (bassIc1L + gBass * (xL - bassIc2L))
                let v2L = bassIc2L + gBass * v1L
                bassIc1L = 2 * v1L - bassIc1L
                bassIc2L = 2 * v2L - bassIc2L
                xL = xL - kBass * v1L - v2L
                let v1R = a1Bass * (bassIc1R + gBass * (xR - bassIc2R))
                let v2R = bassIc2R + gBass * v1R
                bassIc1R = 2 * v1R - bassIc1R
                bassIc2R = 2 * v2R - bassIc2R
                xR = xR - kBass * v1R - v2R
            }
            let v1L = a1 * (ic1L + g * (xL - ic2L))
            let v2L = ic2L + g * v1L
            ic1L = 2 * v1L - ic1L
            ic2L = 2 * v2L - ic2L
            let v1R = a1 * (ic1R + g * (xR - ic2R))
            let v2R = ic2R + g * v1R
            ic1R = 2 * v1R - ic1R
            ic2R = 2 * v2R - ic2R
            let yL: Double
            let yR: Double
            switch shape {
            case .lowPass:  yL = v2L; yR = v2R
            case .bandPass: yL = v1L; yR = v1R
            case .highPass: yL = xL - k * v1L - v2L; yR = xR - k * v1R - v2R
            }
            oL[i] = Float(yL)
            oR[i] = Float(yR)
        }
        }}}}

        self.baseFcLog2 = baseFcLog2
        self.baseFc = baseFc
        self.coeffFc = coeffFc; self.coeffQ = coeffQ
        self.coeffG = coeffG; self.coeffK = coeffK; self.coeffA1 = coeffA1
        self.coeffBassCut = coeffBassCut
        self.coeffGBass = coeffGBass; self.coeffA1Bass = coeffA1Bass
        self.cutoffLog2 = cutoffLog2
        self.q = q
        self.lfoDepth = lfoDepth
        self.bassCut = bassCut
        self.lfoPhase = lfoPhase
        self.ic1L = ic1L; self.ic1R = ic1R
        self.ic2L = ic2L; self.ic2R = ic2R
        self.bassIc1L = bassIc1L; self.bassIc1R = bassIc1R
        self.bassIc2L = bassIc2L; self.bassIc2R = bassIc2R
        position += n
        return (outL, outR)
    }

    public func tail() -> (l: [Float], r: [Float]) { ([], []) }

    /// Retunes everything continuous in place: cutoff (slewed in log2 domain),
    /// resonance, bass-cut and LFO depth as slew targets; shape and LFO period
    /// instantly (the integrator state survives a shape switch, and the phase
    /// accumulator makes a period change continuous). Runs on the audio
    /// thread — plain stored writes only. Clamps match the initialiser's.
    func update(from fx: EffectsParameters) {
        shape = fx.sweepFilterShape
        targetCutoffLog2 = log2(Double(min(max(fx.sweepFilterCutoff, 20), 20_000)))
        targetQ = Double(min(max(fx.sweepFilterResonance, 0.5), 12))
        targetBassCut = Double(max(0, min(fx.sweepFilterBassCut, 2_000)))
        lfoPeriod = Double(max(1, fx.sweepFilterLFOPeriod))
        targetLfoDepth = Double(max(0, min(fx.sweepFilterLFODepth, 4)))
    }
}

#endif  // !os(watchOS)
