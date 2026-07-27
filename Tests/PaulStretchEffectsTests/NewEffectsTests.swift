//
//  NewEffectsTests.swift
//  Parametric EQ migration, stereo placement and the trance gate.
//

import XCTest
import PaulStretch
@testable import PaulStretchEffects

#if !os(watchOS)

final class NewEffectsTests: XCTestCase {

    private let sr = 44100.0

    private func buffer(_ seconds: Double, stereoSpread: Bool = false) -> StereoBuffer {
        let n = Int(sr * seconds)
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            let t = Double(i) / sr
            l[i] = Float(0.4 * sin(2 * .pi * 200 * t))
            r[i] = Float(0.4 * sin(2 * .pi * (stereoSpread ? 320 : 200) * t))
        }
        return StereoBuffer(l: l, r: r, sampleRate: sr)
    }

    // MARK: - EQ

    /// A current preset must round-trip its bands exactly.
    func testEQBandsRoundTrip() throws {
        var fx = EffectsParameters()
        fx.eqEnabled = true
        fx.eqBands[2].enabled = true
        fx.eqBands[2].frequency = 777
        fx.eqBands[2].gain = -6
        fx.eqBands[2].bandwidth = 0.3

        let data = try JSONEncoder().encode(fx)
        let back = try JSONDecoder().decode(EffectsParameters.self, from: data)
        XCTAssertEqual(back.eqBands, fx.eqBands)
    }

    /// Defaults must be inaudible — switching the EQ on should do nothing
    /// until a band is dialled in.
    func testDefaultEQBandsAreFlatAndOff() {
        for b in EQBand.defaultBands {
            XCTAssertFalse(b.enabled)
            XCTAssertEqual(b.gain, 0)
        }
    }

    // MARK: - Placement

    /// Centre must be unity gain, not the 3 dB dip a naive equal-power pan
    /// leaves behind.
    func testCentrePanIsUnityGain() {
        let src = buffer(0.5)
        let out = StereoPlacement(pan: 0, width: 1).process(l: src.l, r: src.r)
        var worst: Float = 0
        for i in 0..<src.l.count { worst = max(worst, abs(out.l[i] - src.l[i])) }
        XCTAssertLessThan(worst, 1e-5, "centre pan altered the signal by \(worst)")
    }

    /// Panning right must move energy right.
    func testPanShiftsEnergy() {
        let src = buffer(0.5)
        let out = StereoPlacement(pan: 1, width: 1).process(l: src.l, r: src.r)
        func rms(_ a: [Float]) -> Float { (a.reduce(0) { $0 + $1 * $1 } / Float(a.count)).squareRoot() }
        XCTAssertLessThan(rms(out.l), 0.01, "hard right still had left content")
        XCTAssertGreaterThan(rms(out.r), 0.1)
    }

    /// Width 0 must collapse to mono: both channels identical.
    func testZeroWidthCollapsesToMono() {
        let src = buffer(0.5, stereoSpread: true)
        let out = StereoPlacement(pan: 0, width: 0).process(l: src.l, r: src.r)
        var worst: Float = 0
        for i in 0..<out.l.count { worst = max(worst, abs(out.l[i] - out.r[i])) }
        XCTAssertLessThan(worst, 1e-5, "width 0 left \(worst) of stereo difference")
    }

    /// Width 2 must widen, not just get louder.
    func testWidthTwoIncreasesSideEnergy() {
        let src = buffer(0.5, stereoSpread: true)
        func side(_ p: (l: [Float], r: [Float])) -> Float {
            var e: Float = 0
            for i in 0..<p.l.count { let s = (p.l[i] - p.r[i]) * 0.5; e += s * s }
            return (e / Float(p.l.count)).squareRoot()
        }
        let normal = StereoPlacement(pan: 0, width: 1).process(l: src.l, r: src.r)
        let wide = StereoPlacement(pan: 0, width: 2).process(l: src.l, r: src.r)
        XCTAssertGreaterThan(side(wide), side(normal) * 1.8)
    }

    // MARK: - Trance gate

    private func gate(_ fx: EffectsParameters, seconds: Double = 2.0,
                      chunk: Int = 512) -> StereoBuffer {
        let src = buffer(seconds)
        let stages = makePureStages(sampleRate: sr, effects: fx, totalFrames: src.frameCount)
        var outL = [Float](), outR = [Float]()
        var pos = 0
        while pos < src.frameCount {
            let n = min(chunk, src.frameCount - pos)
            var l = Array(src.l[pos..<pos+n]), r = Array(src.r[pos..<pos+n])
            for s in stages { let o = s.process(l: l, r: r); l = o.l; r = o.r }
            outL += l; outR += r
            pos += n
        }
        return StereoBuffer(l: outL, r: outR, sampleRate: sr)
    }

    private func gateParams() -> EffectsParameters {
        var fx = EffectsParameters()
        fx.tranceGateEnabled = true
        fx.tranceGateRateHz = 8
        fx.tranceGateDepth = 1
        fx.tranceGatePattern = TranceGatePattern.eighths
        return fx
    }

    /// The gate must actually produce rhythm: alternating loud and quiet.
    func testGateProducesRhythm() {
        let out = gate(gateParams())
        let win = Int(sr / 16)          // half a step at 8 Hz
        var levels = [Float]()
        var i = Int(sr * 0.2)
        while i + win < out.frameCount {
            var e: Float = 0
            for j in i..<(i + win) { e += out.l[j] * out.l[j] }
            levels.append((e / Float(win)).squareRoot())
            i += win
        }
        let hi = levels.max() ?? 0, lo = levels.min() ?? 0
        XCTAssertGreaterThan(hi, 0.1, "gate silenced everything")
        XCTAssertLessThan(lo, hi * 0.3, "gate produced no rhythm (hi \(hi), lo \(lo))")
    }

    /// The reason smoothing exists: a hard gate clicks. No sample-to-sample
    /// jump may exceed what the source itself contains.
    func testGateDoesNotClick() {
        var fx = gateParams()
        fx.tranceGateSmoothingMs = 8
        let out = gate(fx)
        var worstJump: Float = 0
        for i in 1..<out.frameCount {
            worstJump = max(worstJump, abs(out.l[i] - out.l[i - 1]))
        }
        // The 200 Hz source itself steps ~0.036 per sample at peak slope.
        XCTAssertLessThan(worstJump, 0.06,
                          "gate edge produced a \(worstJump) discontinuity — that clicks")
    }

    /// The pattern is locked to absolute time, so chunk size must not shift
    /// the rhythm.
    func testGateIsChunkSizeIndependent() {
        let a = gate(gateParams(), chunk: 256)
        let b = gate(gateParams(), chunk: 1024)
        var worst: Float = 0
        for i in 0..<min(a.frameCount, b.frameCount) {
            worst = max(worst, abs(a.l[i] - b.l[i]))
        }
        XCTAssertLessThan(worst, 1e-6, "chunking shifted the gate by \(worst)")
    }

    /// A stereo offset must decorrelate the channels (ping-pong).
    func testGateStereoOffsetSplitsChannels() {
        var fx = gateParams()
        fx.tranceGateStereoOffset = 1
        let out = gate(fx)
        var diff: Float = 0
        for i in 0..<out.frameCount { diff += abs(out.l[i] - out.r[i]) }
        XCTAssertGreaterThan(diff / Float(out.frameCount), 0.01,
                             "stereo offset produced identical channels")
    }

    /// Depth 0 must be a true bypass.
    func testGateDepthZeroIsTransparent() {
        var fx = gateParams()
        fx.tranceGateDepth = 0
        let out = gate(fx)
        let src = buffer(2.0)
        var worst: Float = 0
        for i in 0..<out.frameCount { worst = max(worst, abs(out.l[i] - src.l[i])) }
        XCTAssertLessThan(worst, 1e-5, "depth 0 was not transparent (\(worst))")
    }
}

#endif
