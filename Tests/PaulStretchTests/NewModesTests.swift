//
//  NewModesTests.swift
//  Tests for SwiftPaulStretch
//
//  The v1.1 algorithms: shimmer layers, scanning freeze, phase-vocoder
//  stretch and the granular cloud — including chunked-equality for each.
//
//  Created by David Sherlock on 7/12/26.
//

import XCTest
@testable import PaulStretch

final class NewModesTests: XCTestCase {

    private func params(_ mutate: (inout StretchParameters) -> Void = { _ in }) -> StretchParameters {
        var p = StretchParameters()
        p.targetSeconds = 4
        p.windowSeconds = 0.12
        p.fadeInSeconds = 0.5
        p.fadeOutSeconds = 0.5
        mutate(&p)
        return p
    }

    /// Renders via renderChunks and reassembles the timeline.
    private func assembleChunked(_ source: StereoBuffer, _ p: StretchParameters) -> StereoBuffer {
        var l: [Float] = []
        var r: [Float] = []
        StretchRenderer.renderChunks(source, parameters: p, chunkFrames: 25_000) { chunk in
            l.append(contentsOf: chunk.l)
            r.append(contentsOf: chunk.r)
        }
        return StereoBuffer(l: l, r: r, sampleRate: source.sampleRate)
    }

    /// Fraction of (lower-half) spectral energy within ±3 bins of `hz`.
    private func toneEnergyShare(_ b: StereoBuffer, hz: Double, atFrame start: Int) -> Double {
        let n = 8192
        guard start + n <= b.frameCount, let fft = PSFFT(n: n) else { return 0 }
        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)
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
        var tone = 0.0, total = 0.0
        for k in 1..<(n / 2) {
            let m = Double(real[k] * real[k] + imag[k] * imag[k])
            total += m
            if abs(k - bin) <= 3 { tone += m }
        }
        return total > 0 ? tone / total : 0
    }

    // MARK: - Shimmer layers

    func testShimmerAddsAnOctaveVoice() {
        let source = TestSignals.sine(220, seconds: 1.2)
        let plain = StretchRenderer.render(source, parameters: params { $0.layering = .standard },
                                           isCancelled: { false })
        let shimmer = StretchRenderer.render(source, parameters: params { $0.layering = .shimmer },
                                             isCancelled: { false })
        let mid = plain.frameCount / 2
        let octavePlain = toneEnergyShare(plain, hz: 440, atFrame: mid)
        let octaveShimmer = toneEnergyShare(shimmer, hz: 440, atFrame: mid)
        XCTAssertGreaterThan(octaveShimmer, octavePlain * 3 + 0.02,
                             "shimmer must add clear octave-up energy")
    }

    func testShimmerPresetsExposeRecipes() {
        XCTAssertEqual(LayerPreset.allCases.count, 6)
        XCTAssertEqual(LayerPreset.shimmer.layers?.count, 3)
        XCTAssertTrue(LayerPreset.shimmer.layers?.contains { $0.pitch == 12 } ?? false)
        XCTAssertTrue(LayerPreset.shimmerDeep.layers?.contains { $0.pitch == -12 } ?? false)
        // Legacy presets must stay unshifted (bit-compatibility).
        XCTAssertTrue(LayerPreset.standard.layers?.allSatisfy { $0.pitch == 0 } ?? false)
        XCTAssertTrue(LayerPreset.lush.layers?.allSatisfy { $0.pitch == 0 } ?? false)
    }

    // MARK: - Scanning freeze

    func testScanningFreezeMorphsTheSpectrum() {
        // Source: first half 330 Hz, second half 660 Hz. A full scan should
        // start near 330 and end near 660; a static freeze stays at 330.
        let sr = 44_100.0
        let n = Int(sr * 1.5)
        var l = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            let hz = i < n / 2 ? 330.0 : 660.0
            l[i] = 0.5 * Float(sin(2 * Double.pi * hz * t))
        }
        let source = StereoBuffer(l: l, r: l, sampleRate: sr)

        let p = params {
            $0.mode = .spectralFreeze
            $0.freezePosition = 0
            $0.freezeSmear = 0
            $0.freezeScan = 1
            $0.fadeInSeconds = 0
            $0.fadeOutSeconds = 0
        }
        let out = StretchRenderer.render(source, parameters: p, isCancelled: { false })
        let early330 = toneEnergyShare(out, hz: 330, atFrame: 8192)
        let late660 = toneEnergyShare(out, hz: 660, atFrame: out.frameCount - 16_384)
        XCTAssertGreaterThan(early330, 0.4, "scan start should sound like the source's start")
        XCTAssertGreaterThan(late660, 0.4, "scan end should sound like the source's end")
    }

    func testScanZeroMatchesTheStaticFreezeExactly() {
        let source = TestSignals.source(seconds: 1.2)
        let staticP = params { $0.mode = .spectralFreeze; $0.freezeSmear = 0.3 }
        let scanZeroP = params { $0.mode = .spectralFreeze; $0.freezeSmear = 0.3; $0.freezeScan = 0 }
        let a = StretchRenderer.render(source, parameters: staticP, isCancelled: { false })
        let b = StretchRenderer.render(source, parameters: scanZeroP, isCancelled: { false })
        assertSamplesIdentical(a.l, b.l, "scan 0 must be the classic static freeze")
    }

    // MARK: - Phase vocoder

    func testPhaseVocoderKeepsPitchWhileStretching() {
        let source = TestSignals.sine(440, seconds: 1.0)
        let p = params {
            $0.mode = .phaseVocoder
            $0.windowSeconds = 0.08
            $0.fadeInSeconds = 0
            $0.fadeOutSeconds = 0
        }
        let out = StretchRenderer.render(source, parameters: p, isCancelled: { false })
        XCTAssertEqual(out.duration, 4, accuracy: 0.01)
        let share = toneEnergyShare(out, hz: 440, atFrame: out.frameCount / 2)
        XCTAssertGreaterThan(share, 0.5, "PV must keep the source pitch dominant")
        XCTAssertEqual(out.peak, 0.92, accuracy: 1e-3)
    }

    func testPhaseVocoderIsSmootherThanPaulStretch() {
        // The whole point of PV: dramatically lower amplitude flutter than
        // the phase-randomised stretch. Compare RMS coefficient-of-variation
        // over ~46 ms frames (the CLAUDE-documented flutter metric).
        let source = TestSignals.sine(330, seconds: 1.0)
        func flutterCV(_ b: StereoBuffer) -> Double {
            let w = 2048
            var rmses: [Double] = []
            var i = w * 4
            while i + w <= b.frameCount - w * 4 {
                var acc = 0.0
                for j in i..<(i + w) { acc += Double(b.l[j]) * Double(b.l[j]) }
                rmses.append((acc / Double(w)).squareRoot())
                i += w
            }
            let mean = rmses.reduce(0, +) / Double(rmses.count)
            let variance = rmses.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rmses.count)
            return variance.squareRoot() / mean
        }
        let pv = StretchRenderer.render(source, parameters: params {
            $0.mode = .phaseVocoder; $0.windowSeconds = 0.08
            $0.fadeInSeconds = 0; $0.fadeOutSeconds = 0
        }, isCancelled: { false })
        let ps = StretchRenderer.render(source, parameters: params {
            $0.mode = .paulStretch; $0.layering = .off; $0.windowSeconds = 0.08
            $0.fadeInSeconds = 0; $0.fadeOutSeconds = 0
        }, isCancelled: { false })
        XCTAssertLessThan(flutterCV(pv), flutterCV(ps) * 0.5,
                          "PV should flutter far less than the random-phase stretch")
    }

    // MARK: - Granular cloud

    func testGranularCloudFillsTheTargetAndSpreadsTheField() {
        let source = TestSignals.source(seconds: 1.2)
        let p = params {
            $0.mode = .granularCloud
            $0.grainPanSpread = 1.0
            $0.fadeInSeconds = 0
            $0.fadeOutSeconds = 0
        }
        let out = StretchRenderer.render(source, parameters: p, isCancelled: { false })
        XCTAssertEqual(out.duration, 4, accuracy: 0.01)
        XCTAssertGreaterThan(out.rms, 0.02, "cloud must carry audio")
        XCTAssertEqual(out.peak, 0.92, accuracy: 1e-3)
        XCTAssertNotEqual(out.l, out.r, "pan spread must decorrelate the channels")
        XCTAssertFalse(out.l.contains { $0.isNaN })
    }

    func testGranularPitchSpreadWidensTheSpectrum() {
        let source = TestSignals.sine(440, seconds: 1.2)
        let focused = StretchRenderer.render(source, parameters: params {
            $0.mode = .granularCloud; $0.grainPitchSpread = 0
            $0.fadeInSeconds = 0; $0.fadeOutSeconds = 0
        }, isCancelled: { false })
        let spread = StretchRenderer.render(source, parameters: params {
            $0.mode = .granularCloud; $0.grainPitchSpread = 12
            $0.fadeInSeconds = 0; $0.fadeOutSeconds = 0
        }, isCancelled: { false })
        let focusedShare = toneEnergyShare(focused, hz: 440, atFrame: focused.frameCount / 2)
        let spreadShare = toneEnergyShare(spread, hz: 440, atFrame: spread.frameCount / 2)
        XCTAssertLessThan(spreadShare, focusedShare * 0.6,
                          "pitch spread should scatter energy away from the source tone")
    }

    // MARK: - Chunked equality for every new mode

    func testChunkedMatchesInMemoryForNewModes() {
        let source = TestSignals.source(seconds: 1.2)
        let matrix: [(String, StretchParameters)] = [
            ("shimmer", params { $0.layering = .shimmer }),
            ("shimmer-deep-loop", params { $0.layering = .shimmerDeep; $0.seamlessLoop = true }),
            ("scan-freeze", params { $0.mode = .spectralFreeze; $0.freezeScan = 0.8; $0.freezeSmear = 0.2 }),
            ("scan-freeze-loop", params { $0.mode = .spectralFreeze; $0.freezeScan = 1; $0.seamlessLoop = true }),
            ("pv", params { $0.mode = .phaseVocoder; $0.windowSeconds = 0.08 }),
            ("pv-loop", params { $0.mode = .phaseVocoder; $0.windowSeconds = 0.08; $0.seamlessLoop = true }),
            ("pv-pitch", params { $0.mode = .phaseVocoder; $0.windowSeconds = 0.08; $0.pitchSemitones = 7 }),
            ("granular", params { $0.mode = .granularCloud; $0.grainPitchSpread = 5 }),
            ("granular-loop", params { $0.mode = .granularCloud; $0.seamlessLoop = true }),
        ]
        for (name, p) in matrix {
            let full = StretchRenderer.render(source, parameters: p, isCancelled: { false })
            let chunked = assembleChunked(source, p)
            XCTAssertEqual(chunked.frameCount, full.frameCount, "\(name): length")
            assertSamplesIdentical(chunked.l, full.l, "\(name) left")
            assertSamplesIdentical(chunked.r, full.r, "\(name) right")
        }
    }

    // MARK: - Determinism + geometry

    func testNewModesAreDeterministicAndPredictable() {
        let source = TestSignals.source(seconds: 1.0)
        for p in [params { $0.mode = .granularCloud },
                  params { $0.mode = .phaseVocoder; $0.windowSeconds = 0.08 },
                  params { $0.mode = .spectralFreeze; $0.freezeScan = 0.5 },
                  params { $0.layering = .shimmer }] {
            let a = StretchRenderer.render(source, parameters: p, isCancelled: { false })
            let b = StretchRenderer.render(source, parameters: p, isCancelled: { false })
            assertSamplesIdentical(a.l, b.l, "determinism \(p.mode)")
            XCTAssertEqual(StretchRenderer.outputFrameCount(source, parameters: p), a.frameCount,
                           "outputFrameCount \(p.mode)")
        }
    }

    // MARK: - Preset compatibility

    func testOldPresetJSONStillDecodes() throws {
        // A v1.0.0-era preset knows nothing of freezeScan or the grain
        // fields — it must decode with defaults, not throw.
        let legacyJSON = """
        {"mode":"paulStretch","targetSeconds":120,"maxStretch":1500,
         "layering":"standard","windowSeconds":0.25,"phaseRandomness":1,
         "pitchSemitones":0,"onsetSensitivity":0,"tapeSpeed":1,"reverse":false,
         "stereoWidth":1,"freezePosition":0.5,"freezeSmear":0.1,
         "seamlessLoop":true,"fadeInSeconds":20,"fadeOutSeconds":30}
        """
        let decoded = try JSONDecoder().decode(StretchParameters.self,
                                               from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.targetSeconds, 120)
        XCTAssertEqual(decoded.freezeScan, 0, "missing fields keep their defaults")
        XCTAssertEqual(decoded.grainSeconds, 0.15)
        XCTAssertTrue(decoded.seamlessLoop)
    }
}
