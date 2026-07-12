//
//  AudioFileIOTests.swift
//  Tests for SwiftPaulStretch
//
//  File decode/encode round trips and the streaming WAV writer.
//
//  Created by David Sherlock on 7/12/26.
//

import XCTest
import AVFoundation
@testable import PaulStretch

final class AudioFileIOTests: XCTestCase {

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pstest-\(name)-\(UUID().uuidString).wav")
    }

    // MARK: - Round trips

    func testWAVWriteReadRoundTrip() throws {
        let src = TestSignals.source(seconds: 0.5)
        let url = tempURL("roundtrip")
        defer { try? FileManager.default.removeItem(at: url) }

        try AudioFileIO.writeWAV(src, to: url)
        let back = try AudioFileIO.readStereo(url: url)
        XCTAssertEqual(back.frameCount, src.frameCount)
        XCTAssertEqual(back.sampleRate, 44_100)
        assertSamplesClose(back.l, src.l, tolerance: 1e-4, "round trip left")
        assertSamplesClose(back.r, src.r, tolerance: 1e-4, "round trip right")
    }

    func test16BitExportAlsoRoundTrips() throws {
        let src = TestSignals.sine(440, seconds: 0.25)
        let url = tempURL("16bit")
        defer { try? FileManager.default.removeItem(at: url) }

        try AudioFileIO.writeWAV(src, to: url, bitDepth: 16)
        let back = try AudioFileIO.readStereo(url: url)
        XCTAssertEqual(back.frameCount, src.frameCount)
        // 16-bit quantisation step ≈ 3e-5.
        assertSamplesClose(back.l, src.l, tolerance: 1e-3, "16-bit round trip")
    }

    func testMonoFilesAreDuplicatedToBothChannels() throws {
        // Write a mono file with AVAudioFile directly, then read it back
        // through the library.
        let url = tempURL("mono")
        defer { try? FileManager.default.removeItem(at: url) }

        let sr = 44_100.0
        let n = 4410
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else {
            return XCTFail("mono buffer setup failed")
        }
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { buf.floatChannelData![0][i] = Float(sin(2 * Double.pi * 440 * Double(i) / sr)) * 0.5 }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // Scope the writer so the file is finalised before it is read back.
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buf)
        }

        let back = try AudioFileIO.readStereo(url: url)
        assertSamplesIdentical(back.l, back.r, "mono must duplicate to both channels")
        XCTAssertGreaterThan(back.rms, 0.1)
    }

    func testResamplingToTheRequestedRate() throws {
        let src = TestSignals.sine(440, seconds: 0.5)
        let url = tempURL("resample")
        defer { try? FileManager.default.removeItem(at: url) }

        try AudioFileIO.writeWAV(src, to: url)
        let back = try AudioFileIO.readStereo(url: url, sampleRate: 22_050)
        XCTAssertEqual(back.sampleRate, 22_050)
        XCTAssertEqual(Double(back.frameCount), Double(src.frameCount) / 2, accuracy: 64)
    }

    // MARK: - Streaming writer

    func testStreamingWriterMatchesOneShotWrite() throws {
        let src = TestSignals.source(seconds: 0.5)
        let urlA = tempURL("stream-a")
        let urlB = tempURL("stream-b")
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try AudioFileIO.writeWAV(src, to: urlA)

        let writer = try StreamingAudioWriter(url: urlB, sampleRate: src.sampleRate)
        let half = src.frameCount / 2
        try writer.append(l: Array(src.l[0..<half]), r: Array(src.r[0..<half]))
        try writer.append(l: Array(src.l[half...]), r: Array(src.r[half...]))
        XCTAssertEqual(writer.framesWritten, src.frameCount)
        writer.close()

        let a = try AudioFileIO.readStereo(url: urlA)
        let b = try AudioFileIO.readStereo(url: urlB)
        assertSamplesIdentical(b.l, a.l, "chunked write must equal one-shot write")
    }

    func testWriterThrowsAfterClose() throws {
        let url = tempURL("closed")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try StreamingAudioWriter(url: url, sampleRate: 44_100)
        writer.close()
        XCTAssertThrowsError(try writer.append(l: [0], r: [0])) { error in
            guard case AudioFileIOError.writerClosed = error else {
                return XCTFail("expected .writerClosed, got \(error)")
            }
        }
    }

    // MARK: - Loudness (EBU R128)

    func testIntegratedLoudnessOfReferenceSine() {
        // BS.1770 reference: a 0 dBFS 997 Hz sine in ONE channel reads
        // −3.01 LUFS, so both channels at −6.02 dBFS read ≈ −6.0 LUFS
        // (the −0.691 offset cancels the K-filter's gain at 1 kHz).
        let sr = 44_100.0
        let n = Int(sr * 5)
        var l = [Float](repeating: 0, count: n)
        for i in 0..<n { l[i] = 0.5 * Float(sin(2 * Double.pi * 997 * Double(i) / sr)) }
        let sine = StereoBuffer(l: l, r: l, sampleRate: sr)
        guard let lufs = Loudness.integrated(of: sine) else { return XCTFail("gated to silence") }
        XCTAssertEqual(lufs, -6.0, accuracy: 0.5)
        XCTAssertNil(Loudness.integrated(of: StereoBuffer(silenceFrames: n, sampleRate: sr)),
                     "silence must gate out entirely")
    }

    func testLoudnessNormalizationHitsTheTarget() {
        let quiet = TestSignals.source(seconds: 5).peakNormalized(to: 0.1)
        let levelled = Loudness.normalize(quiet, toLUFS: -18)
        guard let lufs = Loudness.integrated(of: levelled) else { return XCTFail() }
        XCTAssertEqual(lufs, -18, accuracy: 0.5)
        // Peak safety: a hot target on quiet material must not clip.
        let hot = Loudness.normalize(quiet, toLUFS: 0)
        let peak = hot.l.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertLessThanOrEqual(peak, 0.981, "the ceiling must hold")
    }

    // MARK: - PCM bridging

    func testMakePCMBufferCopiesBothChannels() throws {
        let src = TestSignals.source(seconds: 0.1)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: src.sampleRate, channels: 2),
              let buf = AudioFileIO.makePCMBuffer(src, format: format) else {
            return XCTFail("makePCMBuffer failed")
        }
        XCTAssertEqual(Int(buf.frameLength), src.frameCount)
        let l = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: src.frameCount))
        let r = Array(UnsafeBufferPointer(start: buf.floatChannelData![1], count: src.frameCount))
        assertSamplesIdentical(l, src.l, "PCM left")
        assertSamplesIdentical(r, src.r, "PCM right")
    }
}
