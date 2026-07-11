//
//  StereoBufferTests.swift
//  Tests for SwiftPaulStretch
//
//  Source/output shaping transforms: trim, normalise, reverse, tape speed,
//  stereo width, fades and the seamless loop crossfade.
//
//  Created by David Sherlock on 7/12/26.
//

import XCTest
@testable import PaulStretch

final class StereoBufferTests: XCTestCase {

    // MARK: - Trim / normalise / reverse

    func testTrimmedCutsTheRequestedRegion() {
        let src = TestSignals.source(seconds: 2.0)
        let cut = src.trimmed(fromSeconds: 0.5, toSeconds: 1.25)
        XCTAssertEqual(cut.frameCount, Int(0.75 * 44_100))
        XCTAssertEqual(cut.l[0], src.l[Int(0.5 * 44_100)])
    }

    func testTrimmedClampsOutOfRangeTimes() {
        let src = TestSignals.source(seconds: 1.0)
        let cut = src.trimmed(fromSeconds: -5, toSeconds: 99)
        XCTAssertEqual(cut.frameCount, src.frameCount)
        let degenerate = src.trimmed(fromSeconds: 10, toSeconds: 12)
        XCTAssertGreaterThanOrEqual(degenerate.frameCount, 1)
    }

    func testPeakNormalizedHitsTarget() {
        let quiet = TestSignals.sine(440, seconds: 0.25, amplitude: 0.1)
        let normalized = quiet.peakNormalized(to: 0.98)
        XCTAssertEqual(normalized.peak, 0.98, accuracy: 1e-4)
        let silent = StereoBuffer(silenceFrames: 100, sampleRate: 44_100)
        XCTAssertEqual(silent.peakNormalized().peak, 0, "silence must stay silent")
    }

    func testReversedFlipsTheBuffer() {
        let src = TestSignals.source(seconds: 0.5)
        let rev = src.reversed()
        XCTAssertEqual(rev.frameCount, src.frameCount)
        XCTAssertEqual(rev.l[0], src.l[src.frameCount - 1])
        assertSamplesIdentical(rev.reversed().l, src.l, "double reverse")
    }

    // MARK: - Tape speed

    func testTapeSpeedHalvesPitchAndDoublesLength() {
        let src = TestSignals.sine(440, seconds: 1.0)
        let slow = src.applyingTapeSpeed(0.5)
        XCTAssertEqual(slow.frameCount, src.frameCount * 2)
        XCTAssertEqual(zeroCrossingFrequency(slow), 220, accuracy: 5,
                       "half speed should halve the pitch")
    }

    func testTapeSpeedNearUnityIsPassthrough() {
        let src = TestSignals.source(seconds: 0.5)
        let out = src.applyingTapeSpeed(1.0004)
        assertSamplesIdentical(out.l, src.l, "speed ≈ 1 must return the input")
    }

    // MARK: - Stereo width

    func testStereoWidthZeroCollapsesToMono() {
        let src = TestSignals.source(seconds: 0.25)
        let mono = src.applyingStereoWidth(0)
        assertSamplesIdentical(mono.l, mono.r, "width 0 must be mono")
    }

    func testStereoWidthUnityIsPassthrough() {
        let src = TestSignals.source(seconds: 0.25)
        let out = src.applyingStereoWidth(1.0)
        assertSamplesIdentical(out.l, src.l, "width 1 must return the input")
    }

    // MARK: - Fades

    func testFadesShapeTheEnds() {
        let src = TestSignals.sine(440, seconds: 2.0, amplitude: 0.9)
        let faded = src.applyingFades(fadeInSeconds: 0.1, fadeOutSeconds: 0.1)
        XCTAssertEqual(faded.l[0], 0, "fade-in must start at silence")
        XCTAssertEqual(abs(faded.l[faded.frameCount - 1]), 0, accuracy: 1e-3,
                       "fade-out must end near silence")
        let mid = faded.frameCount / 2
        XCTAssertEqual(faded.l[mid], src.l[mid], "the middle must be untouched")
    }

    func testFadesAreCappedRelativeToLength() {
        // A 1 s buffer with 20 s fades: fade-in caps at 10 %, fade-out at 15 %.
        let src = TestSignals.sine(440, seconds: 1.0, amplitude: 0.9)
        let faded = src.applyingFades(fadeInSeconds: 20, fadeOutSeconds: 30)
        let quarter = faded.frameCount / 4
        XCTAssertEqual(faded.l[quarter], src.l[quarter],
                       "capped fades must not reach 25% in")
    }

    // MARK: - Seamless loop

    func testSeamlesslyLoopedAppliesEqualPowerCrossfade() {
        let sr = 44_100.0
        let n = Int(sr * 2)
        let src = StereoBuffer(l: [Float](repeating: 0.5, count: n),
                               r: [Float](repeating: 0.5, count: n),
                               sampleRate: sr)
        let xfSeconds = 0.5
        let looped = src.seamlesslyLooped(crossfadeSeconds: xfSeconds)
        let xf = Int(xfSeconds * sr)
        XCTAssertEqual(looped.frameCount, n - xf)

        // For a constant signal the equal-power crossfade is
        // 0.5·(√k + √(1−k)) — check the formula at a few points.
        for i in [0, xf / 3, xf / 2, xf - 1] {
            let k = Float(i) / Float(xf)
            let expected = 0.5 * (k.squareRoot() + (1 - k).squareRoot())
            XCTAssertEqual(looped.l[i], expected, accuracy: 1e-5, "crossfade sample \(i)")
        }
        XCTAssertEqual(looped.l[xf + 10], 0.5, "post-crossfade must be untouched")
    }

    func testSeamlesslyLoopedPassthroughWhenTooShort() {
        let src = TestSignals.source(seconds: 0.01)
        let looped = src.seamlesslyLooped(crossfadeSeconds: 6)
        XCTAssertEqual(looped.frameCount, src.frameCount,
                       "buffers too short to donate a crossfade must pass through")
    }

    // MARK: - Codable

    func testStretchParametersRoundTripThroughJSON() throws {
        var p = StretchParameters()
        p.mode = .spectralFreeze
        p.layering = .lush
        p.targetSeconds = 123
        p.freezeSmear = 0.42
        p.seamlessLoop = true
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(StretchParameters.self, from: data)
        XCTAssertEqual(decoded, p)
    }

    // MARK: - Helpers

    /// Frequency estimate from zero-crossing count.
    private func zeroCrossingFrequency(_ b: StereoBuffer) -> Double {
        var crossings = 0
        for i in 1..<b.frameCount where (b.l[i - 1] < 0) != (b.l[i] < 0) {
            crossings += 1
        }
        return Double(crossings) / (2 * b.duration)
    }
}
