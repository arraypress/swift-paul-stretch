import XCTest
@testable import PaulStretch

/// How many realtime-seconds of stretched audio one core can synthesise per
/// wall-clock second. This decides whether a multitrack app can stretch
/// clips just-in-time or must pre-render each one to a cache.
final class DawFeasibilityTests: XCTestCase {
    func testStretchThroughputPerCore() throws {
        let sr = 44100.0
        let n = Int(sr * 10)
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            let t = Double(i) / sr
            l[i] = Float(0.3 * sin(2 * .pi * 110 * t) + 0.2 * sin(2 * .pi * 277 * t))
            r[i] = l[i]
        }
        let src = StereoBuffer(l: l, r: r, sampleRate: sr)

        for mode in [StretchMode.paulStretch, .spectralFreeze, .granularCloud] {
            var p = StretchParameters()
            p.mode = mode
            p.targetSeconds = 60
            p.fadeInSeconds = 0; p.fadeOutSeconds = 0
            let t0 = Date()
            _ = StretchRenderer.render(src, parameters: p, isCancelled: { false })
            let dt = Date().timeIntervalSince(t0)
            let xRealtime = 60.0 / dt
            print(String(format: "BENCH %-16@ %6.1fx realtime  (%.2fs for 60s)  ~%.1f%% of one core per track",
                         mode.rawValue as NSString, xRealtime, dt, 100.0 / xRealtime))
        }
    }
}
