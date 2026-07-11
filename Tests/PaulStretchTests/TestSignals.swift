//
//  TestSignals.swift
//  Tests for SwiftPaulStretch
//
//  Deterministic synthetic sources + comparison helpers shared by the suite.
//
//  Created by David Sherlock on 7/12/26.
//

import XCTest
@testable import PaulStretch

enum TestSignals {

    /// A deterministic, spectrally-busy stereo source: two tones, a slow
    /// chirp and an amplitude envelope. Same everywhere, every run.
    static func source(seconds: Double = 1.5, sampleRate sr: Double = 44_100) -> StereoBuffer {
        let n = Int(sr * seconds)
        var l = [Float](repeating: 0, count: n)
        var r = l
        for i in 0..<n {
            let t = Double(i) / sr
            let env = 0.5 + 0.5 * sin(2 * Double.pi * 0.7 * t)
            let s1 = sin(2 * Double.pi * 220 * t)
            let s2 = 0.4 * sin(2 * Double.pi * (330 + 40 * t) * t)
            let gr = 0.08 * sin(2 * Double.pi * 1234.5 * t * t)
            l[i] = Float((s1 + s2 + gr) * env * 0.5)
            r[i] = Float((s1 * 0.8 + s2 * 1.1 + gr) * env * 0.5)
        }
        return StereoBuffer(l: l, r: r, sampleRate: sr)
    }

    /// A pure sine, useful for pitch/spectrum assertions.
    static func sine(_ hz: Double, seconds: Double = 1.5, amplitude: Float = 0.5,
                     sampleRate sr: Double = 44_100) -> StereoBuffer {
        let n = Int(sr * seconds)
        var l = [Float](repeating: 0, count: n)
        for i in 0..<n {
            l[i] = amplitude * Float(sin(2 * Double.pi * hz * Double(i) / sr))
        }
        return StereoBuffer(l: l, r: l, sampleRate: sr)
    }
}

/// Asserts two sample arrays are identical down to the bit pattern.
func assertSamplesIdentical(_ a: [Float], _ b: [Float],
                            _ label: String,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, "\(label): frame count differs", file: file, line: line)
    guard a.count == b.count else { return }
    for i in 0..<a.count where a[i].bitPattern != b[i].bitPattern {
        XCTFail("\(label): first divergence at frame \(i): \(a[i]) vs \(b[i])", file: file, line: line)
        return
    }
}

/// Asserts two sample arrays match within an absolute tolerance.
func assertSamplesClose(_ a: [Float], _ b: [Float], tolerance: Float,
                        _ label: String,
                        file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, "\(label): frame count differs", file: file, line: line)
    guard a.count == b.count else { return }
    for i in 0..<a.count where abs(a[i] - b[i]) > tolerance {
        XCTFail("\(label): first divergence at frame \(i): \(a[i]) vs \(b[i])", file: file, line: line)
        return
    }
}

extension StereoBuffer {
    /// Root-mean-square level across both channels (test metric).
    var rms: Float {
        guard frameCount > 0 else { return 0 }
        var acc = 0.0
        for i in 0..<frameCount {
            acc += Double(l[i]) * Double(l[i]) + Double(r[i]) * Double(r[i])
        }
        return Float((acc / Double(frameCount * 2)).squareRoot())
    }

    /// Absolute peak across both channels (test metric).
    var peak: Float {
        var p: Float = 0
        for i in 0..<frameCount { p = max(p, max(abs(l[i]), abs(r[i]))) }
        return p
    }
}
