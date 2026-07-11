//
//  PaulStretchTests.swift
//  Tests for SwiftPaulStretch
//
//  Core algorithm tests: FFT correctness, seeding/determinism, and the raw
//  stretch's contract.
//
//  Created by David Sherlock on 7/12/26.
//

import XCTest
@testable import PaulStretch

final class PaulStretchTests: XCTestCase {

    // MARK: - FFT

    func testFFTForwardInverseIdentity() {
        let n = 1024
        guard let fft = PSFFT(n: n) else { return XCTFail("PSFFT init failed") }
        var real = (0..<n).map { Float(sin(Double($0) * 0.37) + 0.5 * cos(Double($0) * 0.11)) }
        var imag = [Float](repeating: 0, count: n)
        let original = real
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                fft.forward(rp.baseAddress!, ip.baseAddress!)
                fft.inverse(rp.baseAddress!, ip.baseAddress!)
            }
        }
        for i in 0..<n {
            XCTAssertEqual(real[i], original[i], accuracy: 1e-4, "identity broke at \(i)")
            XCTAssertEqual(imag[i], 0, accuracy: 1e-4, "imag leaked at \(i)")
        }
    }

    func testFFTMatchesScalarOracle() {
        let n = 512
        guard let fft = PSFFT(n: n) else { return XCTFail("PSFFT init failed") }
        var rng = FastRNG(seed: 0xABCDEF)
        let srcR = (0..<n).map { _ in Float(rng.unit() * 2 - 1) }
        let srcI = (0..<n).map { _ in Float(rng.unit() * 2 - 1) }

        var fastR = srcR, fastI = srcI
        fastR.withUnsafeMutableBufferPointer { rp in
            fastI.withUnsafeMutableBufferPointer { ip in
                fft.forward(rp.baseAddress!, ip.baseAddress!)
            }
        }
        var slowR = srcR, slowI = srcI
        slowR.withUnsafeMutableBufferPointer { rp in
            slowI.withUnsafeMutableBufferPointer { ip in
                scalarFFT(rp.baseAddress!, ip.baseAddress!, n, false)
            }
        }
        for i in 0..<n {
            XCTAssertEqual(fastR[i], slowR[i], accuracy: 2e-3, "real bin \(i)")
            XCTAssertEqual(fastI[i], slowI[i], accuracy: 2e-3, "imag bin \(i)")
        }
    }

    func testFFTRejectsNonPowerOfTwo() {
        XCTAssertNil(PSFFT(n: 1000))
        XCTAssertNil(PSFFT(n: 1))
        XCTAssertNotNil(PSFFT(n: 2048))
    }

    // MARK: - Seeding

    func testBlockSeedDecorrelatesNeighbours() {
        // Adjacent block seeds must differ in roughly half their bits —
        // linear seeds caused audible amplitude flutter.
        var totalHamming = 0
        let pairs = 1000
        for b in 0..<pairs {
            let x = blockSeed(0x1234, b) ^ blockSeed(0x1234, b + 1)
            totalHamming += x.nonzeroBitCount
        }
        let mean = Double(totalHamming) / Double(pairs)
        XCTAssertGreaterThan(mean, 24, "adjacent block seeds are correlated")
        XCTAssertLessThan(mean, 40, "adjacent block seeds are anti-correlated")
    }

    func testNextPow2() {
        XCTAssertEqual(nextPow2(1), 1)
        XCTAssertEqual(nextPow2(2), 2)
        XCTAssertEqual(nextPow2(3), 4)
        XCTAssertEqual(nextPow2(11025), 16384)
    }

    // MARK: - Raw stretch

    func testStretchIsDeterministicPerSeed() {
        let src = TestSignals.source(seconds: 0.75)
        let a = PaulStretcher.stretch(src, ratio: 4, windowSeconds: 0.12)
        let b = PaulStretcher.stretch(src, ratio: 4, windowSeconds: 0.12)
        assertSamplesIdentical(a.l, b.l, "same seed, left")
        assertSamplesIdentical(a.r, b.r, "same seed, right")

        let c = PaulStretcher.stretch(src, ratio: 4, windowSeconds: 0.12,
                                      seed: StretchRenderer.variationSeed(1))
        XCTAssertEqual(a.frameCount, c.frameCount)
        XCTAssertNotEqual(a.l, c.l, "different seeds must produce different audio")
    }

    func testStretchLengthAndNormalization() {
        let src = TestSignals.source(seconds: 0.75)
        let ratio = 6.0
        let out = PaulStretcher.stretch(src, ratio: ratio, windowSeconds: 0.12)
        XCTAssertEqual(out.frameCount, Int(Double(src.frameCount) * ratio))
        XCTAssertEqual(out.peak, 0.92, accuracy: 1e-3, "output should be peak-normalised to 0.92")
        XCTAssertGreaterThan(out.rms, 0.05, "output should not be near-silent")
    }

    func testStretchPassthroughBelowThresholdRatio() {
        let src = TestSignals.source(seconds: 0.5)
        let out = PaulStretcher.stretch(src, ratio: 1.0005)
        assertSamplesIdentical(out.l, src.l, "ratio ≤ 1.001 must return the input, left")
        assertSamplesIdentical(out.r, src.r, "ratio ≤ 1.001 must return the input, right")
    }

    func testStretchCancellationReturnsEmpty() {
        let src = TestSignals.source(seconds: 0.75)
        let out = PaulStretcher.stretch(src, ratio: 8, windowSeconds: 0.12,
                                        isCancelled: { true })
        XCTAssertTrue(out.isEmpty, "cancelled render must come back empty")
    }

    func testPitchShiftMovesDominantFrequency() {
        // Stretch a 220 Hz sine up a full octave; the dominant output bin
        // should land near 440 Hz.
        let src = TestSignals.sine(220, seconds: 1.0)
        let out = PaulStretcher.stretch(src, ratio: 4, windowSeconds: 0.12,
                                        pitchSemitones: 12)
        let hz = dominantFrequency(out, sampleRate: 44_100)
        XCTAssertEqual(hz, 440, accuracy: 25, "octave-up should dominate near 440 Hz")
    }

    func testOnsetSensitivityChangesOutput() {
        let src = TestSignals.source(seconds: 0.75)
        let flat = PaulStretcher.stretch(src, ratio: 4, windowSeconds: 0.12, onsetSensitivity: 0)
        let onset = PaulStretcher.stretch(src, ratio: 4, windowSeconds: 0.12, onsetSensitivity: 1)
        XCTAssertEqual(flat.frameCount, onset.frameCount)
        XCTAssertNotEqual(flat.l, onset.l, "onset preservation should alter the render")
    }

    // MARK: - Helpers

    /// Peak-bin frequency of a Hann-windowed FFT taken from the middle of
    /// the buffer.
    private func dominantFrequency(_ b: StereoBuffer, sampleRate: Double) -> Double {
        let n = 8192
        guard b.frameCount >= n, let fft = PSFFT(n: n) else { return 0 }
        let start = (b.frameCount - n) / 2
        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let w = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)))
            real[i] = b.l[start + i] * w
        }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                fft.forward(rp.baseAddress!, ip.baseAddress!)
            }
        }
        var bestBin = 0
        var bestMag: Float = 0
        for k in 1..<(n / 2) {
            let m = real[k] * real[k] + imag[k] * imag[k]
            if m > bestMag { bestMag = m; bestBin = k }
        }
        return Double(bestBin) * sampleRate / Double(n)
    }
}
