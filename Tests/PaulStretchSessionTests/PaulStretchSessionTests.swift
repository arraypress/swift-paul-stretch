//
//  PaulStretchSessionTests.swift
//  Tests for SwiftPaulStretch
//
//  Effect stacks (order, bypass, duplicates, signature) and the clip-based
//  session bounce (tiling, phasing, trims, fades, lanes, pan law,
//  mute/solo, determinism).
//
//  Created by David Sherlock on 7/12/26.
//

import XCTest
import PaulStretch
import PaulStretchEffects
@testable import PaulStretchSession

final class PaulStretchSessionTests: XCTestCase {

    private let sr = 44_100.0

    /// A deterministic stereo test tone.
    private func tone(seconds: Double, hz: Double = 220, amp: Float = 0.3) -> StereoBuffer {
        let n = Int(sr * seconds)
        var l = [Float](repeating: 0, count: n)
        for i in 0..<n { l[i] = amp * Float(sin(2 * Double.pi * hz * Double(i) / sr)) }
        return StereoBuffer(l: l, r: l, sampleRate: sr)
    }

    /// A constant-value buffer (easy to reason about after placement).
    private func dc(_ value: Float, frames: Int) -> StereoBuffer {
        StereoBuffer(l: [Float](repeating: value, count: frames),
                     r: [Float](repeating: value, count: frames), sampleRate: sr)
    }

    /// A stereo ramp: sample n = n / frames (both channels).
    private func ramp(frames: Int) -> StereoBuffer {
        var l = [Float](repeating: 0, count: frames)
        for i in 0..<frames { l[i] = Float(i) / Float(frames) }
        return StereoBuffer(l: l, r: l, sampleRate: sr)
    }

    /// An empty-audio clip (voices are injected by id in placement tests).
    private func stubClip(start: Double = 0, duration: Double) -> Clip {
        Clip(source: .sample(SampleSource(audio: AudioReference(data: Data()))),
             startSeconds: start, durationSeconds: duration)
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(Float(0)) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    // MARK: - Effect stacks

    func testEmptyOrBypassedStackIsTransparent() {
        let input = tone(seconds: 0.5)
        XCTAssertEqual(EffectStackBaker.bake(input, stack: EffectStack()), input)

        var pump = BreathingPumpSettings(); pump.depth = 1; pump.rateHz = 2
        let bypassed = EffectStack([EffectDevice(.breathingPump(pump), isEnabled: false)])
        XCTAssertEqual(EffectStackBaker.bake(input, stack: bypassed), input,
                       "a disabled device must be bit-transparent")
    }

    func testDeviceOrderChangesTheResult() {
        let input = tone(seconds: 1.0)
        var pump = BreathingPumpSettings(); pump.depth = 1; pump.rateHz = 1
        var shimmer = ShimmerSettings(); shimmer.mix = 60; shimmer.feedback = 60

        let pumpFirst = EffectStackBaker.bake(input, stack: EffectStack([
            EffectDevice(.breathingPump(pump)), EffectDevice(.shimmer(shimmer))]))
        let shimmerFirst = EffectStackBaker.bake(input, stack: EffectStack([
            EffectDevice(.shimmer(shimmer)), EffectDevice(.breathingPump(pump))]))

        XCTAssertNotEqual(pumpFirst, shimmerFirst,
                          "pumping into a reverb and pumping its tail are different sounds")
    }

    func testDuplicateDevicesCascade() {
        let input = tone(seconds: 0.5, hz: 4000)
        var filter = SweepFilterSettings(); filter.cutoff = 500

        let once = EffectStackBaker.bake(input, stack: EffectStack([
            EffectDevice(.sweepFilter(filter))]))
        let twice = EffectStackBaker.bake(input, stack: EffectStack([
            EffectDevice(.sweepFilter(filter)), EffectDevice(.sweepFilter(filter))]))

        XCTAssertLessThan(rms(twice.l[0...]), rms(once.l[0...]) * 0.7,
                          "two identical low-passes must attenuate a 4 kHz tone harder than one")
    }

    func testStackInterleavesAppleAndPureDevicesInOrder() {
        let input = tone(seconds: 0.5)
        var pump = BreathingPumpSettings(); pump.depth = 1; pump.rateHz = 2
        let eq = EQSettings(bands: [], globalGain: -6)

        let stack = EffectStack([
            EffectDevice(.apple(.eq(eq))),
            EffectDevice(.breathingPump(pump)),
            EffectDevice(.apple(.eq(eq))),
        ])
        let out = EffectStackBaker.bake(input, stack: stack)
        XCTAssertGreaterThan(out.frameCount, 0)
        XCTAssertLessThan(rms(out.l[0...]), rms(input.l[0...]) * 0.3,
                          "two −6 dB EQ passes should land near −12 dB")
    }

    func testStackMoveRemoveAndSignature() {
        var pump = BreathingPumpSettings(); pump.depth = 1
        let a = EffectDevice(.breathingPump(pump))
        let b = EffectDevice(.autoPan(AutoPanSettings()))
        var stack = EffectStack([a, b])
        let original = stack.signature

        stack.move(fromIndex: 0, toIndex: 1)
        XCTAssertEqual(stack.devices.first?.id, b.id)
        XCTAssertNotEqual(stack.signature, original, "order is audible, so it must be in the key")

        var toggled = stack
        toggled.devices[0].isEnabled = false
        XCTAssertNotEqual(toggled.signature, stack.signature)

        var retuned = stack
        if case .breathingPump(var s) = retuned.devices[1].kind {
            s.depth = 0.25
            retuned.devices[1].kind = .breathingPump(s)
        }
        XCTAssertNotEqual(retuned.signature, stack.signature)

        // Identity alone must NOT change the key (voices cached across saves).
        var reidentified = stack
        reidentified.devices[0].id = UUID()
        XCTAssertEqual(reidentified.signature, stack.signature)

        stack.remove(id: a.id)
        XCTAssertEqual(stack.devices.count, 1)
    }

    func testStackCodableRoundTrip() throws {
        var conv = ConvolutionReverbSettings()
        conv.customIRData = Data([1, 2, 3, 4])
        conv.customIRName = "stairwell"
        conv.mixLane = AutomationLane(points: [AutomationPoint(t: 0, v: 0.2),
                                               AutomationPoint(t: 1, v: 0.9)])
        let stack = EffectStack([
            EffectDevice(.convolutionReverb(conv)),
            EffectDevice(.apple(.reverb(ReverbSettings())), isEnabled: false),
            EffectDevice(.shimmer(ShimmerSettings())),
        ])
        let data = try JSONEncoder().encode(stack)
        let decoded = try JSONDecoder().decode(EffectStack.self, from: data)
        XCTAssertEqual(decoded, stack)
    }

    // MARK: - Clip placement

    func testLoopTilingAndPhasingIsSampleExact() {
        var session = Session()
        session.durationSeconds = 1.0

        // Two looping clips with co-prime-ish voice lengths; every output
        // sample must be exactly the sum of the two voices read modulo.
        var a = Track(name: "A"), b = Track(name: "B")
        let clipA = stubClip(duration: 1.0)
        var clipB = stubClip(duration: 1.0)
        clipB.offsetSeconds = 100.0 / sr          // 100-frame left-trim (phase)
        a.clips = [clipA]; b.clips = [clipB]
        session.tracks = [a, b]

        let out = try! SessionRenderer.render(session, voices: [
            clipA.id: ramp(frames: 1000), clipB.id: ramp(frames: 707)])
        let frames = Int(sr * 1.0)
        XCTAssertEqual(out.frameCount, frames)
        for n in [0, 999, 1000, 5000, 44_099] {
            let expected = Float(n % 1000) / 1000 + Float((n + 100) % 707) / 707
            XCTAssertEqual(out.l[n], expected, accuracy: 1e-5, "frame \(n)")
        }
        _ = (clipA, clipB)
    }

    func testClipPositionTrimAndOneShotEnd() {
        var session = Session()
        session.durationSeconds = 1.0
        var track = Track(name: "late")
        var clip = stubClip(start: 0.5, duration: 0.4)
        clip.fillsWithLoop = false
        track.clips = [clip]
        session.tracks = [track]

        // 0.1 s one-shot voice inside a 0.4 s clip.
        let out = try! SessionRenderer.render(session, voices: [clip.id: dc(0.5, frames: 4410)])
        let startFrame = Int(0.5 * sr)
        XCTAssertEqual(out.l[startFrame - 1], 0, "silent before the clip")
        XCTAssertEqual(out.l[startFrame], 0.5, accuracy: 1e-6)
        XCTAssertEqual(out.l[startFrame + 4409], 0.5, accuracy: 1e-6)
        XCTAssertEqual(out.l[startFrame + 4410], 0, "one-shot ends at the voice's natural end")
    }

    func testClipDurationBoundsTiling() {
        var session = Session()
        session.durationSeconds = 1.0
        var track = Track(name: "short clip")
        let clip = stubClip(start: 0.1, duration: 0.2)   // clip shorter than session
        track.clips = [clip]
        session.tracks = [track]

        let out = try! SessionRenderer.render(session, voices: [clip.id: dc(0.5, frames: 1000)])
        let s = Int(0.1 * sr), e = s + Int(0.2 * sr)
        XCTAssertEqual(out.l[s], 0.5, accuracy: 1e-6)
        XCTAssertEqual(out.l[e - 1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(out.l[e + 1], 0, "audio must stop at the clip's right edge")
    }

    func testClipFadesShapeTheEdges() {
        var session = Session()
        session.durationSeconds = 1.0
        var track = Track(name: "faded")
        var clip = stubClip(start: 0, duration: 1.0)
        clip.fadeInSeconds = 0.5
        clip.fadeOutSeconds = 0.25
        track.clips = [clip]
        session.tracks = [track]

        let frames = Int(sr * 1.0)
        let out = try! SessionRenderer.render(session, voices: [clip.id: dc(1.0, frames: frames)])
        XCTAssertLessThan(out.l[10], 0.01, "starts near silence")
        XCTAssertEqual(out.l[Int(0.25 * sr)], 0.5, accuracy: 0.01, "half-way up the fade-in")
        XCTAssertEqual(out.l[Int(0.6 * sr)], 1.0, accuracy: 0.01, "full level between fades")
        XCTAssertLessThan(out.l[frames - 10], 0.01, "ends near silence")
    }

    func testMuteAndSolo() {
        var session = Session()
        session.durationSeconds = 0.1
        var a = Track(name: "A"), b = Track(name: "B")
        let clipA = stubClip(duration: 0.1), clipB = stubClip(duration: 0.1)
        a.clips = [clipA]; b.clips = [clipB]
        session.tracks = [a, b]
        let voices = [clipA.id: dc(0.25, frames: 100), clipB.id: dc(0.5, frames: 100)]

        var mix = try! SessionRenderer.render(session, voices: voices)
        XCTAssertEqual(mix.l[0], 0.75, accuracy: 1e-6)

        session.tracks[0].isMuted = true
        mix = try! SessionRenderer.render(session, voices: voices)
        XCTAssertEqual(mix.l[0], 0.5, accuracy: 1e-6, "muting A leaves only B")

        session.tracks[0].isMuted = false
        session.tracks[0].isSoloed = true
        mix = try! SessionRenderer.render(session, voices: voices)
        XCTAssertEqual(mix.l[0], 0.25, accuracy: 1e-6, "soloing A silences B")
    }

    func testPanLawUnityCentreAndCosineFarSide() {
        var session = Session()
        session.durationSeconds = 0.01
        var track = Track(name: "left")
        track.pan = -1
        let clip = stubClip(duration: 0.01)
        track.clips = [clip]
        session.tracks = [track]

        let out = try! SessionRenderer.render(session, voices: [clip.id: dc(0.5, frames: 500)])
        XCTAssertEqual(out.l[0], 0.5, accuracy: 1e-6, "near side stays at unity")
        XCTAssertEqual(out.r[0], 0, accuracy: 1e-6, "far side fully attenuates at the extreme")

        let (gL, gR) = SessionRenderer.balanceGains(pan: 0)
        XCTAssertEqual(gL, 1); XCTAssertEqual(gR, 1)
    }

    func testGainLaneShapesTheTrackOverSessionTime() {
        var session = Session()
        session.durationSeconds = 1.0
        var track = Track(name: "swell")
        track.gainLane = AutomationLane(points: [AutomationPoint(t: 0, v: 0),
                                                 AutomationPoint(t: 1, v: 1)])
        let clip = stubClip(duration: 1.0)
        track.clips = [clip]
        session.tracks = [track]

        let frames = Int(sr * 1.0)
        let out = try! SessionRenderer.render(session, voices: [clip.id: dc(0.5, frames: frames)])
        XCTAssertLessThan(out.l[100], 0.02, "starts near silence")
        XCTAssertGreaterThan(out.l[frames - 100], 0.45, "ends near full")
        XCTAssertLessThan(out.l[frames / 2 - 100], out.l[frames - 100])
    }

    func testMasterStackShapesTheSum() {
        var session = Session()
        session.durationSeconds = 0.5
        var track = Track(name: "A")
        let clip = stubClip(duration: 0.5)
        track.clips = [clip]
        session.tracks = [track]
        var pan = AutoPanSettings(); pan.depth = 1; pan.rateHz = 4
        session.master = EffectStack([EffectDevice(.autoPan(pan))])

        let voices = [clip.id: tone(seconds: 0.5)]
        let withMaster = try! SessionRenderer.render(session, voices: voices)
        session.master = EffectStack()
        let dry = try! SessionRenderer.render(session, voices: voices)

        XCTAssertNotEqual(withMaster, dry, "the master strip must process the sum")
    }

    func testBounceIsDeterministicAndCacheKeysTrackTheVoice() throws {
        var session = Session()
        session.durationSeconds = 2.0
        let seedTone = tone(seconds: 0.4, hz: 330)
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-test-seed.wav")
        try AudioFileIO.writeWAV(seedTone, to: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let audioData = try Data(contentsOf: wavURL)

        var params = StretchParameters()
        params.targetSeconds = 1.0
        params.windowSeconds = 0.1
        var track = Track(name: "drone")
        var shimmer = ShimmerSettings(); shimmer.mix = 40
        track.stack = EffectStack([EffectDevice(.shimmer(shimmer))])
        let clip = Clip(name: "drone",
                        source: .generative(GenerativeSource(audio: AudioReference(data: audioData),
                                                             parameters: params, seed: 7)),
                        startSeconds: 0, durationSeconds: 2.0)
        track.clips = [clip]
        session.tracks = [track]

        let first = try SessionRenderer.render(session)
        let second = try SessionRenderer.render(session)
        XCTAssertEqual(first, second, "same session must bounce bit-identically")
        XCTAssertGreaterThan(rms(first.l[0...]), 0.001, "and actually contain audio")

        // Placement edits must NOT invalidate the voice cache…
        let key = SessionRenderer.voiceCacheKey(for: clip, trackStack: track.stack, sampleRate: sr)
        var moved = clip
        moved.startSeconds = 1.0; moved.durationSeconds = 0.5
        moved.fadeInSeconds = 0.2; moved.gain = 0.5; moved.offsetSeconds = 0.3
        XCTAssertEqual(SessionRenderer.voiceCacheKey(for: moved, trackStack: track.stack, sampleRate: sr),
                       key, "dragging/trimming/fading a clip must not re-render its voice")

        // …but seed and strip changes must.
        var reseeded = clip
        if case .generative(var g) = reseeded.source { g.seed = 8; reseeded.source = .generative(g) }
        XCTAssertNotEqual(SessionRenderer.voiceCacheKey(for: reseeded, trackStack: track.stack, sampleRate: sr), key)
        XCTAssertNotEqual(SessionRenderer.voiceCacheKey(for: clip, trackStack: EffectStack(), sampleRate: sr), key)
    }

    func testSessionCodableRoundTripAndTolerance() throws {
        var session = Session()
        session.name = "Airports"
        session.durationSeconds = 1800
        var track = Track(name: "piano")
        let clip: Clip = {
            var c = Clip(name: "loop",
                         source: .sample(SampleSource(audio: AudioReference(path: "/tmp/p.wav"))),
                         startSeconds: 60, durationSeconds: 240)
            c.offsetSeconds = 13
            c.fadeInSeconds = 20
            return c
        }()
        track.clips = [clip]
        track.gainLane = AutomationLane(points: [AutomationPoint(t: 0, v: 1)])
        session.tracks = [track]
        session.master = EffectStack([EffectDevice(.shimmer(ShimmerSettings()))])

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(decoded, session)

        // Tolerant decode: a bare-bones document still opens.
        let minimal = #"{"tracks": []}"#.data(using: .utf8)!
        let opened = try JSONDecoder().decode(Session.self, from: minimal)
        XCTAssertEqual(opened.durationSeconds, 600)
    }

    // MARK: - Mixer (state logic; placement math is exercised above)

    @MainActor
    func testMixerPrepareAndTransportState() {
        let mixer = SessionMixer()
        var session = Session()
        session.durationSeconds = 5
        var track = Track(name: "A")
        let clip = stubClip(duration: 4)
        track.clips = [clip]
        session.tracks = [track]
        mixer.prepare(session: session, voices: [clip.id: tone(seconds: 1)])

        XCTAssertEqual(mixer.duration, 5)
        XCTAssertFalse(mixer.isPlaying)
        mixer.seek(to: 3)
        XCTAssertEqual(mixer.currentTime, 3, accuracy: 1e-6)
        mixer.seek(to: 99)
        XCTAssertEqual(mixer.currentTime, 5, accuracy: 1e-6)
        mixer.stop()
        XCTAssertEqual(mixer.currentTime, 0)
        mixer.setGain(trackID: track.id, 0.5)
        mixer.setSoloed(trackID: track.id, true)
        mixer.setGainMultiplier(trackID: track.id, 0.5)
    }
}
