//
//  TranceGate.swift
//  SwiftPaulStretch
//
//  Rhythmic amplitude gating — the one effect that gives a static drone a
//  pulse instead of a swell.
//
//  Created by David Sherlock on 7/27/26.
//

import Foundation
import PaulStretch

#if !os(watchOS)

/// Common 16-step gate patterns.
///
/// Patterns are read as sixteen slots; the rate sets how long each slot
/// lasts, so the same pattern at a different rate is the same rhythm at a
/// different tempo.
public enum TranceGatePattern {
    /// Every step open — no rhythm, useful as a starting point.
    public static let solid = [Bool](repeating: true, count: 16)
    /// Straight eighths: on-off, on-off.
    public static let eighths = (0..<16).map { $0 % 2 == 0 }
    /// Sixteenths with every fourth step held — a driving pulse.
    public static let sixteenths = (0..<16).map { $0 % 4 != 3 }
    /// Off-beats only, which reads as a syncopated lift.
    public static let offbeat = (0..<16).map { $0 % 4 == 2 }
    /// A 3-3-2 tresillo, the least mechanical of the set.
    public static let tresillo: [Bool] = {
        var p = [Bool](repeating: false, count: 16)
        for i in [0, 3, 6, 8, 11, 14] { p[i] = true }
        return p
    }()
    /// Long-short breathing, for slower rates.
    public static let sparse = (0..<16).map { $0 % 8 < 3 }

    /// Every named pattern, for pickers.
    public static let named: [(name: String, pattern: [Bool])] = [
        ("Solid", solid), ("Eighths", eighths), ("Sixteenths", sixteenths),
        ("Off-beat", offbeat), ("Tresillo", tresillo), ("Sparse", sparse),
    ]
}

/// Gates the signal on a repeating step pattern.
///
/// The gate is not a hard switch: each step edge is ramped over
/// ``smoothingMs``. That matters more than it sounds — a hard gate on a
/// sustained pad produces a click at every edge, because the waveform is cut
/// mid-cycle and the discontinuity is broadband. The ramp costs a little of
/// the rhythmic bite but is the difference between a gate and a buzz.
///
/// The right channel can be offset by whole steps, which turns a single
/// pattern into a ping-pong without needing a second pattern.
final class TranceGate {

    private let sampleRate: Double
    private let pattern: [Bool]
    /// How far closed steps duck, slewed toward `targetDepth` — it sets the
    /// gate floor directly, and the envelope's own ramp can be well under a
    /// millisecond, too fast to hide a stepped knob move.
    private var depth: Float
    private var targetDepth: Float
    private var stereoOffset: Int
    /// Steps advanced per frame. A retune changes this increment only, so the
    /// pattern speeds up or slows down from wherever it is — deriving the step
    /// from the absolute frame index would teleport it instead.
    private var stepInc: Double
    /// Position within the pattern, in steps (`0..<pattern.count`), wrapped
    /// at the pattern length so precision never degrades over a long piece.
    private var stepPhase = 0.0
    /// Ramp coefficient — how far the envelope moves toward its target each
    /// frame. Derived from the smoothing time; applied instantly on retune
    /// because the envelope it shapes is continuous state either way.
    private var slew: Float
    /// One-pole coefficient for the ~30 ms depth slew.
    private let paramSlew: Float

    private var envL: Float = 1
    private var envR: Float = 1

    /// Creates a gate.
    ///
    /// - Parameters:
    ///   - sampleRate: The stream's sample rate, in hertz.
    ///   - rateHz: Steps per second.
    ///   - depth: How far closed steps duck, `0`…`1`.
    ///   - smoothingMs: Edge ramp time, in milliseconds.
    ///   - pattern: Which steps are open. Empty falls back to eighths.
    ///   - stereoOffset: Steps to offset the right channel by.
    init(sampleRate: Double, rateHz: Float, depth: Float,
         smoothingMs: Float, pattern: [Bool], stereoOffset: Int) {
        self.sampleRate = sampleRate
        self.pattern = pattern.isEmpty ? TranceGatePattern.eighths : pattern
        let d = min(max(depth, 0), 1)
        self.depth = d
        self.targetDepth = d
        self.stereoOffset = stereoOffset
        // Clamped so a step can never be shorter than one frame.
        stepInc = min(1, Double(max(0.01, rateHz)) / sampleRate)
        // One-pole ramp reaching ~63 % in the smoothing time; clamped so a
        // zero setting still takes a couple of frames and cannot click.
        let ms = Double(max(0.5, smoothingMs))
        slew = Float(1.0 - exp(-1.0 / (ms * 0.001 * sampleRate)))
        // One-pole reaching ~63 % of a step in 30 ms.
        paramSlew = Float(1 - exp(-1 / (0.03 * sampleRate)))
    }

    /// The gate level for a pattern step and channel offset.
    @inline(__always)
    private func target(step: Int, offset: Int) -> Float {
        let s = step + offset
        // Swift's % keeps the sign of the dividend, so a negative offset
        // needs correcting or the pattern index goes out of range.
        let idx = ((s % pattern.count) + pattern.count) % pattern.count
        return pattern[idx] ? 1 : (1 - depth)
    }

    func process(l: [Float], r: [Float]) -> (l: [Float], r: [Float]) {
        let n = min(l.count, r.count)
        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        let patternLength = Double(pattern.count)
        for i in 0..<n {
            depth += (targetDepth - depth) * paramSlew
            let step = Int(stepPhase)
            envL += (target(step: step, offset: 0) - envL) * slew
            envR += (target(step: step, offset: stereoOffset) - envR) * slew
            outL[i] = l[i] * envL
            outR[i] = r[i] * envR
            stepPhase += stepInc
            if stepPhase >= patternLength { stepPhase -= patternLength }
        }
        return (outL, outR)
    }

    func tail() -> (l: [Float], r: [Float]) { ([], []) }
}

extension TranceGate: PureStage {
    /// Retunes rate, depth, smoothing and stereo offset in place — the
    /// PATTERN is structural (it re-anchors the phase) and is ignored here.
    /// Depth is a slew target; rate changes the step increment only, so the
    /// pulse stays where it is; a new offset or smoothing rides the envelope
    /// ramp like any other gate edge. Runs on the audio thread — plain
    /// stored writes only. Clamps match the initialiser's.
    func update(from fx: EffectsParameters) {
        stepInc = min(1, Double(max(0.01, fx.tranceGateRateHz)) / sampleRate)
        targetDepth = min(max(fx.tranceGateDepth, 0), 1)
        let ms = Double(max(0.5, fx.tranceGateSmoothingMs))
        slew = Float(1.0 - exp(-1.0 / (ms * 0.001 * sampleRate)))
        stereoOffset = fx.tranceGateStereoOffset
    }
}

#endif  // !os(watchOS)
