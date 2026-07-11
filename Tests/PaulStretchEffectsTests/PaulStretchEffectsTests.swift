//
//  PaulStretchEffectsTests.swift
//  Tests for SwiftPaulStretch
//
//  Effect-chain baking: no-op passthrough, tail handling, streaming/whole
//  equivalence and Codable settings.
//
//  Created by David Sherlock on 7/12/26.
//

import XCTest
import PaulStretch
@testable import PaulStretchEffects

final class PaulStretchEffectsTests: XCTestCase {

    /// Deterministic stereo test tone.
    private func tone(seconds: Double = 1.0, hz: Double = 440) -> StereoBuffer {
        let sr = 44_100.0
        let n = Int(sr * seconds)
        var l = [Float](repeating: 0, count: n)
        var r = l
        for i in 0..<n {
            let t = Double(i) / sr
            l[i] = Float(0.4 * sin(2 * Double.pi * hz * t))
            r[i] = Float(0.4 * sin(2 * Double.pi * hz * 1.5 * t))
        }
        return StereoBuffer(l: l, r: r, sampleRate: sr)
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        var acc = 0.0
        for v in x { acc += Double(v) * Double(v) }
        return Float((acc / Double(x.count)).squareRoot())
    }

    // MARK: - Whole-buffer bake

    func testAllOffBakeReturnsTheDryInput() {
        let dry = tone()
        let out = EffectsBaker.bake(dry, effects: EffectsParameters())
        XCTAssertEqual(out.l, dry.l, "no effects → untouched input")
        XCTAssertEqual(out.r, dry.r)
    }

    func testReverbBakeAddsATailAndWetness() {
        let dry = tone()
        var fx = EffectsParameters()
        fx.reverbEnabled = true
        fx.reverbMix = 50
        let wet = EffectsBaker.bake(dry, effects: fx)
        XCTAssertEqual(wet.frameCount, dry.frameCount + Int(44_100 * EffectsBaker.tailSeconds),
                       "reverb bake must append the decay tail")
        XCTAssertNotEqual(Array(wet.l[0..<dry.frameCount]), dry.l, "wet audio must differ from dry")
        let tail = wet.l[dry.frameCount...]
        XCTAssertGreaterThan(rms(tail), 1e-5, "the tail should carry reverb decay")
    }

    func testEQOnlyBakeKeepsLengthAndChangesTone() {
        let dry = tone(hz: 100)   // sits on the low shelf
        var fx = EffectsParameters()
        fx.eqEnabled = true
        fx.eqLowGain = 6
        let wet = EffectsBaker.bake(dry, effects: fx)
        XCTAssertEqual(wet.frameCount, dry.frameCount, "EQ has no tail")
        // A +6 dB low shelf should raise the level of a 100 Hz tone.
        let skip = 4410   // ignore the filter settling transient
        XCTAssertGreaterThan(rms(wet.l[skip...]), rms(dry.l[skip...]) * 1.5)
    }

    // MARK: - Streaming bake

    func testStreamingBakeMatchesWholeBufferBake() {
        let dry = tone()
        var fx = EffectsParameters()
        fx.reverbEnabled = true
        fx.reverbMix = 40
        fx.eqEnabled = true
        fx.eqHighGain = 3

        let whole = EffectsBaker.bake(dry, effects: fx)

        guard let baker = StreamingEffectsBaker(sampleRate: dry.sampleRate, effects: fx) else {
            return XCTFail("streaming baker setup failed")
        }
        var outL: [Float] = []
        var outR: [Float] = []
        let chunk = 10_000
        var pos = 0
        while pos < dry.frameCount {
            let end = min(dry.frameCount, pos + chunk)
            let wet = baker.process(l: Array(dry.l[pos..<end]), r: Array(dry.r[pos..<end]))
            outL.append(contentsOf: wet.l)
            outR.append(contentsOf: wet.r)
            pos = end
        }
        let tail = baker.finish()
        outL.append(contentsOf: tail.l)
        outR.append(contentsOf: tail.r)

        XCTAssertEqual(outL.count, whole.frameCount, "streamed length must match the whole bake")
        // The AUs are stateful black boxes, so compare energy over 50 ms
        // windows rather than demanding bit equality.
        let w = 2205
        var i = 0
        while i + w <= whole.frameCount {
            let a = rms(whole.l[i..<i + w])
            let b = rms(outL[i..<i + w])
            XCTAssertEqual(a, b, accuracy: max(0.02, a * 0.1),
                           "energy diverged in window at frame \(i)")
            i += w
        }
    }

    func testStreamingPassthroughWhenNothingIsEnabled() {
        let dry = tone(seconds: 0.25)
        guard let baker = StreamingEffectsBaker(sampleRate: dry.sampleRate,
                                                effects: EffectsParameters()) else {
            return XCTFail("passthrough baker setup failed")
        }
        let wet = baker.process(l: dry.l, r: dry.r)
        XCTAssertEqual(wet.l, dry.l)
        let tail = baker.finish()
        XCTAssertTrue(tail.l.isEmpty, "passthrough has no tail")
    }

    // MARK: - Effected file export

    func testRenderToWAVFileWithEffectsWritesRenderPlusTail() throws {
        let source = tone(seconds: 1.0)
        var p = StretchParameters()
        p.targetSeconds = 3
        p.windowSeconds = 0.12
        p.layering = .off
        var fx = EffectsParameters()
        fx.reverbEnabled = true

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("psfx-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let completed = try StretchRenderer.renderToWAVFile(source, parameters: p, effects: fx,
                                                            url: url, chunkFrames: 30_000)
        XCTAssertTrue(completed)
        let back = try AudioFileIO.readStereo(url: url)
        let renderFrames = StretchRenderer.outputFrameCount(source, parameters: p)
        XCTAssertEqual(back.frameCount,
                       renderFrames + Int(source.sampleRate * EffectsBaker.tailSeconds),
                       "file must hold the render plus the reverb tail")
    }

    // MARK: - Settings

    func testEffectsParametersRoundTripThroughJSON() throws {
        var fx = EffectsParameters()
        fx.reverbEnabled = true
        fx.reverbPreset = .plate
        fx.delayEnabled = true
        fx.delayTime = 0.42
        let data = try JSONEncoder().encode(fx)
        let decoded = try JSONDecoder().decode(EffectsParameters.self, from: data)
        XCTAssertEqual(decoded, fx)
    }

    func testReverbPresetsExposeDisplayNamesAndAVPresets() {
        XCTAssertEqual(ReverbPreset.allCases.count, 8)
        XCTAssertEqual(ReverbPreset.cathedral.displayName, "Cathedral")
        XCTAssertEqual(ReverbPreset.largeChamber.avPreset, .largeChamber)
        XCTAssertFalse(EffectsParameters().isAnyEnabled)
    }
}
