//
//  SpectrumAnalyzerTests.swift
//  Tests for SwiftPaulStretch
//
//  The display spectrum: band mapping, level mapping, smoothing reset and
//  the waveform peaks helper.
//
//  Created by David Sherlock on 7/12/26.
//

import XCTest
import AVFoundation
@testable import PaulStretch

final class SpectrumAnalyzerTests: XCTestCase {

    /// A PCM buffer holding a sine at `hz` in both channels.
    private func sineBuffer(hz: Double, sampleRate: Double = 44_100, frames: Int = 1024) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let v = Float(0.8 * sin(2 * Double.pi * hz * Double(i) / sampleRate))
            buf.floatChannelData![0][i] = v
            buf.floatChannelData![1][i] = v
        }
        return buf
    }

    /// The band index whose log-spaced range contains `hz` (the analyzer's
    /// own mapping, restated).
    private func expectedBand(for hz: Double, bandCount: Int, minF: Double = 40, maxF: Double = 18_000) -> Int {
        Int(Double(bandCount) * log(hz / minF) / log(maxF / minF))
    }

    func testSineLandsInTheRightBand() {
        let analyzer = SpectrumAnalyzer()
        var received: [Float] = []
        analyzer.onBands = { received = $0 }
        analyzer.process(sineBuffer(hz: 1000))

        XCTAssertEqual(received.count, analyzer.bandCount)
        let loudest = received.firstIndex(of: received.max()!)!
        let expected = expectedBand(for: 1000, bandCount: analyzer.bandCount)
        XCTAssertLessThanOrEqual(abs(loudest - expected), 1,
                                 "1 kHz peaked in band \(loudest), expected ~\(expected)")
    }

    func testSilenceProducesNearZeroBands() {
        let analyzer = SpectrumAnalyzer()
        var received: [Float] = []
        analyzer.onBands = { received = $0 }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let silent = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024)!
        silent.frameLength = 1024
        analyzer.process(silent)
        XCTAssertLessThan(received.max() ?? 1, 0.02)
    }

    func testResetClearsDecaySmoothing() {
        let analyzer = SpectrumAnalyzer()
        var received: [Float] = []
        analyzer.onBands = { received = $0 }
        analyzer.process(sineBuffer(hz: 1000))
        let hot = received.max()!
        XCTAssertGreaterThan(hot, 0.3)

        analyzer.reset()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let silent = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024)!
        silent.frameLength = 1024
        analyzer.process(silent)
        XCTAssertLessThan(received.max() ?? 1, 0.02,
                          "reset should drop the peaks instead of decaying them")
    }

    func testCustomBandCountIsRespected() {
        let analyzer = SpectrumAnalyzer(bandCount: 12)
        var received: [Float] = []
        analyzer.onBands = { received = $0 }
        analyzer.process(sineBuffer(hz: 1000))
        XCTAssertEqual(received.count, 12)
    }

    // MARK: - StereoBuffer.peaks

    func testPeaksColumnCountAndLocation() {
        var l = [Float](repeating: 0, count: 44_100)
        // A burst ~75% of the way through, wider than the probe stride
        // (peaks sub-samples for display, so a 1-frame spike may be missed).
        for i in 33_000..<33_500 { l[i] = 0.9 }
        let b = StereoBuffer(l: l, r: l, sampleRate: 44_100)

        let peaks = b.peaks(columns: 100)
        XCTAssertEqual(peaks.count, 100)
        let hottest = peaks.firstIndex(of: peaks.max()!)!
        XCTAssertEqual(hottest, 33_000 * 100 / 44_100)
        XCTAssertEqual(peaks.max()!, 0.9, accuracy: 1e-6)
    }

    func testPeaksHandlesEmptyAndDegenerateInput() {
        XCTAssertTrue(StereoBuffer(l: [], r: [], sampleRate: 44_100).peaks(columns: 50).isEmpty)
        let b = StereoBuffer(l: [0.5], r: [0.5], sampleRate: 44_100)
        XCTAssertTrue(b.peaks(columns: 0).isEmpty)
        XCTAssertEqual(b.peaks(columns: 4).count, 4)
    }
}
