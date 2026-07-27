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
    private let depth: Float
    private let stereoOffset: Int
    private let framesPerStep: Double
    /// Ramp coefficient — how far the envelope moves toward its target each
    /// frame. Derived from the smoothing time.
    private let slew: Float

    /// Absolute frame position, so the pattern stays locked to the timeline
    /// across chunk boundaries.
    private var frame: Int = 0
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
        self.depth = min(max(depth, 0), 1)
        self.stereoOffset = stereoOffset
        let rate = Double(max(0.01, rateHz))
        framesPerStep = max(1, sampleRate / rate)
        // One-pole ramp reaching ~63 % in the smoothing time; clamped so a
        // zero setting still takes a couple of frames and cannot click.
        let ms = Double(max(0.5, smoothingMs))
        slew = Float(1.0 - exp(-1.0 / (ms * 0.001 * sampleRate)))
    }

    /// The gate level for a given absolute frame and channel offset.
    @inline(__always)
    private func target(at f: Int, offset: Int) -> Float {
        let step = Int((Double(f) / framesPerStep).rounded(.down)) + offset
        // Swift's % keeps the sign of the dividend, so a negative offset
        // needs correcting or the pattern index goes out of range.
        let idx = ((step % pattern.count) + pattern.count) % pattern.count
        return pattern[idx] ? 1 : (1 - depth)
    }

    func process(l: [Float], r: [Float]) -> (l: [Float], r: [Float]) {
        let n = min(l.count, r.count)
        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let f = frame + i
            envL += (target(at: f, offset: 0) - envL) * slew
            envR += (target(at: f, offset: stereoOffset) - envR) * slew
            outL[i] = l[i] * envL
            outR[i] = r[i] * envR
        }
        frame += n
        return (outL, outR)
    }

    func tail() -> (l: [Float], r: [Float]) { ([], []) }
}

extension TranceGate: PureStage {}

#endif  // !os(watchOS)
