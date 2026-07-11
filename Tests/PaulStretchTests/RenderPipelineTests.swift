//
//  RenderPipelineTests.swift
//  Tests for SwiftPaulStretch
//
//  Behavioural tests of the full pipeline: modes, tiling, freeze character,
//  looping and seeded variations.
//
//  Created by David Sherlock on 7/12/26.
//

import XCTest
@testable import PaulStretch

final class RenderPipelineTests: XCTestCase {

    private func params(_ mutate: (inout StretchParameters) -> Void = { _ in }) -> StretchParameters {
        var p = StretchParameters()
        p.targetSeconds = 4
        p.windowSeconds = 0.12
        p.fadeInSeconds = 0.5
        p.fadeOutSeconds = 0.5
        mutate(&p)
        return p
    }

    // MARK: - Basic contract

    func testRenderHitsTheTargetDuration() {
        let source = TestSignals.source(seconds: 1.2)
        let out = StretchRenderer.render(source, parameters: params())
        XCTAssertEqual(out.duration, 4, accuracy: 0.01)
        XCTAssertGreaterThan(out.rms, 0.02, "render should not be near-silent")
        XCTAssertFalse(out.l.contains { $0.isNaN }, "no NaNs allowed")
    }

    func testLoopRenderTrimsTheCrossfadeAndStaysSeamless() {
        let source = TestSignals.source(seconds: 1.2)
        // Target 18 s so the full 6 s crossfade fits (it is capped at a
        // quarter of the rendered length): 24 s rendered − 6 s trim = 18 s.
        let p = params { $0.seamlessLoop = true; $0.targetSeconds = 18 }
        let out = StretchRenderer.render(source, parameters: p)
        XCTAssertEqual(out.duration, 18, accuracy: 0.01)

        // The loop seam (end → start) should be as smooth as the interior:
        // compare the end/start RMS over 50 ms windows — a hard seam would
        // show as silence or a spike at either edge.
        let w = Int(0.05 * out.sampleRate)
        let head = StereoBuffer(l: Array(out.l[0..<w]), r: Array(out.r[0..<w]), sampleRate: out.sampleRate)
        let tail = StereoBuffer(l: Array(out.l[(out.frameCount - w)...].map { $0 }),
                                r: Array(out.r[(out.frameCount - w)...].map { $0 }),
                                sampleRate: out.sampleRate)
        XCTAssertGreaterThan(head.rms, 0.02, "loop head must not fade to silence")
        XCTAssertGreaterThan(tail.rms, 0.02, "loop tail must not fade to silence")
    }

    func testTilingFillsTheTargetWhenTheStretchCapIsHit() {
        let source = TestSignals.source(seconds: 1.2)
        let p = params { $0.layering = .off; $0.maxStretch = 1.5; $0.targetSeconds = 6 }
        let out = StretchRenderer.render(source, parameters: p)
        XCTAssertEqual(out.duration, 6, accuracy: 0.01)
        // The middle of the render (past the first tile) must still carry audio.
        let midStart = out.frameCount / 2
        let w = Int(0.25 * out.sampleRate)
        let mid = StereoBuffer(l: Array(out.l[midStart..<midStart + w]),
                               r: Array(out.r[midStart..<midStart + w]),
                               sampleRate: out.sampleRate)
        XCTAssertGreaterThan(mid.rms, 0.02, "tiled render must not go silent between tiles")
    }

    // MARK: - Modes

    func testTapeSlowLowersThePitch() {
        let source = TestSignals.sine(440, seconds: 1.5)
        let p = params { $0.mode = .tapeSlow; $0.tapeSpeed = 0.5; $0.fadeInSeconds = 0; $0.fadeOutSeconds = 0 }
        let out = StretchRenderer.render(source, parameters: p)
        var crossings = 0
        for i in 1..<out.frameCount where (out.l[i - 1] < 0) != (out.l[i] < 0) { crossings += 1 }
        let hz = Double(crossings) / (2 * out.duration)
        XCTAssertEqual(hz, 220, accuracy: 8, "half tape speed should halve the pitch")
    }

    func testFreezeKeepsTheSourceTone() {
        // Freeze a pure 330 Hz tone with no smear: the sustained output's
        // dominant frequency must stay at ~330 Hz.
        let source = TestSignals.sine(330, seconds: 1.5)
        let p = params { $0.mode = .spectralFreeze; $0.freezeSmear = 0; $0.windowSeconds = 0.2 }
        let out = StretchRenderer.render(source, parameters: p)

        let n = 8192
        guard let fft = PSFFT(n: n) else { return XCTFail() }
        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)
        let start = out.frameCount / 2
        for i in 0..<n {
            let w = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)))
            real[i] = out.l[start + i] * w
        }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                fft.forward(rp.baseAddress!, ip.baseAddress!)
            }
        }
        var bestBin = 0
        var bestMag: Float = 0
        for k in 1..<(n / 2) {
            let m = real[k] * real[k] + imag[k] * imag[k]
            if m > bestMag { bestMag = m; bestBin = k }
        }
        let hz = Double(bestBin) * out.sampleRate / Double(n)
        XCTAssertEqual(hz, 330, accuracy: 20, "the frozen spectrum should keep the source tone")
    }

    func testFreezeSmearFlattensTheSpectrum() {
        let source = TestSignals.sine(330, seconds: 1.5)
        let tonal = StretchRenderer.render(source, parameters: params {
            $0.mode = .spectralFreeze; $0.freezeSmear = 0
        })
        let washed = StretchRenderer.render(source, parameters: params {
            $0.mode = .spectralFreeze; $0.freezeSmear = 1
        })
        // Smearing blurs the 330 Hz peak into neighbouring bins, so the
        // share of spectral energy concentrated at the tone must fall.
        let tonalShare = toneEnergyShare(tonal, hz: 330)
        let washedShare = toneEnergyShare(washed, hz: 330)
        XCTAssertLessThan(washedShare, tonalShare * 0.5,
                          "full smear should spread the tonal peak into the spectrum")
    }

    /// Fraction of (lower-half) spectral energy within ±3 bins of `hz`,
    /// measured on a Hann-windowed FFT from the middle of the buffer.
    private func toneEnergyShare(_ b: StereoBuffer, hz: Double) -> Double {
        let n = 8192
        guard b.frameCount >= n, let fft = PSFFT(n: n) else { return 0 }
        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)
        let start = (b.frameCount - n) / 2
        for i in 0..<n {
            let w = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)))
            real[i] = b.l[start + i] * w
        }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                fft.forward(rp.baseAddress!, ip.baseAddress!)
            }
        }
        let bin = Int((hz / b.sampleRate * Double(n)).rounded())
        var toneEnergy = 0.0
        var totalEnergy = 0.0
        for k in 1..<(n / 2) {
            let m = Double(real[k] * real[k] + imag[k] * imag[k])
            totalEnergy += m
            if abs(k - bin) <= 3 { toneEnergy += m }
        }
        return totalEnergy > 0 ? toneEnergy / totalEnergy : 0
    }

    // MARK: - Seeds

    func testVariationSeedsProduceDistinctRenders() {
        let source = TestSignals.source(seconds: 1.0)
        let p = params { $0.layering = .off }
        let a = StretchRenderer.render(source, parameters: p, seed: StretchRenderer.variationSeed(0))
        let b = StretchRenderer.render(source, parameters: p, seed: StretchRenderer.variationSeed(1))
        XCTAssertEqual(a.frameCount, b.frameCount)
        XCTAssertNotEqual(a.l, b.l, "variation seeds must differ audibly")
        XCTAssertEqual(StretchRenderer.variationSeed(0), PaulStretcher.defaultSeed,
                       "variation 0 is the default seed")
    }

    func testRenderIsFullyDeterministic() {
        let source = TestSignals.source(seconds: 1.0)
        let p = params { $0.layering = .standard; $0.seamlessLoop = true }
        let a = StretchRenderer.render(source, parameters: p)
        let b = StretchRenderer.render(source, parameters: p)
        assertSamplesIdentical(a.l, b.l, "determinism left")
        assertSamplesIdentical(a.r, b.r, "determinism right")
    }

    // MARK: - Cancellation

    func testCancelledPipelineRenderReturnsEmpty() {
        let source = TestSignals.source(seconds: 1.0)
        let out = StretchRenderer.render(source, parameters: params(), isCancelled: { true })
        XCTAssertTrue(out.isEmpty)
    }
}
