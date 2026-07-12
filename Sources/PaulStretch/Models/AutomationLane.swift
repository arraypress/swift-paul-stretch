//
//  AutomationLane.swift
//  SwiftPaulStretch
//
//  Spline-based parameter automation: normalised (t, v) points sampled with
//  cardinal (Catmull-Rom family) interpolation — naturally smooth curves,
//  because drone material doesn't like sharp transitions.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// One anchor of an ``AutomationLane`` — both coordinates normalised `0…1`.
public struct AutomationPoint: Sendable, Codable, Equatable {
    /// Position along the timeline, `0…1`.
    public var t: Double
    /// The parameter value at that position, `0…1`.
    public var v: Double

    public init(t: Double, v: Double) {
        self.t = t
        self.v = v
    }
}

/// A smooth parameter curve over a render's timeline.
///
/// Lanes let a parameter *travel* across a piece — a filter opening over
/// twenty minutes, a shimmer blooming in the second half — which is the
/// difference between processing a drone and composing one. Points are
/// normalised on both axes; sampling interpolates with a cardinal spline:
///
/// - `tension 0` — standard Catmull-Rom: smooth, may gently overshoot anchors.
/// - `tension 1` — zero tangents at anchors: tight, flat-topped, no overshoot.
///
/// ```swift
/// var fx = EffectsParameters()
/// fx.sweepFilterEnabled = true
/// fx.parameterLanes["sweepFilter.cutoff"] = AutomationLane(points: [
///     AutomationPoint(t: 0, v: 0.1),      // closed at the start
///     AutomationPoint(t: 1, v: 0.9),      // open by the end
/// ])
/// ```
public struct AutomationLane: Sendable, Codable, Equatable {

    /// The anchors, in ascending `t` order.
    public var points: [AutomationPoint]

    /// Spline tension, `0…1` (see the type overview).
    public var tension: Double

    public init(points: [AutomationPoint], tension: Double = 0) {
        self.points = points
        self.tension = tension
    }

    /// Samples the curve at a normalised time.
    ///
    /// Before the first point the first value holds; after the last point
    /// the last value holds. An empty lane returns `0`.
    ///
    /// - Parameter t: The position, `0…1`.
    /// - Returns: The interpolated value, `0…1` territory (Catmull-Rom may
    ///   overshoot slightly between anchors at `tension 0`).
    public func value(at t: Double) -> Double {
        if points.isEmpty { return 0 }
        if points.count == 1 { return points[0].v }
        if t <= points[0].t { return points[0].v }
        if t >= points[points.count - 1].t { return points[points.count - 1].v }

        var i = 0
        while i < points.count - 2 && t > points[i + 1].t { i += 1 }
        let p1 = points[i]
        let p2 = points[i + 1]
        let p0 = i > 0 ? points[i - 1] : p1
        let p3 = i + 2 < points.count ? points[i + 2] : p2
        let span = max(1e-9, p2.t - p1.t)
        let localT = (t - p1.t) / span
        return Self.cardinalSpline(p0.v, p1.v, p2.v, p3.v, localT: localT, tension: tension)
    }

    /// Cardinal spline between `p1` and `p2` with `p0`/`p3` as tangent
    /// neighbours — standard Hermite basis with scaled tangents
    /// `m = ((1 − τ)/2)·(p_next − p_prev)`.
    static func cardinalSpline(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double,
                               localT: Double, tension: Double) -> Double {
        let s = (1 - min(max(tension, 0), 1)) / 2
        let m1 = s * (p2 - p0)
        let m2 = s * (p3 - p1)
        let t2 = localT * localT
        let t3 = t2 * localT
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + localT
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * p1 + h10 * m1 + h01 * p2 + h11 * m2
    }
}
