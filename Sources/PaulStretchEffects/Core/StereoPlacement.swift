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
/// Pan is equal-power (`cos`/`sin` over a quarter turn) lifted to unity at
/// centre, with each side CAPPED at unity: the uncapped √2 lift put a hard
/// pan at +3 dB, and placement is the last stage in the chain — nothing
/// downstream caught a normalised render clipping at 1.3 FS.
///
/// Pan and width retune in place (``update(from:)``), slewed over ~30 ms so
/// an automated sweep is a movement, not a zipper.
final class StereoPlacement {

    private var pan: Float           // -1…1, slewed toward `targetPan`
    private var width: Float         // 0…2, slewed toward `targetWidth`
    private var targetPan: Float
    private var targetWidth: Float
    private var gainL: Float
    private var gainR: Float
    private let slew: Float

    /// Creates a placement stage.
    ///
    /// - Parameters:
    ///   - sampleRate: Stream rate, in hertz — sets the retune slew time.
    ///   - pan: Stereo position, `-1` hard left to `+1` hard right.
    ///   - width: Stereo width, `0` mono to `2` doubled.
    init(sampleRate: Double, pan: Float, width: Float) {
        let p = min(max(pan, -1), 1)
        self.pan = p
        self.targetPan = p
        let w = min(max(width, 0), 2)
        self.width = w
        self.targetWidth = w
        let g = Self.gains(for: p)
        self.gainL = g.l
        self.gainR = g.r
        self.slew = Float(1 - exp(-1 / (0.03 * sampleRate)))
    }

    /// The channel gains for a pan position: equal-power, unity at centre,
    /// capped at unity per side (see the type overview).
    @inline(__always)
    private static func gains(for pan: Float) -> (l: Float, r: Float) {
        let theta = (pan + 1) * 0.25 * Float.pi
        let root2: Float = 1.4142135623730951
        return (min(cos(theta) * root2, 1), min(sin(theta) * root2, 1))
    }

    func process(l: [Float], r: [Float]) -> (l: [Float], r: [Float]) {
        let n = min(l.count, r.count)
        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        for i in 0..<n {
            // Gains are recomputed only while a retune is in flight — the
            // settled state pays no trigonometry at all.
            if pan != targetPan {
                pan += (targetPan - pan) * slew
                if abs(targetPan - pan) < 1e-5 { pan = targetPan }
                let g = Self.gains(for: pan)
                gainL = g.l
                gainR = g.r
            }
            if width != targetWidth {
                width += (targetWidth - width) * slew
                if abs(targetWidth - width) < 1e-5 { width = targetWidth }
            }
            let mid = (l[i] + r[i]) * 0.5
            let side = (l[i] - r[i]) * 0.5 * width
            outL[i] = (mid + side) * gainL
            outR[i] = (mid - side) * gainR
        }
        return (outL, outR)
    }

    func tail() -> (l: [Float], r: [Float]) { ([], []) }
}

extension StereoPlacement: PureStage {
    func update(from fx: EffectsParameters) {
        targetPan = min(max(fx.placementPan, -1), 1)
        targetWidth = min(max(fx.placementWidth, 0), 2)
    }
}

#endif  // !os(watchOS)
