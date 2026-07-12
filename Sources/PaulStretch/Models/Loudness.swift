//
//  Loudness.swift
//  SwiftPaulStretch
//
//  EBU R128 / ITU-R BS.1770 integrated loudness: K-weighting, 400 ms gated
//  blocks, absolute and relative gates — plus loudness normalisation for
//  publishing pipelines where consistent perceived level matters more than
//  peak level.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// EBU R128 integrated-loudness measurement and normalisation.
///
/// Batch pipelines ("pre-generate loops, host on a CDN") want every file at
/// the same *perceived* loudness; peak normalisation can't provide that —
/// two renders peaking identically can differ by many LU. Streaming
/// platforms target integrated loudness (-14 LUFS is common; -16 for
/// spoken/ambient beds).
///
/// ```swift
/// let lufs = Loudness.integrated(of: render)          // e.g. -21.3
/// let levelled = Loudness.normalize(render, toLUFS: -16)
/// ```
public enum Loudness {

    /// The gain in decibels that would bring `buffer` to `targetLUFS`.
    ///
    /// - Returns: The gain, or `nil` when the buffer is effectively silent
    ///   (below the -70 LUFS absolute gate throughout).
    public static func gainToTarget(_ buffer: StereoBuffer, targetLUFS: Double) -> Double? {
        guard let current = integrated(of: buffer) else { return nil }
        return targetLUFS - current
    }

    /// Returns `buffer` normalised to `targetLUFS` integrated loudness.
    ///
    /// True-peak safety: after the loudness gain, any sample peak above
    /// `peakCeiling` pulls the whole buffer down to fit (loudness then lands
    /// below target rather than clipping).
    ///
    /// - Parameters:
    ///   - buffer: The audio to normalise.
    ///   - targetLUFS: The integrated-loudness target (e.g. `-16`).
    ///   - peakCeiling: The absolute sample ceiling. Defaults to `0.98`.
    /// - Returns: The normalised buffer (unchanged if effectively silent).
    public static func normalize(_ buffer: StereoBuffer,
                                 toLUFS targetLUFS: Double,
                                 peakCeiling: Float = 0.98) -> StereoBuffer {
        guard let gainDB = gainToTarget(buffer, targetLUFS: targetLUFS) else { return buffer }
        var gain = Float(pow(10.0, gainDB / 20.0))

        var peak: Float = 0
        for i in 0..<buffer.frameCount {
            peak = max(peak, max(abs(buffer.l[i]), abs(buffer.r[i])))
        }
        if peak * gain > peakCeiling {
            gain = peakCeiling / max(peak, 1e-9)
        }

        var l = buffer.l
        var r = buffer.r
        for i in 0..<l.count { l[i] *= gain; r[i] *= gain }
        return StereoBuffer(l: l, r: r, sampleRate: buffer.sampleRate)
    }

    /// Integrated loudness per ITU-R BS.1770-4 / EBU R128, in LUFS.
    ///
    /// K-weighted (high-shelf + high-pass), measured over 400 ms blocks at
    /// 75 % overlap, gated absolutely at -70 LUFS and relatively at
    /// -10 LU under the gated mean.
    ///
    /// - Returns: The loudness, or `nil` when no block survives the
    ///   absolute gate (effective silence).
    public static func integrated(of buffer: StereoBuffer) -> Double? {
        let sr = buffer.sampleRate
        let n = buffer.frameCount
        guard n > Int(0.4 * sr) else { return nil }

        // K-weight both channels.
        var kl = buffer.l
        var kr = buffer.r
        applyKWeighting(&kl, sampleRate: sr)
        applyKWeighting(&kr, sampleRate: sr)

        // 400 ms blocks, 100 ms hop.
        let block = Int(0.4 * sr)
        let hop = Int(0.1 * sr)
        var blockPowers: [Double] = []
        var start = 0
        while start + block <= n {
            var sum = 0.0
            for i in start..<(start + block) {
                sum += Double(kl[i]) * Double(kl[i]) + Double(kr[i]) * Double(kr[i])
            }
            blockPowers.append(sum / Double(block))
            start += hop
        }
        guard !blockPowers.isEmpty else { return nil }

        func loudness(_ power: Double) -> Double { -0.691 + 10 * log10(max(power, 1e-15)) }

        // Absolute gate at -70 LUFS.
        let absGated = blockPowers.filter { loudness($0) > -70 }
        guard !absGated.isEmpty else { return nil }

        // Relative gate 10 LU under the absolute-gated mean.
        let absMean = absGated.reduce(0, +) / Double(absGated.count)
        let threshold = loudness(absMean) - 10
        let relGated = absGated.filter { loudness($0) > threshold }
        guard !relGated.isEmpty else { return loudness(absMean) }

        let mean = relGated.reduce(0, +) / Double(relGated.count)
        return loudness(mean)
    }

    // MARK: - K-weighting (BS.1770 pre-filter + RLB high-pass)

    /// The two K-weighting biquads, designed at the buffer's sample rate
    /// from the standard's analogue parameters (shelf: +4 dB, ~1681 Hz,
    /// Q 0.707; high-pass: ~38 Hz, Q 0.5).
    static func applyKWeighting(_ x: inout [Float], sampleRate sr: Double) {
        // Stage 1: high-shelf.
        do {
            let f0 = 1681.9744509555319
            let gainDB = 3.99984385397
            let q = 0.7071752369554196
            let k = tan(Double.pi * f0 / sr)
            let vh = pow(10.0, gainDB / 20.0)
            let vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            let b0 = (vh + vb * k / q + k * k) / a0
            let b1 = 2 * (k * k - vh) / a0
            let b2 = (vh - vb * k / q + k * k) / a0
            let a1 = 2 * (k * k - 1) / a0
            let a2 = (1 - k / q + k * k) / a0
            biquad(&x, b0, b1, b2, a1, a2)
        }
        // Stage 2: RLB high-pass.
        do {
            let f0 = 38.13547087602444
            let q = 0.5003270373238773
            let k = tan(Double.pi * f0 / sr)
            let a0 = 1 + k / q + k * k
            let b0 = 1 / a0
            let b1 = -2 / a0
            let b2 = 1 / a0
            let a1 = 2 * (k * k - 1) / a0
            let a2 = (1 - k / q + k * k) / a0
            biquad(&x, b0, b1, b2, a1, a2)
        }
    }

    private static func biquad(_ x: inout [Float],
                               _ b0: Double, _ b1: Double, _ b2: Double,
                               _ a1: Double, _ a2: Double) {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let xn = Double(x[i])
            let yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = xn
            y2 = y1; y1 = yn
            x[i] = Float(yn)
        }
    }
}
