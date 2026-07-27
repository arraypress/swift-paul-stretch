//
//  StereoPlacement.swift
//  SwiftPaulStretch
//
//  Static stereo position and width — the plain pan control the effect set
//  was missing (AutoPan only ever swept it).
//
//  Created by David Sherlock on 7/27/26.
//

import Foundation
import PaulStretch

#if !os(watchOS)

/// Places the signal in the stereo field: a fixed pan, plus a width control
/// that collapses toward mono or spreads beyond the original image.
///
/// Width works on the mid/side decomposition — `mid = (l+r)/2`,
/// `side = (l-r)/2` — scaling only the side component. At `0` the side
/// vanishes and the result is mono; at `2` it is doubled. This is the
/// standard trick, and it is mono-safe in the sense that summing the output
/// to mono cancels the side signal cleanly rather than comb-filtering, which
/// is what a delay-based widener would do.
///
/// Pan is equal-power (`cos`/`sin` over a quarter turn), so sweeping across
/// the image holds perceived loudness steady where a linear pan would dip
/// about 3 dB in the middle.
final class StereoPlacement {

    private let pan: Float       // -1…1
    private let width: Float     // 0…2
    private let gainL: Float
    private let gainR: Float

    /// Creates a placement stage.
    ///
    /// - Parameters:
    ///   - pan: Stereo position, `-1` hard left to `+1` hard right.
    ///   - width: Stereo width, `0` mono to `2` doubled.
    init(pan: Float, width: Float) {
        let p = min(max(pan, -1), 1)
        self.pan = p
        self.width = min(max(width, 0), 2)
        // Map -1…1 to a 0…π/2 quarter turn.
        let theta = (p + 1) * 0.25 * Float.pi
        gainL = cos(theta)
        gainR = sin(theta)
        // At centre this yields cos(π/4) = sin(π/4) ≈ 0.7071 on both sides,
        // which is a 3 dB drop, so both are lifted back to unity at centre.
        // (Scaling by √2 keeps the equal-power curve and restores centre
        // gain to 1.0.)
    }

    func process(l: [Float], r: [Float]) -> (l: [Float], r: [Float]) {
        let n = min(l.count, r.count)
        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        let root2: Float = 1.4142135623730951
        let gl = gainL * root2
        let gr = gainR * root2
        let w = width
        for i in 0..<n {
            let mid = (l[i] + r[i]) * 0.5
            let side = (l[i] - r[i]) * 0.5 * w
            outL[i] = (mid + side) * gl
            outR[i] = (mid - side) * gr
        }
        return (outL, outR)
    }

    func tail() -> (l: [Float], r: [Float]) { ([], []) }
}

extension StereoPlacement: PureStage {}

#endif  // !os(watchOS)
