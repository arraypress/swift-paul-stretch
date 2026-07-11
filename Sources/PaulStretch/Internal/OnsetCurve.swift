//
//  OnsetCurve.swift
//  SwiftPaulStretch
//
//  Energy-gradient onset curve used to ease phase randomisation off during
//  attacks.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// The frame size (in samples) the onset curve is computed over.
let onsetFrameSize = 512

/// Half-wave-rectified energy gradient, normalised `0…1` and smoothed over
/// three frames.
///
/// A high value means "energy is rising fast here" — the stretcher scales
/// its phase randomisation down at those input positions (proportionally to
/// the onset sensitivity), which keeps attacks and swells legible inside the
/// wash.
func computeOnsetCurve(_ inL: [Float], _ inR: [Float], _ frameSize: Int) -> [Float] {
    let numFrames = max(1, inL.count / frameSize)
    var energies = [Float](repeating: 0, count: numFrames)
    for f in 0..<numFrames {
        var e: Float = 0
        let start = f * frameSize
        let end = min(start + frameSize, inL.count)
        var i = start
        while i < end { let s = (inL[i] + inR[i]) * 0.5; e += s * s; i += 1 }
        energies[f] = (e / Float(max(1, end - start))).squareRoot()
    }
    var raw = [Float](repeating: 0, count: numFrames)
    if numFrames > 1 { for f in 1..<numFrames { raw[f] = max(0, energies[f] - energies[f - 1]) } }
    var smoothed = [Float](repeating: 0, count: numFrames)
    for f in 0..<numFrames {
        var acc = raw[f]; var count = 1
        if f > 0 { acc += raw[f - 1]; count += 1 }
        if f < numFrames - 1 { acc += raw[f + 1]; count += 1 }
        smoothed[f] = acc / Float(count)
    }
    var maxO: Float = 0
    for v in smoothed { if v > maxO { maxO = v } }
    if maxO > 0 { for f in 0..<numFrames { smoothed[f] /= maxO } }
    return smoothed
}
