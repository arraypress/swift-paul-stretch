//
//  StretchSourceNodeTests.swift
//  Tests for SwiftPaulStretch
//
//  The realtime source node, exercised headlessly through AVAudioEngine
//  manual rendering: pulled audio must match the offline render exactly,
//  and looped playback must wrap seamlessly.
//
//  Created by David Sherlock on 7/12/26.
//

import XCTest
import AVFoundation
@testable import PaulStretch

final class StretchSourceNodeTests: XCTestCase {

    /// Pulls `frames` from a prepared node through an offline AVAudioEngine.
    private func pull(_ node: StretchSourceNode, frames: Int) throws -> ([Float], [Float]) {
        let engine = AVAudioEngine()
        engine.attach(node.avAudioNode)
        engine.connect(node.avAudioNode, to: engine.mainMixerNode, format: node.format)
        try engine.enableManualRenderingMode(.offline, format: node.format, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }

        guard let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else {
            throw AudioFileIOError.cannotAllocateBuffer
        }
        var l: [Float] = []; l.reserveCapacity(frames)
        var r: [Float] = []; r.reserveCapacity(frames)
        var rendered = 0
        while rendered < frames {
            // Give the producer time to stay ahead — offline pulling is much
            // faster than realtime.
            var waited = 0
            while node.bufferedFrames < min(4096, frames - rendered), waited < 2000 {
                Thread.sleep(forTimeInterval: 0.005)
                waited += 1
                if node.isFinished { break }
            }
            let n = AVAudioFrameCount(min(4096, frames - rendered))
            let status = try engine.renderOffline(n, to: out)
            guard status == .success else { break }
            let got = Int(out.frameLength)
            if got == 0 { break }
            l.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: got))
            r.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![1], count: got))
            rendered += got
        }
        return (l, r)
    }

    private func params(_ mutate: (inout StretchParameters) -> Void = { _ in }) -> StretchParameters {
        var p = StretchParameters()
        p.targetSeconds = 3
        p.windowSeconds = 0.12
        p.layering = .off
        p.fadeInSeconds = 0.3
        p.fadeOutSeconds = 0.3
        mutate(&p)
        return p
    }

    // MARK: - Fidelity

    func testNodePlaysTheOfflineRenderExactly() async throws {
        let source = TestSignals.source(seconds: 1.0)
        let p = params()
        let offline = StretchRenderer.render(source, parameters: p, isCancelled: { false })

        let node = try await StretchSourceNode.prepare(source: source, parameters: p,
                                                       bufferSeconds: 2)
        defer { node.stop() }
        XCTAssertEqual(node.totalFrames, offline.frameCount)

        let n = Int(1.5 * 44_100)
        let (l, r) = try pull(node, frames: n)
        XCTAssertEqual(l.count, n)
        assertSamplesClose(Array(l[0..<n]), Array(offline.l[0..<n]), tolerance: 1e-6,
                           "node output vs offline render, left")
        assertSamplesClose(Array(r[0..<n]), Array(offline.r[0..<n]), tolerance: 1e-6,
                           "node output vs offline render, right")
        XCTAssertEqual(node.underrunFrames, 0, "offline pull should never underrun")
    }

    func testLoopingNodeWrapsSeamlessly() async throws {
        let source = TestSignals.source(seconds: 1.0)
        let p = params { $0.seamlessLoop = true }
        let offline = StretchRenderer.render(source, parameters: p, isCancelled: { false })
        let loopLen = offline.frameCount

        let node = try await StretchSourceNode.prepare(source: source, parameters: p,
                                                       bufferSeconds: 2)
        defer { node.stop() }
        XCTAssertTrue(node.loops)
        XCTAssertEqual(node.totalFrames, loopLen)

        // Pull one full pass plus half of the next: the wrapped region must
        // replay the loop's beginning exactly.
        let extra = loopLen / 2
        let (l, _) = try pull(node, frames: loopLen + extra)
        XCTAssertEqual(l.count, loopLen + extra)
        assertSamplesClose(Array(l[0..<loopLen]), offline.l, tolerance: 1e-6, "first pass")
        assertSamplesClose(Array(l[loopLen..<(loopLen + extra)]), Array(offline.l[0..<extra]),
                           tolerance: 1e-6, "wrapped second pass")
    }

    func testTapeSlowNodePreparesInstantly() async throws {
        // Tape-slow has no peak passes — prepare should be near-instant and
        // the node should play the varispeed-tiled timeline.
        let source = TestSignals.sine(440, seconds: 1.0)
        let p = params { $0.mode = .tapeSlow; $0.tapeSpeed = 0.5; $0.seamlessLoop = true }
        let node = try await StretchSourceNode.prepare(source: source, parameters: p,
                                                       bufferSeconds: 2)
        defer { node.stop() }

        let (l, _) = try pull(node, frames: 44_100)
        var crossings = 0
        for i in 1..<l.count where (l[i - 1] < 0) != (l[i] < 0) { crossings += 1 }
        let hz = Double(crossings) / 2.0
        XCTAssertEqual(hz, 220, accuracy: 10, "tape-slow node should play at half pitch")
    }

    func testNonLoopingNodeFinishesWithSilence() async throws {
        let source = TestSignals.source(seconds: 0.75)
        let p = params { $0.targetSeconds = 1.0 }
        let node = try await StretchSourceNode.prepare(source: source, parameters: p,
                                                       bufferSeconds: 2)
        defer { node.stop() }

        let total = node.totalFrames
        let (l, _) = try pull(node, frames: total + 8192)
        // After the end of the timeline the node must emit silence.
        let tail = Array(l[total...])
        XCTAssertTrue(tail.allSatisfy { $0 == 0 }, "post-timeline output must be silence")
    }

    func testEmptySourceThrowsNothingToRender() async {
        let empty = StereoBuffer(l: [], r: [], sampleRate: 44_100)
        do {
            _ = try await StretchSourceNode.prepare(source: empty, parameters: params())
            XCTFail("expected nothingToRender")
        } catch StretchSourceNodeError.nothingToRender {
            // expected
        } catch {
            XCTFail("expected nothingToRender, got \(error)")
        }
    }
}
