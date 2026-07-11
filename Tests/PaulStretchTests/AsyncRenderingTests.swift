//
//  AsyncRenderingTests.swift
//  Tests for SwiftPaulStretch
//
//  The async/await surface: async renders must equal their sync
//  counterparts bit for bit, and Task cancellation must actually stop work.
//
//  Created by David Sherlock on 7/12/26.
//

import XCTest
@testable import PaulStretch

final class AsyncRenderingTests: XCTestCase {

    private func params(_ mutate: (inout StretchParameters) -> Void = { _ in }) -> StretchParameters {
        var p = StretchParameters()
        p.targetSeconds = 4
        p.windowSeconds = 0.12
        p.fadeInSeconds = 0.5
        p.fadeOutSeconds = 0.5
        mutate(&p)
        return p
    }

    // MARK: - Equality with the sync API

    func testAsyncRenderMatchesSyncRender() async throws {
        let source = TestSignals.source(seconds: 1.0)
        let p = params { $0.layering = .standard }
        let sync = StretchRenderer.render(source, parameters: p, isCancelled: { false })
        let async = try await StretchRenderer.render(source, parameters: p)
        assertSamplesIdentical(async.l, sync.l, "async render left")
        assertSamplesIdentical(async.r, sync.r, "async render right")
    }

    func testAsyncStretchAndFreezeMatchSync() async throws {
        let source = TestSignals.source(seconds: 0.75)
        let syncStretch = PaulStretcher.stretch(source, ratio: 4, windowSeconds: 0.12, isCancelled: { false })
        let asyncStretch = try await PaulStretcher.stretch(source, ratio: 4, windowSeconds: 0.12)
        assertSamplesIdentical(asyncStretch.l, syncStretch.l, "async stretch")

        let syncFreeze = SpectralFreezer.render(source, position: 0.5, smear: 0.2, targetSeconds: 3, isCancelled: { false })
        let asyncFreeze = try await SpectralFreezer.render(source, position: 0.5, smear: 0.2, targetSeconds: 3)
        assertSamplesIdentical(asyncFreeze.l, syncFreeze.l, "async freeze")
    }

    func testChunkSequenceMatchesSyncChunks() async throws {
        let source = TestSignals.source(seconds: 1.0)
        let p = params { $0.layering = .standard; $0.seamlessLoop = true }

        let sync = StretchRenderer.render(source, parameters: p, isCancelled: { false })

        var l: [Float] = []
        var r: [Float] = []
        var nextStart = 0
        for try await chunk in StretchRenderer.renderChunkSequence(source, parameters: p,
                                                                   chunkFrames: 30_000) {
            XCTAssertEqual(chunk.startFrame, nextStart, "chunks must arrive in order")
            nextStart += chunk.frameCount
            l.append(contentsOf: chunk.l)
            r.append(contentsOf: chunk.r)
        }
        assertSamplesIdentical(l, sync.l, "sequence left")
        assertSamplesIdentical(r, sync.r, "sequence right")
    }

    func testAsyncRenderToFileWritesTheSameAudio() async throws {
        let source = TestSignals.source(seconds: 1.0)
        let p = params { $0.layering = .off }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("psasync-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try await StretchRenderer.renderToFile(source, parameters: p, url: url)
        let sync = StretchRenderer.render(source, parameters: p, isCancelled: { false })
        let back = try AudioFileIO.readStereo(url: url)
        XCTAssertEqual(back.frameCount, sync.frameCount)
        assertSamplesClose(back.l, sync.l, tolerance: 1e-4, "async file left")
    }

    // MARK: - Cancellation

    func testCancellingTheTaskThrowsCancellationError() async {
        // A long render that would take a while — cancel almost immediately.
        let source = TestSignals.source(seconds: 2.0)
        let p = params { $0.targetSeconds = 600; $0.layering = .lush }

        let task = Task {
            try await StretchRenderer.render(source, parameters: p)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)   // 50 ms
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testCancellingChunkSequenceIterationStops() async throws {
        let source = TestSignals.source(seconds: 1.0)
        let p = params { $0.targetSeconds = 60; $0.layering = .off }

        let task = Task { () -> Int in
            var delivered = 0
            for try await _ in StretchRenderer.renderChunkSequence(source, parameters: p,
                                                                   chunkFrames: 20_000) {
                delivered += 1
                if delivered == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return delivered
        }
        do {
            _ = try await task.value
            XCTFail("expected CancellationError from the sequence")
        } catch is CancellationError {
            // expected
        }
    }

    func testAsyncCancelledFileRenderRemovesPartialFile() async throws {
        let source = TestSignals.source(seconds: 1.5)
        let p = params { $0.targetSeconds = 300; $0.layering = .standard }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("psasync-cancel-\(UUID().uuidString).wav")

        let task = Task {
            try await StretchRenderer.renderToFile(source, parameters: p, url: url)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "cancelled async file render must remove the partial file")
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        try? FileManager.default.removeItem(at: url)
    }
}
