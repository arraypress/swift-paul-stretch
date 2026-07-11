//
//  AudioFileFormatTests.swift
//  Tests for SwiftPaulStretch
//
//  Round trips through every encodable format: lossless formats must come
//  back (near-)exact, lossy formats must come back plausible and small.
//
//  Created by David Sherlock on 7/12/26.
//

import XCTest
@testable import PaulStretch

final class AudioFileFormatTests: XCTestCase {

    private func tempURL(_ name: String, _ format: AudioFileFormat) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("psfmt-\(name)-\(UUID().uuidString).\(format.fileExtension)")
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func windowRMS(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        var acc = 0.0
        for v in x { acc += Double(v) * Double(v) }
        return Float((acc / Double(x.count)).squareRoot())
    }

    // MARK: - Lossless round trips

    func testLosslessFormatsRoundTripExactly() throws {
        let src = TestSignals.source(seconds: 1.0)
        // (format, absolute tolerance from the format's quantisation step)
        let cases: [(String, AudioFileFormat, Float)] = [
            ("wav16", .wav(bitDepth: 16), 1e-3),
            ("wav24", .wav(bitDepth: 24), 1e-4),
            ("wav32f", .wav(bitDepth: 32), 1e-6),
            ("aiff16", .aiff(bitDepth: 16), 1e-3),
            ("aiff24", .aiff(bitDepth: 24), 1e-4),
            ("caf24", .caf(bitDepth: 24), 1e-4),
            ("caf32f", .caf(bitDepth: 32), 1e-6),
            ("alac16", .m4aALAC(bitDepth: 16), 1e-3),
            ("alac24", .m4aALAC(bitDepth: 24), 1e-4),
            ("flac16", .flac(bitDepth: 16), 1e-3),
            ("flac24", .flac(bitDepth: 24), 1e-4),
        ]
        for (name, format, tolerance) in cases {
            let url = tempURL(name, format)
            defer { try? FileManager.default.removeItem(at: url) }
            try AudioFileIO.write(src, to: url, format: format)
            let back = try AudioFileIO.readStereo(url: url)
            XCTAssertEqual(back.frameCount, src.frameCount, "\(name): frame count")
            assertSamplesClose(back.l, src.l, tolerance: tolerance, "\(name) left")
            assertSamplesClose(back.r, src.r, tolerance: tolerance, "\(name) right")
            XCTAssertFalse(format.isLossy, "\(name) must report lossless")
        }
    }

    // MARK: - Lossy round trips

    func testLossyFormatsRoundTripPlausiblyAndSmall() throws {
        let src = TestSignals.source(seconds: 2.0)
        let wavURL = tempURL("ref", .wav24)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        try AudioFileIO.write(src, to: wavURL, format: .wav24)
        let wavSize = fileSize(wavURL)

        let cases: [(String, AudioFileFormat, Double)] = [
            ("aac-cbr", .m4aAAC(bitRate: 256_000, quality: .max), 0.45),
            ("aac-vbr", .m4aAACVBR(quality: .high), 0.45),
            ("he-aac", .m4aHEAAC(bitRate: 64_000), 0.15),
        ]
        for (name, format, maxSizeRatio) in cases {
            let url = tempURL(name, format)
            defer { try? FileManager.default.removeItem(at: url) }
            try AudioFileIO.write(src, to: url, format: format)
            XCTAssertTrue(format.isLossy, "\(name) must report lossy")

            XCTAssertLessThan(Double(fileSize(url)), Double(wavSize) * maxSizeRatio,
                              "\(name): expected a much smaller file than WAV")

            let back = try AudioFileIO.readStereo(url: url)
            // Encoder priming/padding is trimmed on read; allow one packet
            // of slack in either direction.
            XCTAssertEqual(back.frameCount, src.frameCount, accuracy: 2048, "\(name): length")
            // Compare mid-file energy (lossy → tolerant): 50 ms windows.
            let w = 2205
            var i = w * 4
            while i + w <= min(back.frameCount, src.frameCount) - w * 4 {
                let a = windowRMS(src.l[i..<i + w])
                let b = windowRMS(back.l[i..<i + w])
                XCTAssertEqual(a, b, accuracy: max(0.03, a * 0.25),
                               "\(name): energy diverged at frame \(i)")
                i += w * 4
            }
        }
    }

    func testOpusRequiresAndWorksAt48k() throws {
        // Opus only encodes 48 kHz-family streams.
        let src48 = TestSignals.source(seconds: 1.0, sampleRate: 48_000)
        let format = AudioFileFormat.opusCAF(bitRate: 96_000)
        let url = tempURL("opus48", format)
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioFileIO.write(src48, to: url, format: format)
        let back = try AudioFileIO.readStereo(url: url, sampleRate: 48_000)
        XCTAssertEqual(back.frameCount, src48.frameCount, accuracy: 4096, "opus length")
        XCTAssertGreaterThan(back.rms, 0.05, "opus must carry audio")

        // …and fails cleanly at 44.1 kHz.
        let src44 = TestSignals.source(seconds: 0.25)
        let badURL = tempURL("opus44", format)
        defer { try? FileManager.default.removeItem(at: badURL) }
        XCTAssertThrowsError(try AudioFileIO.write(src44, to: badURL, format: format),
                             "Opus at 44.1 kHz must throw")
    }

    // MARK: - Chunked render straight to compressed files

    func testRenderToFileInAACMatchesTheRenderGeometry() throws {
        let source = TestSignals.source(seconds: 1.2)
        var p = StretchParameters()
        p.targetSeconds = 4
        p.windowSeconds = 0.12
        p.layering = .off

        let format = AudioFileFormat.aac256
        let url = tempURL("render", format)
        defer { try? FileManager.default.removeItem(at: url) }

        let completed = try StretchRenderer.renderToFile(source, parameters: p, url: url,
                                                         format: format, chunkFrames: 30_000)
        XCTAssertTrue(completed)

        let expected = StretchRenderer.outputFrameCount(source, parameters: p)
        let back = try AudioFileIO.readStereo(url: url)
        XCTAssertEqual(back.frameCount, expected, accuracy: 2048,
                       "AAC file length must match the render")
        XCTAssertGreaterThan(back.rms, 0.02, "AAC render must carry audio")
    }

    func testCancelledCompressedFileRenderRemovesThePartialFile() throws {
        let source = TestSignals.source(seconds: 1.2)
        var p = StretchParameters()
        p.targetSeconds = 4
        p.windowSeconds = 0.12
        p.layering = .off

        let format = AudioFileFormat.aac256
        let url = tempURL("cancel", format)
        let completed = try StretchRenderer.renderToFile(source, parameters: p, url: url,
                                                         format: format, isCancelled: { true })
        XCTAssertFalse(completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "cancelled compressed render must remove the partial file")
    }

    // MARK: - Metadata

    func testFileExtensionsMatchContainers() {
        XCTAssertEqual(AudioFileFormat.wav24.fileExtension, "wav")
        XCTAssertEqual(AudioFileFormat.aiff(bitDepth: 16).fileExtension, "aiff")
        XCTAssertEqual(AudioFileFormat.caf(bitDepth: 32).fileExtension, "caf")
        XCTAssertEqual(AudioFileFormat.aac256.fileExtension, "m4a")
        XCTAssertEqual(AudioFileFormat.m4aAACVBR(quality: .high).fileExtension, "m4a")
        XCTAssertEqual(AudioFileFormat.m4aHEAAC(bitRate: 64_000).fileExtension, "m4a")
        XCTAssertEqual(AudioFileFormat.alac.fileExtension, "m4a")
        XCTAssertEqual(AudioFileFormat.flac(bitDepth: 24).fileExtension, "flac")
        XCTAssertEqual(AudioFileFormat.opusCAF(bitRate: 96_000).fileExtension, "caf")
    }
}
