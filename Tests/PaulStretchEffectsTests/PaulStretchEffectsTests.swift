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

    // MARK: - Shimmer reverb

    /// Power of a single frequency via the Goertzel algorithm (comparison
    /// metric only — same-length windows).
    private func goertzelPower(_ x: ArraySlice<Float>, hz: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        let c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s0 = Double(v) + c * s1 - s2
            s2 = s1; s1 = s0
        }
        return s1 * s1 + s2 * s2 - c * s1 * s2
    }

    func testShimmerBloomsAnOctaveUpInTheTail() {
        let dry = tone(seconds: 1.0, hz: 440)
        var withFeedback = EffectsParameters()
        withFeedback.shimmerEnabled = true
        withFeedback.shimmerMix = 60
        withFeedback.shimmerFeedback = 65
        withFeedback.shimmerPitch = 12

        var withoutFeedback = withFeedback
        withoutFeedback.shimmerFeedback = 0

        let bloom = EffectsBaker.bake(dry, effects: withFeedback)
        let plain = EffectsBaker.bake(dry, effects: withoutFeedback)
        XCTAssertEqual(bloom.frameCount,
                       dry.frameCount + Int(44_100 * ShimmerReverb.tailSeconds),
                       "shimmer must append its ring-out tail")

        // Compare octave-up (880 Hz) energy early in the tails: the
        // feedback loop is what climbs the octave.
        let tailStart = dry.frameCount + 4410
        let window = tailStart..<(tailStart + 44_100)
        let octaveBloom = goertzelPower(bloom.l[window], hz: 880, sampleRate: 44_100)
        let octavePlain = goertzelPower(plain.l[window], hz: 880, sampleRate: 44_100)
        XCTAssertGreaterThan(octaveBloom, octavePlain * 10 + 1e-9,
                             "feedback must add octave-up energy to the tail")
        XCTAssertFalse(bloom.l.contains { $0.isNaN || $0.isInfinite })
        let peak = bloom.l.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertLessThan(peak, 4, "the feedback loop must stay stable")
    }

    func testShimmerStreamingMatchesWholeBakeExactly() {
        // Shimmer is pure sequential DSP — chunking must not change a bit.
        let dry = tone(seconds: 1.0)
        var fx = EffectsParameters()
        fx.shimmerEnabled = true
        fx.shimmerFeedback = 50

        let whole = EffectsBaker.bake(dry, effects: fx)

        guard let baker = StreamingEffectsBaker(sampleRate: dry.sampleRate, effects: fx) else {
            return XCTFail("shimmer-only streaming baker setup failed")
        }
        var outL: [Float] = []
        var pos = 0
        while pos < dry.frameCount {
            let end = min(dry.frameCount, pos + 7_777)
            let wet = baker.process(l: Array(dry.l[pos..<end]), r: Array(dry.r[pos..<end]))
            outL.append(contentsOf: wet.l)
            pos = end
        }
        let flushed = baker.finish()
        outL.append(contentsOf: flushed.l)
        XCTAssertEqual(outL.count, whole.frameCount)
        XCTAssertEqual(outL, whole.l, "chunked shimmer must be bit-identical to the whole bake")
    }

    func testShimmerIntoReverbAppendsBothTails() {
        let dry = tone(seconds: 0.5)
        var fx = EffectsParameters()
        fx.shimmerEnabled = true
        fx.reverbEnabled = true
        let wet = EffectsBaker.bake(dry, effects: fx)
        let expected = dry.frameCount
            + Int(44_100 * ShimmerReverb.tailSeconds)
            + Int(44_100 * EffectsBaker.tailSeconds)
        XCTAssertEqual(wet.frameCount, expected,
                       "shimmer ring-out and reverb tail must both be appended")
    }

    func testLegacyEffectsJSONStillDecodes() throws {
        // v1.1-era settings know nothing of the shimmer fields.
        let legacyJSON = """
        {"reverbEnabled":true,"reverbPreset":"plate","reverbMix":40,
         "eqEnabled":false,"eqLowGain":0,"eqMidGain":0,"eqHighGain":0,
         "filterEnabled":false,"filterCutoff":8000,"filterResonance":0,
         "delayEnabled":false,"delayTime":0.35,"delayFeedback":35,"delayMix":25}
        """
        let decoded = try JSONDecoder().decode(EffectsParameters.self,
                                               from: Data(legacyJSON.utf8))
        XCTAssertTrue(decoded.reverbEnabled)
        XCTAssertEqual(decoded.reverbPreset, .plate)
        XCTAssertFalse(decoded.shimmerEnabled, "missing shimmer fields keep defaults")
        XCTAssertEqual(decoded.shimmerPitch, 12)
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
