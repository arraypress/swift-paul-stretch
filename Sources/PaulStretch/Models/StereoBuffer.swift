//
//  StereoBuffer.swift
//  SwiftPaulStretch
//
//  The deinterleaved stereo Float buffer every algorithm in the library
//  consumes and produces, plus the source/output shaping transforms
//  (trim, normalise, reverse, tape speed, stereo width, fades, seamless loop).
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// A deinterleaved stereo audio buffer of 32-bit floats.
///
/// `StereoBuffer` is the interchange type for the whole library: sources go
/// in as `StereoBuffer`s, renders come out as `StereoBuffer`s, and every
/// transform is a pure `StereoBuffer → StereoBuffer` function. That keeps
/// the DSP trivially testable from a plain command-line harness — no audio
/// engine required.
///
/// ```swift
/// let source = try AudioFileIO.readStereo(url: fileURL)
/// let region = source.trimmed(fromSeconds: 2.0, toSeconds: 6.5).peakNormalized()
/// ```
public struct StereoBuffer: Sendable, Equatable {

    /// Left-channel samples.
    public var l: [Float]

    /// Right-channel samples.
    public var r: [Float]

    /// The sample rate of the audio, in hertz.
    public var sampleRate: Double

    /// The number of frames (samples per channel) in the buffer.
    public var frameCount: Int { l.count }

    /// The duration of the buffer, in seconds.
    public var duration: Double { Double(l.count) / sampleRate }

    /// Creates a stereo buffer from two channel arrays.
    ///
    /// Both channels are expected to have the same length; all library
    /// algorithms index the two arrays in lockstep using `l.count`.
    ///
    /// - Parameters:
    ///   - l: Left-channel samples.
    ///   - r: Right-channel samples.
    ///   - sampleRate: The sample rate of the audio, in hertz.
    public init(l: [Float], r: [Float], sampleRate: Double) {
        self.l = l
        self.r = r
        self.sampleRate = sampleRate
    }

    /// Creates a silent stereo buffer of a given length.
    ///
    /// - Parameters:
    ///   - frameCount: The number of frames of silence.
    ///   - sampleRate: The sample rate of the audio, in hertz.
    public init(silenceFrames frameCount: Int, sampleRate: Double) {
        self.l = [Float](repeating: 0, count: max(0, frameCount))
        self.r = [Float](repeating: 0, count: max(0, frameCount))
        self.sampleRate = sampleRate
    }

    /// `true` when the buffer contains no frames.
    ///
    /// Renders return an empty buffer when they are cancelled, so this is
    /// also the "was it cancelled?" check after a call that took an
    /// `isCancelled` closure.
    public var isEmpty: Bool { l.isEmpty }
}

// MARK: - Source shaping

extension StereoBuffer {

    /// Returns a copy of the buffer cut down to a time region.
    ///
    /// Out-of-range times are clamped (a start beyond the end of the buffer
    /// clamps to the final frame); a non-empty buffer always yields at least
    /// one frame. Use this to stretch just a selected region of a source.
    ///
    /// - Parameters:
    ///   - startSeconds: The start of the region, in seconds.
    ///   - endSeconds: The end of the region, in seconds.
    /// - Returns: The trimmed buffer.
    public func trimmed(fromSeconds startSeconds: Double, toSeconds endSeconds: Double) -> StereoBuffer {
        guard frameCount > 0 else { return self }
        let s = max(0, min(frameCount - 1, Int(startSeconds * sampleRate)))
        let e = max(s + 1, min(frameCount, Int(endSeconds * sampleRate)))
        return StereoBuffer(l: Array(l[s..<e]), r: Array(r[s..<e]), sampleRate: sampleRate)
    }

    /// Returns a copy of the buffer scaled so its absolute peak hits `target`.
    ///
    /// A silent buffer is returned unchanged.
    ///
    /// - Parameter target: The desired absolute peak, `0…1`. Defaults to `0.98`.
    /// - Returns: The peak-normalised buffer.
    public func peakNormalized(to target: Float = 0.98) -> StereoBuffer {
        var peak: Float = 0
        for i in 0..<frameCount { peak = max(peak, max(abs(l[i]), abs(r[i]))) }
        guard peak > 0 else { return self }
        let g = target / peak
        var outL = l, outR = r
        for i in 0..<frameCount { outL[i] *= g; outR[i] *= g }
        return StereoBuffer(l: outL, r: outR, sampleRate: sampleRate)
    }

    /// Returns the buffer played backwards.
    ///
    /// Reversing *before* stretching gives swelling, bowed attacks; the
    /// smeared result sounds quite different from reversing afterwards.
    ///
    /// - Returns: The reversed buffer.
    public func reversed() -> StereoBuffer {
        StereoBuffer(l: Array(l.reversed()), r: Array(r.reversed()), sampleRate: sampleRate)
    }

    /// Returns the buffer varispeed-resampled like a tape machine.
    ///
    /// Linear-interpolation resampling: `speed < 1` makes the audio longer
    /// *and* lower-pitched (the "slowed + reverb" treatment), `speed > 1`
    /// shorter and higher. Speeds within 0.001 of `1` return the buffer
    /// unchanged.
    ///
    /// - Parameter speed: The playback-speed factor, e.g. `0.5` for
    ///   half-speed / one octave down.
    /// - Returns: The resampled buffer.
    public func applyingTapeSpeed(_ speed: Double) -> StereoBuffer {
        if abs(speed - 1) < 0.001 { return self }
        let n = frameCount
        let outFrames = max(1, Int((Double(n) / speed).rounded(.up)))
        var outL = [Float](repeating: 0, count: outFrames)
        var outR = [Float](repeating: 0, count: outFrames)
        for i in 0..<outFrames {
            let srcPos = Double(i) * speed
            let i0 = Int(srcPos.rounded(.down))
            if i0 >= 0 && i0 < n {
                let frac = Float(srcPos - Double(i0))
                let i1 = min(i0 + 1, n - 1)
                outL[i] = l[i0] * (1 - frac) + l[i1] * frac
                outR[i] = r[i0] * (1 - frac) + r[i1] * frac
            }
        }
        return StereoBuffer(l: outL, r: outR, sampleRate: sampleRate)
    }
}

// MARK: - Output shaping

extension StereoBuffer {

    /// Returns the buffer with mid/side stereo widening applied.
    ///
    /// `1` leaves the image unchanged, `0` collapses to mono, values above
    /// `1` widen. Widths within 0.001 of `1` return the buffer unchanged.
    ///
    /// - Parameter width: The stereo width factor.
    /// - Returns: The widened (or narrowed) buffer.
    public func applyingStereoWidth(_ width: Double) -> StereoBuffer {
        var out = self
        applyStereoWidthInPlace(&out, width: width)
        return out
    }

    /// Returns the buffer with linear fade-in and fade-out envelopes.
    ///
    /// Fades are capped relative to the buffer length (fade-in at 10 %,
    /// fade-out at 15 %) so short renders never fade past their midpoint.
    ///
    /// - Parameters:
    ///   - fadeInSeconds: The requested fade-in length, in seconds.
    ///   - fadeOutSeconds: The requested fade-out length, in seconds.
    /// - Returns: The faded buffer.
    public func applyingFades(fadeInSeconds: Double, fadeOutSeconds: Double) -> StereoBuffer {
        var out = self
        applyFadesInPlace(&out, fadeInSeconds: fadeInSeconds, fadeOutSeconds: fadeOutSeconds)
        return out
    }

    /// Returns a copy that loops seamlessly, made by equal-power crossfading
    /// the tail into the head.
    ///
    /// The result is `crossfadeSeconds` shorter than the input (the tail is
    /// consumed by the crossfade). Buffers too short to donate a crossfade
    /// (under ~4× the crossfade, or crossfades below 256 frames) are
    /// returned unchanged. Loop the result end-to-start with no gap and the
    /// seam is inaudible under the PaulStretch wash.
    ///
    /// - Parameter crossfadeSeconds: The crossfade length, in seconds.
    ///   Defaults to ``StretchRenderer/loopCrossfadeSeconds``.
    /// - Returns: A loop-ready buffer.
    public func seamlesslyLooped(crossfadeSeconds: Double = StretchRenderer.loopCrossfadeSeconds) -> StereoBuffer {
        let xf = min(Int(crossfadeSeconds * sampleRate), frameCount / 4)
        if xf < 256 { return self }
        let newLen = frameCount - xf
        var dl = [Float](repeating: 0, count: newLen)
        var dr = [Float](repeating: 0, count: newLen)
        for i in 0..<xf {
            let k = Float(i) / Float(xf)
            let fin = k.squareRoot(); let fout = (1 - k).squareRoot()
            dl[i] = l[i] * fin + l[newLen + i] * fout
            dr[i] = r[i] * fin + r[newLen + i] * fout
        }
        for i in xf..<newLen { dl[i] = l[i]; dr[i] = r[i] }
        return StereoBuffer(l: dl, r: dr, sampleRate: sampleRate)
    }
}

// MARK: - Display support

extension StereoBuffer {

    /// Returns per-column peak levels for waveform drawing.
    ///
    /// Each column holds the peak absolute sample of its slice of the left
    /// channel, found by sub-sampling (up to 48 probes per column) — display
    /// accuracy, not measurement accuracy, at any zoom level for free.
    ///
    /// - Parameter columns: The number of columns the waveform view draws.
    /// - Returns: `columns` peak values in `0…1` (empty for an empty buffer).
    public func peaks(columns: Int) -> [Float] {
        let n = frameCount
        guard n > 0, columns > 0 else { return [] }
        var out = [Float](repeating: 0, count: columns)
        for c in 0..<columns {
            let start = c * n / columns
            let end = max(start + 1, (c + 1) * n / columns)
            let step = max(1, (end - start) / 48)
            var pk: Float = 0
            var i = start
            while i < end && i < n { pk = max(pk, abs(l[i])); i += step }
            out[c] = pk
        }
        return out
    }
}

// MARK: - In-place implementations (shared with the render pipeline)

/// Mid/side stereo widener, in place. Kept as a free function so the render
/// pipeline and the public value-returning API run the exact same float ops.
func applyStereoWidthInPlace(_ b: inout StereoBuffer, width: Double) {
    if abs(width - 1) < 0.001 { return }
    let w = Float(width)
    for i in 0..<b.frameCount {
        let mid = (b.l[i] + b.r[i]) * 0.5
        let side = (b.l[i] - b.r[i]) * 0.5 * w
        b.l[i] = mid + side
        b.r[i] = mid - side
    }
}

/// Caps requested fades relative to the total duration: fade-in at 10 % and
/// fade-out at 15 % of the render.
func effectiveFades(_ fadeIn: Double, _ fadeOut: Double, _ totalSeconds: Double) -> (Double, Double) {
    (max(0, min(fadeIn, totalSeconds * 0.10)), max(0, min(fadeOut, totalSeconds * 0.15)))
}

/// Linear fade-in / fade-out envelopes, in place.
func applyFadesInPlace(_ buffer: inout StereoBuffer, fadeInSeconds: Double, fadeOutSeconds: Double) {
    let sr = buffer.sampleRate
    let total = buffer.frameCount
    let (efi, efo) = effectiveFades(fadeInSeconds, fadeOutSeconds, Double(total) / sr)
    let fadeIn = max(0, min(total, Int(efi * sr)))
    let fadeOut = max(0, min(total - fadeIn, Int(efo * sr)))
    if fadeIn > 0 {
        for i in 0..<fadeIn { let g = Float(i) / Float(fadeIn); buffer.l[i] *= g; buffer.r[i] *= g }
    }
    if fadeOut > 0 {
        for i in 0..<fadeOut { let g = Float(i) / Float(fadeOut); buffer.l[total - 1 - i] *= g; buffer.r[total - 1 - i] *= g }
    }
}
