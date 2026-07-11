//
//  ChunkedRenderTests.swift
//  Tests for SwiftPaulStretch
//
//  The library's core promise: the chunked/streaming renderer produces
//  bit-for-bit the same audio as the in-memory renderer, for every mode and
//  any chunk size.
//
//  Created by David Sherlock on 7/12/26.
//

import XCTest
@testable import PaulStretch

final class ChunkedRenderTests: XCTestCase {

    /// The mode/feature matrix the equality tests sweep. Kept short so the
    /// whole suite stays fast; every pipeline branch is hit at least once
    /// (layering, tiling, loop trim, fades, width, pitch, tape speed,
    /// reverse, freeze).
    private static let matrix: [(name: String, parameters: StretchParameters)] = {
        func cfg(_ mutate: (inout StretchParameters) -> Void) -> StretchParameters {
            var p = StretchParameters()
            p.targetSeconds = 4
            p.windowSeconds = 0.12
            p.fadeInSeconds = 0.5
            p.fadeOutSeconds = 0.5
            mutate(&p)
            return p
        }
        return [
            ("plain", cfg { p in p.layering = .off }),
            ("layered", cfg { p in p.layering = .standard }),
            ("layered-loop", cfg { p in p.layering = .standard; p.seamlessLoop = true }),
            ("lush-pitch-width", cfg { p in
                p.layering = .lush; p.pitchSemitones = -5; p.stereoWidth = 1.4
            }),
            ("tiled", cfg { p in p.layering = .off; p.maxStretch = 1.8; p.targetSeconds = 6 }),
            ("tape-slow", cfg { p in p.mode = .tapeSlow; p.tapeSpeed = 0.5 }),
            ("tape-slow-loop", cfg { p in
                p.mode = .tapeSlow; p.tapeSpeed = 0.6; p.seamlessLoop = true; p.targetSeconds = 5
            }),
            ("freeze", cfg { p in
                p.mode = .spectralFreeze; p.freezePosition = 0.3; p.freezeSmear = 0.4
            }),
            ("freeze-loop", cfg { p in p.mode = .spectralFreeze; p.seamlessLoop = true }),
            ("reverse-soft", cfg { p in
                p.layering = .off; p.reverse = true; p.phaseRandomness = 0.35
            }),
        ]
    }()

    /// Renders via renderChunks and reassembles the timeline.
    private func assemble(_ source: StereoBuffer, _ p: StretchParameters,
                          chunkFrames: Int) -> (buffer: StereoBuffer, chunkSizes: [Int], completed: Bool) {
        var l: [Float] = []
        var r: [Float] = []
        var sizes: [Int] = []
        var nextStart = 0
        var total = -1
        let completed = StretchRenderer.renderChunks(source, parameters: p,
                                                     chunkFrames: chunkFrames) { chunk in
            XCTAssertEqual(chunk.startFrame, nextStart, "chunks must arrive in order")
            if total < 0 { total = chunk.totalFrames }
            XCTAssertEqual(chunk.totalFrames, total, "totalFrames must be stable")
            nextStart += chunk.frameCount
            sizes.append(chunk.frameCount)
            l.append(contentsOf: chunk.l)
            r.append(contentsOf: chunk.r)
        }
        return (StereoBuffer(l: l, r: r, sampleRate: source.sampleRate), sizes, completed)
    }

    // MARK: - Bitwise equality with the in-memory renderer

    func testChunkedMatchesInMemoryAcrossTheModeMatrix() {
        let source = TestSignals.source(seconds: 1.2)
        for (name, p) in Self.matrix {
            let full = StretchRenderer.render(source, parameters: p)
            let chunked = assemble(source, p, chunkFrames: 30_000)
            XCTAssertTrue(chunked.completed, "\(name): chunked render did not complete")
            XCTAssertEqual(chunked.buffer.frameCount, full.frameCount, "\(name): length")
            assertSamplesIdentical(chunked.buffer.l, full.l, "\(name) left")
            assertSamplesIdentical(chunked.buffer.r, full.r, "\(name) right")
        }
    }

    func testChunkSizeDoesNotChangeTheAudio() {
        let source = TestSignals.source(seconds: 1.2)
        var p = StretchParameters()
        p.targetSeconds = 4
        p.windowSeconds = 0.12
        p.layering = .standard
        p.seamlessLoop = true
        let full = StretchRenderer.render(source, parameters: p)

        for chunkFrames in [12_345, 65_536, 10_000_000] {
            let chunked = assemble(source, p, chunkFrames: chunkFrames)
            XCTAssertTrue(chunked.completed)
            assertSamplesIdentical(chunked.buffer.l, full.l, "chunk=\(chunkFrames) left")
            assertSamplesIdentical(chunked.buffer.r, full.r, "chunk=\(chunkFrames) right")
        }
    }

    // MARK: - Geometry

    func testOutputFrameCountPredictsEveryMode() {
        let source = TestSignals.source(seconds: 1.2)
        for (name, p) in Self.matrix {
            let predicted = StretchRenderer.outputFrameCount(source, parameters: p)
            let actual = StretchRenderer.render(source, parameters: p).frameCount
            XCTAssertEqual(predicted, actual, "\(name): outputFrameCount must match the render")
        }
    }

    func testOutputFrameCountForEmptyAndTinySources() {
        let empty = StereoBuffer(l: [], r: [], sampleRate: 44_100)
        var p = StretchParameters()
        p.targetSeconds = 4
        XCTAssertEqual(StretchRenderer.outputFrameCount(empty, parameters: p), 0)
        XCTAssertTrue(StretchRenderer.render(empty, parameters: p).isEmpty)

        // Sources under 32 frames cannot be frozen.
        let tiny = StereoBuffer(silenceFrames: 16, sampleRate: 44_100)
        p.mode = .spectralFreeze
        XCTAssertEqual(StretchRenderer.outputFrameCount(tiny, parameters: p), 0)
        XCTAssertTrue(StretchRenderer.render(tiny, parameters: p).isEmpty)
    }

    // MARK: - File streaming

    func testRenderToWAVFileMatchesTheInMemoryRender() throws {
        let source = TestSignals.source(seconds: 1.2)
        var p = StretchParameters()
        p.targetSeconds = 4
        p.windowSeconds = 0.12
        p.layering = .off

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pstest-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let completed = try StretchRenderer.renderToWAVFile(source, parameters: p, url: url,
                                                            chunkFrames: 30_000)
        XCTAssertTrue(completed)

        let full = StretchRenderer.render(source, parameters: p)
        let reread = try AudioFileIO.readStereo(url: url)
        XCTAssertEqual(reread.frameCount, full.frameCount)
        // 24-bit PCM quantisation: one step is ~1.2e-7 at full scale.
        assertSamplesClose(reread.l, full.l, tolerance: 1e-4, "WAV round trip left")
        assertSamplesClose(reread.r, full.r, tolerance: 1e-4, "WAV round trip right")
    }

    // MARK: - Cancellation + progress

    func testCancelledChunkedRenderStopsAndReportsFalse() {
        let source = TestSignals.source(seconds: 1.2)
        var p = StretchParameters()
        p.targetSeconds = 4
        p.windowSeconds = 0.12
        p.layering = .off

        var delivered = 0
        let flag = CancelToken()
        let completed = StretchRenderer.renderChunks(source, parameters: p,
                                                     chunkFrames: 20_000,
                                                     isCancelled: { flag.isCancelled }) { _ in
            delivered += 1
            flag.cancel()
        }
        XCTAssertFalse(completed, "a cancelled render must report false")
        XCTAssertEqual(delivered, 1, "no chunks may arrive after cancellation")
    }

    func testCancelledFileRenderRemovesThePartialFile() throws {
        let source = TestSignals.source(seconds: 1.2)
        var p = StretchParameters()
        p.targetSeconds = 4
        p.windowSeconds = 0.12
        p.layering = .off

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pstest-cancel-\(UUID().uuidString).wav")
        let flag = CancelToken()
        var delivered = 0
        var progressValues: [Double] = []
        let completed = try StretchRenderer.renderToWAVFile(source, parameters: p, url: url,
                                                            chunkFrames: 20_000,
                                                            isCancelled: { delivered > 0 && flag.isCancelled },
                                                            progress: { progressValues.append($0) })
        _ = delivered; _ = completed
        // Run a genuine cancellation pass as well:
        let completed2 = try StretchRenderer.renderToWAVFile(source, parameters: p, url: url,
                                                             chunkFrames: 20_000,
                                                             isCancelled: { true })
        XCTAssertFalse(completed2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "cancelled file render must remove the partial file")
        try? FileManager.default.removeItem(at: url)
    }

    func testProgressIsMonotonicAndFinishesAtOne() {
        let source = TestSignals.source(seconds: 1.2)
        var p = StretchParameters()
        p.targetSeconds = 4
        p.windowSeconds = 0.12
        p.layering = .standard

        var values: [Double] = []
        StretchRenderer.renderChunks(source, parameters: p, chunkFrames: 30_000,
                                     progress: { values.append($0) }) { _ in }
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.last ?? 0, 1, accuracy: 1e-9)
        for i in 1..<values.count {
            XCTAssertGreaterThanOrEqual(values[i], values[i - 1] - 1e-9,
                                        "progress must not go backwards")
        }
    }

    // MARK: - Seams

    func testChunkBoundariesLeaveNoSeamArtifacts() {
        // Neighbouring samples across a chunk boundary should be no more
        // discontinuous than neighbouring samples inside a chunk — compare
        // against the in-memory render sample-for-sample instead of by ear.
        let source = TestSignals.source(seconds: 1.2)
        var p = StretchParameters()
        p.targetSeconds = 4
        p.windowSeconds = 0.12
        p.layering = .off
        let full = StretchRenderer.render(source, parameters: p)
        let chunked = assemble(source, p, chunkFrames: 4_099)   // deliberately awkward size
        XCTAssertTrue(chunked.completed)
        assertSamplesIdentical(chunked.buffer.l, full.l, "awkward chunk size left")
        assertSamplesIdentical(chunked.buffer.r, full.r, "awkward chunk size right")
    }
}
