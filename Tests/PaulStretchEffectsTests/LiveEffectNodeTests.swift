//
//  LiveEffectNodeTests.swift
//  Drives the live effect node through a real AVAudioEngine in manual
//  rendering mode — the graph actually runs, just faster than realtime.
//

import XCTest
import AVFAudio
import PaulStretch
@testable import PaulStretchEffects

#if os(macOS) || os(iOS)

final class LiveEffectNodeTests: XCTestCase {

    private let sr = 44100.0

    private func tone(_ seconds: Double, _ format: AVAudioFormat) -> AVAudioPCMBuffer {
        let n = AVAudioFrameCount(sr * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        buf.frameLength = n
        let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
        for i in 0..<Int(n) {
            let t = Double(i) / sr
            l[i] = Float(0.4 * sin(2 * .pi * 220 * t))
            r[i] = Float(0.4 * sin(2 * .pi * 221 * t))
        }
        return buf
    }

    /// Runs the node in a real engine graph and returns the rendered output.
    private func renderThroughEngine(_ fx: EffectsParameters,
                                     seconds: Double = 1.5,
                                     tweak: ((LiveEffectChain) -> Void)? = nil) throws -> [Float] {
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let chain = LiveEffectChain(sampleRate: sr, effects: fx)

        var node: AVAudioUnit?
        let made = expectation(description: "node")
        Task { node = await LiveEffectNode.make(chain: chain); made.fulfill() }
        wait(for: [made], timeout: 10)
        let effectNode = try XCTUnwrap(node, "failed to instantiate the live effect unit")

        engine.attach(player)
        engine.attach(effectNode)
        engine.connect(player, to: effectNode, format: format)
        engine.connect(effectNode, to: engine.mainMixerNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 512)
        try engine.start()
        player.scheduleBuffer(tone(seconds, format), at: nil, options: [])
        player.play()

        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                   frameCapacity: 512)!
        var collected = [Float]()
        let target = AVAudioFramePosition(sr * seconds)
        var tweaked = false
        while engine.manualRenderingSampleTime < target {
            let remaining = target - engine.manualRenderingSampleTime
            let n = AVAudioFrameCount(min(AVAudioFramePosition(512), remaining))
            let status = try engine.renderOffline(n, to: out)
            guard status == .success else { break }
            let ch = out.floatChannelData![0]
            for i in 0..<Int(out.frameLength) { collected.append(ch[i]) }
            // Change parameters at the halfway point, as a user turning a
            // knob would. Callers compare the first quarter against the last,
            // so both windows sit clear of this instant.
            if !tweaked, collected.count > Int(sr * seconds / 2) {
                tweak?(chain); tweaked = true
            }
        }
        engine.stop()
        return collected
    }

    /// The node must pass audio through a real graph without altering length
    /// or producing garbage.
    func testNodeRendersInEngineGraph() throws {
        var fx = EffectsParameters()
        fx.wowEnabled = true; fx.wowAmount = 0.4
        fx.sweepFilterEnabled = true; fx.sweepFilterCutoff = 1200

        let out = try renderThroughEngine(fx)
        XCTAssertGreaterThan(out.count, Int(sr), "engine produced too little audio")
        var peak: Float = 0
        for v in out { XCTAssertTrue(v.isFinite); peak = max(peak, abs(v)) }
        XCTAssertGreaterThan(peak, 0.01, "node output was silent")
        XCTAssertLessThan(peak, 2.0, "node output blew up")
    }

    /// A disabled chain must be a true bypass, not a subtle attenuation.
    func testEmptyChainIsTransparent() throws {
        let out = try renderThroughEngine(EffectsParameters())
        var peak: Float = 0
        for v in out { peak = max(peak, abs(v)) }
        XCTAssertEqual(peak, 0.4, accuracy: 0.01, "empty chain was not unity gain")
    }

    /// The whole point: turning a knob mid-playback changes the sound and
    /// does not stall, crash, or drop the stream.
    func testParameterTweakMidPlaybackTakesEffect() throws {
        var fx = EffectsParameters()
        fx.sweepFilterEnabled = true
        fx.sweepFilterCutoff = 8000        // open: the 220 Hz tone passes

        var changed = fx
        changed.sweepFilterCutoff = 120    // closed: it should duck

        let out = try renderThroughEngine(fx, seconds: 2.0) { chain in
            chain.setEffects(changed)
        }
        XCTAssertGreaterThan(out.count, Int(sr), "stream was cut short by the tweak")

        // Compare the first quarter (before the halfway tweak) against the
        // last (well after it, past the filter's settling time).
        let quarter = out.count / 4
        func rms(_ s: ArraySlice<Float>) -> Float {
            sqrt(s.reduce(0) { $0 + $1 * $1 } / Float(s.count))
        }
        let before = rms(out[0..<quarter])
        let after = rms(out[(quarter * 3)..<out.count])
        XCTAssertLessThan(after, before * 0.8,
                          "closing the filter mid-playback did not change the audio "
                          + "(before \(before), after \(after))")
    }
}

#endif
