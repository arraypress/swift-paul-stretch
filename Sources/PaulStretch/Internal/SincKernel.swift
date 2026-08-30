//
//  SincKernel.swift
//  SwiftPaulStretch
//
//  A windowed-sinc interpolator for varispeed: the kernel tabulated at a
//  fine set of fractional phases, each row normalised to unit gain, read
//  with linear interpolation between neighbouring phases. Sixty-four taps
//  under a Blackman window keep images below the noise of 24-bit audio.
//
//  Created by David Sherlock on 2026.
//

import Foundation

struct SincKernel {
    /// Taps either side of the read position.
    static let half = 32
    /// Fractional phases tabulated; the read interpolates between two.
    static let phases = 512

    private let taps: Int
    private let table: [Float]     // (phases + 1) rows × taps

    /// - Parameter speed: The playback-speed factor. Above `1` the cutoff
    ///   drops to the new Nyquist so speeding up cannot alias.
    init(speed: Double) {
        let half = Self.half
        let taps = half * 2
        let cutoff = min(1, 1 / max(speed, 1e-6))
        var table = [Float](repeating: 0, count: (Self.phases + 1) * taps)
        for q in 0...Self.phases {
            let frac = Double(q) / Double(Self.phases)
            var sum = 0.0
            var row = [Double](repeating: 0, count: taps)
            for t in 0..<taps {
                // Tap t reads sample floor(pos) + (t - half + 1); its distance
                // from the read position is that offset minus the fraction.
                let x = Double(t - half + 1) - frac
                let sinc: Double
                if abs(x) < 1e-9 {
                    sinc = cutoff
                } else {
                    let a = Double.pi * cutoff * x
                    sinc = cutoff * sin(a) / a
                }
                // Blackman window over the kernel's full width.
                let u = x / Double(half)
                let window = abs(u) >= 1 ? 0 : 0.42 + 0.5 * cos(Double.pi * u) + 0.08 * cos(2 * Double.pi * u)
                row[t] = sinc * window
                sum += row[t]
            }
            // Unit DC gain per phase: what goes in at 0 Hz comes out at 0 Hz.
            let norm = sum != 0 ? 1 / sum : 1
            for t in 0..<taps { table[q * taps + t] = Float(row[t] * norm) }
        }
        self.taps = taps
        self.table = table
    }

    /// Both channels at fractional position `pos` (in source frames).
    /// Reads past either end are silence.
    @inline(__always)
    func sample(_ l: UnsafeBufferPointer<Float>, _ r: UnsafeBufferPointer<Float>,
                count n: Int, at pos: Double) -> (Float, Float) {
        let base = Int(pos.rounded(.down))
        let frac = pos - Double(base)
        let scaled = frac * Double(Self.phases)
        let q = min(Int(scaled), Self.phases - 1)
        let mix = Float(scaled - Double(q))
        let rowA = q * taps
        let rowB = rowA + taps
        var accL: Float = 0, accR: Float = 0
        let first = base - Self.half + 1
        let lo = max(0, -first)
        let hi = min(taps, n - first)
        if lo < hi {
            table.withUnsafeBufferPointer { k in
                for t in lo..<hi {
                    let w = k[rowA + t] + (k[rowB + t] - k[rowA + t]) * mix
                    let i = first + t
                    accL += l[i] * w
                    accR += r[i] * w
                }
            }
        }
        return (accL, accR)
    }
}
