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

    func testShimmerClimbDelaysTheBloom() {
        let dry = tone(seconds: 1.0, hz: 440)
        var instant = EffectsParameters()
        instant.shimmerEnabled = true
        instant.shimmerMix = 60
        instant.shimmerFeedback = 65
        var slow = instant
        slow.shimmerClimbSeconds = 3

        let fast = EffectsBaker.bake(dry, effects: instant)
        let climbed = EffectsBaker.bake(dry, effects: slow)

        // Octave energy right at the start of the input (first second):
        // with a 3 s climb the first pitched pass hasn't re-entered yet.
        let window = 4410..<44_100
        let octaveFast = goertzelPower(fast.l[window], hz: 880, sampleRate: 44_100)
        let octaveSlow = goertzelPower(climbed.l[window], hz: 880, sampleRate: 44_100)
        XCTAssertLessThan(octaveSlow, octaveFast * 0.2,
                          "a 3 s climb must hold the octave bloom back")
        XCTAssertFalse(climbed.l.contains { $0.isNaN || $0.isInfinite })
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

    // MARK: - Extended fixed chain (distortion / compressor / limiter)

    func testDistortionBakeMangles() {
        let dry = tone()
        var fx = EffectsParameters()
        fx.distortionEnabled = true
        fx.distortionPreset = .multiDecimated2
        fx.distortionMix = 100
        let wet = EffectsBaker.bake(dry, effects: fx)
        XCTAssertEqual(wet.frameCount, dry.frameCount, "distortion adds no tail")
        XCTAssertNotEqual(Array(wet.l[4410..<44100]), Array(dry.l[4410..<44100]),
                          "distortion must change the signal")
        XCTAssertFalse(wet.l.contains { $0.isNaN })
        XCTAssertEqual(DistortionPreset.allCases.count, 22)
    }

    func testCompressorReducesCrestFactor() {
        // Bursty input: loud attack, quiet tail — compression narrows the gap.
        let sr = 44_100.0
        let n = Int(sr * 1.0)
        var l = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            let env: Double = t < 0.2 ? 0.9 : 0.08
            l[i] = Float(env * sin(2 * Double.pi * 330 * t))
        }
        let dry = StereoBuffer(l: l, r: l, sampleRate: sr)

        var fx = EffectsParameters()
        fx.compressorEnabled = true
        fx.compressorThreshold = -30
        fx.compressorHeadroom = 0.5     // low headroom = hard compression
        fx.compressorAttack = 0.001
        fx.compressorGain = 0
        let wet = EffectsBaker.bake(dry, effects: fx)

        // Compression narrows the level gap between the sustained loud body
        // (post-attack) and the quiet tail.
        let loud = Int(0.05 * sr)..<Int(0.15 * sr)
        let quiet = Int(0.5 * sr)..<Int(0.9 * sr)
        let dryRatio = rms(dry.l[loud]) / max(rms(dry.l[quiet]), 1e-9)
        let wetRatio = rms(wet.l[loud]) / max(rms(wet.l[quiet]), 1e-9)
        XCTAssertLessThan(wetRatio, dryRatio * 0.7,
                          "hard compression must narrow the loud/quiet gap")
    }

    func testLimiterCapsHotPeaks() {
        let dry = tone()   // 0.4 peak
        var fx = EffectsParameters()
        fx.limiterEnabled = true
        fx.limiterPreGain = 20          // drive it ~4 over full scale
        let wet = EffectsBaker.bake(dry, effects: fx)
        let peak = wet.l.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertLessThan(peak, 1.2, "the limiter must hold +20 dB drive near the ceiling")
        XCTAssertGreaterThan(peak, 0.5, "…while clearly louder than the dry 0.4 peak")
    }

    func testDelayLowPassDarkensEchoes() {
        let dry = tone(seconds: 0.3, hz: 6000)   // bright tone
        var open = EffectsParameters()
        open.delayEnabled = true
        open.delayTime = 0.2
        open.delayMix = 100
        open.delayFeedback = 0
        open.delayLowPassCutoff = 20_000
        var dark = open
        dark.delayLowPassCutoff = 500

        let wetOpen = EffectsBaker.bake(dry, effects: open)
        let wetDark = EffectsBaker.bake(dry, effects: dark)
        // The echo lands ~0.2 s in; compare its energy.
        let echo = Int(0.22 * 44_100)..<Int(0.42 * 44_100)
        XCTAssertLessThan(rms(wetDark.l[echo]), rms(wetOpen.l[echo]) * 0.5,
                          "a 500 Hz feedback low-pass must gut a 6 kHz echo")
    }

    // MARK: - The full Apple rack

    func testRackBakesEveryUnitType() {
        let dry = tone(seconds: 0.5)
        let everything: [AppleEffect] = [
            .eq(EQSettings(bands: [
                EQBandSettings(type: .highPass, frequency: 60),
                EQBandSettings(type: .parametric, frequency: 2000, bandwidth: 0.8, gain: 2),
                EQBandSettings(type: .highShelf, frequency: 8000, gain: -3),
            ])),
            .graphicEQ(GraphicEQSettings(use31Bands: false, bandGains: [3, 2, 1, 0, 0, 0, 0, -1, -2, -3])),
            .distortion(DistortionSettings(preset: .multiDecimated1, wetDryMix: 20)),
            .delay(DelaySettings(delayTime: 0.1, feedback: 20, wetDryMix: 20)),
            .reverb(ReverbSettings(preset: .mediumHall2, wetDryMix: 30)),
            .dynamics(DynamicsProcessorSettings(threshold: -20, headRoom: 3)),
            .multibandCompressor(MultibandCompressorSettings()),
            .peakLimiter(PeakLimiterSettings()),
        ]
        let wet = EffectRack.bake(dry, effects: everything)
        XCTAssertEqual(wet.frameCount,
                       dry.frameCount + Int(44_100 * EffectsBaker.tailSeconds),
                       "reverb/delay in the rack must append the tail")
        XCTAssertNotEqual(Array(wet.l[0..<dry.frameCount]), dry.l)
        XCTAssertFalse(wet.l.contains { $0.isNaN })
        XCTAssertGreaterThan(rms(wet.l[0...]), 1e-4)
    }

    func testRackTimeUnitsScaleDuration() {
        let dry = tone(seconds: 1.0)
        // TimePitch at rate 2 → half duration, pitch preserved.
        let fast = EffectRack.bake(dry, effects: [.timePitch(TimePitchSettings(rate: 2))])
        XCTAssertEqual(Double(fast.frameCount), Double(dry.frameCount) / 2,
                       accuracy: 4096, "rate 2 must halve the duration")

        // Varispeed at rate 0.5 → double duration, pitch drops an octave.
        let slow = EffectRack.bake(dry, effects: [.varispeed(VarispeedSettings(rate: 0.5))])
        XCTAssertEqual(Double(slow.frameCount), Double(dry.frameCount) * 2,
                       accuracy: 4096, "rate 0.5 must double the duration")
        var crossings = 0
        for i in 1..<slow.frameCount where (slow.l[i - 1] < 0) != (slow.l[i] < 0) { crossings += 1 }
        let hz = Double(crossings) / (2 * Double(slow.frameCount) / 44_100)
        XCTAssertEqual(hz, 220, accuracy: 12, "varispeed 0.5 must halve the pitch of 440 Hz")
    }

    func testRackRoundTripsThroughJSON() throws {
        let rack: [AppleEffect] = [
            .timePitch(TimePitchSettings(rate: 0.5, pitchCents: 700)),
            .eq(EQSettings(bands: [EQBandSettings(type: .resonantLowPass, frequency: 900, gain: 6)])),
            .multibandCompressor(MultibandCompressorSettings()),
            .peakLimiter(PeakLimiterSettings(preGain: 3)),
        ]
        let decoded = try JSONDecoder().decode([AppleEffect].self,
                                               from: JSONEncoder().encode(rack))
        XCTAssertEqual(decoded, rack)
    }

    func testRackUpdateParametersRequiresSameTopology() {
        let rack = EffectRack(effects: [.reverb(ReverbSettings()), .peakLimiter(PeakLimiterSettings())])
        XCTAssertTrue(rack.updateParameters([.reverb(ReverbSettings(preset: .plate, wetDryMix: 80)),
                                             .peakLimiter(PeakLimiterSettings(preGain: 6))]))
        XCTAssertFalse(rack.updateParameters([.delay(DelaySettings()), .peakLimiter(PeakLimiterSettings())]),
                       "a different unit sequence must be rejected")
        XCTAssertFalse(rack.updateParameters([.reverb(ReverbSettings())]),
                       "a different unit count must be rejected")
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
        XCTAssertEqual(ReverbPreset.allCases.count, 13)
        // The first eight positions are load-bearing (legacy integer-index
        // preset migration) — never reorder them.
        XCTAssertEqual(Array(ReverbPreset.allCases.prefix(8)),
                       [.smallRoom, .mediumRoom, .largeRoom, .mediumHall,
                        .largeHall, .plate, .cathedral, .largeChamber])
        XCTAssertEqual(ReverbPreset.cathedral.displayName, "Cathedral")
        XCTAssertEqual(ReverbPreset.largeChamber.avPreset, .largeChamber)
        XCTAssertFalse(EffectsParameters().isAnyEnabled)
    }
}
