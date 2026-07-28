//
//  PitchVoices.swift
//  SwiftPaulStretch
//
//  A live pitch shifter with detuned voices — the thing that makes a static
//  drone move.
//
//  Created by David Sherlock on 7/28/26.
//

import Foundation

#if !os(watchOS)

/// Shifts pitch live, optionally into several detuned voices.
///
/// ### Why a delay line and not an FFT
///
/// The stretch engine already pitches by resampling, but that changes a whole
/// render — it cannot be drawn on a curve, and a glide is exactly what a long
/// drone wants. This runs in the live chain instead, so its pitch is a
/// parameter like any other and an automation lane can sweep it across twenty
/// minutes.
///
/// A crossfaded delay line is the right tool for that. Reading a buffer faster
/// or slower than it is written IS a pitch shift; the read pointer drifts away
/// from the write pointer, and the only problem is what happens when it has to
/// wrap. Two taps half a buffer apart, each windowed by a Hann curve, solve it:
/// `w(x) + w(x + 0.5) == 1` for a Hann window, so the pair sums to unity
/// everywhere while each tap is silent exactly where it wraps. The seam is
/// inaudible because nothing is crossing it.
///
/// The cost is a gentle smearing at large intervals, which on the washed-out
/// material this library produces is an asset rather than a flaw.
///
/// ### Voices
///
/// Detuned voices are the reason this exists as much as the pitch control is. A
/// PaulStretch drone is spectrally smeared and harmonically static; two or three
/// copies a few cents apart beat against each other and the tone breathes
/// without the harmony moving at all. They are spread across the stereo field,
/// because detuning without width just sounds out of tune.
final class PitchVoices {

    /// One shifting voice.
    private struct Voice {
        var ratio: Double
        /// Read lag behind the write pointer, in samples, `0..<bufferLength`.
        var phase: Double
        /// `-1` hard left to `+1` hard right.
        var pan: Double
    }

    private let sampleRate: Double
    /// Buffer length in samples.
    ///
    /// 80 ms. Longer lowers the wrap rate — the frequency at which the taps
    /// crossfade — but smears transients further; shorter is tighter but starts
    /// to sound like a chorus rather than a shift.
    private let length: Int
    private var bufferL: [Float]
    private var bufferR: [Float]
    private var writeIndex = 0
    private var voices: [Voice]
    private let mix: Double

    /// - Parameters:
    ///   - sampleRate: Stream rate, in hertz.
    ///   - semitones: Coarse shift, `-24…24`.
    ///   - cents: Fine shift, `-100…100`.
    ///   - spread: Detune between voices, in cents. `0` makes them identical,
    ///     which is why voice count alone does nothing.
    ///   - voiceCount: `1…4`.
    ///   - mix: Wet blend, `0…100`. Below 100 the dry signal remains, so a
    ///     shifted voice is an INTERVAL rather than a transposition.
    init(sampleRate: Double, semitones: Double, cents: Double,
         spread: Double, voiceCount: Int, mix: Double) {
        self.sampleRate = sampleRate
        length = max(256, Int(0.08 * sampleRate))
        bufferL = [Float](repeating: 0, count: length)
        bufferR = [Float](repeating: 0, count: length)
        self.mix = min(max(mix / 100, 0), 1)

        let count = min(max(voiceCount, 1), 4)
        let base = semitones + cents / 100
        // Built from locals rather than from `self`: the closure would capture
        // an object whose members are not all initialised yet.
        let bufferLength = length
        voices = (0..<count).map { i -> Voice in
            // Voices are spread symmetrically around the requested pitch, so
            // turning spread up does not also transpose the sound.
            let offset = count == 1 ? 0
                : (Double(i) / Double(count - 1) - 0.5) * 2 * spread / 100
            let pan = count == 1 ? 0 : (Double(i) / Double(count - 1) - 0.5) * 2
            return Voice(ratio: pow(2, (base + offset) / 12),
                         // Stagger the starting phases so the voices do not all
                         // wrap on the same sample, which would make the
                         // crossfade audible as a single periodic pulse.
                         phase: Double(i) / Double(count) * Double(bufferLength),
                         pan: pan)
        }
    }

    /// Reads the buffer `lag` samples behind the write pointer, interpolated.
    private func read(_ buffer: [Float], lag: Double) -> Float {
        let position = Double(writeIndex) - lag
        var index = position.truncatingRemainder(dividingBy: Double(length))
        if index < 0 { index += Double(length) }
        let i = Int(index)
        let frac = Float(index - Double(i))
        let a = buffer[i % length]
        let b = buffer[(i + 1) % length]
        return a + (b - a) * frac
    }

    /// Hann, which is what makes the pair of taps sum to unity.
    private func window(_ x: Double) -> Float {
        Float(0.5 - 0.5 * cos(2 * .pi * x))
    }

    func process(l: [Float], r: [Float]) -> (l: [Float], r: [Float]) {
        guard mix > 0.0001, !voices.isEmpty else { return (l, r) }
        var outL = l, outR = r
        let half = Double(length) / 2
        let gain = Float(1.0 / Double(voices.count).squareRoot())

        for n in 0..<l.count {
            bufferL[writeIndex] = l[n]
            bufferR[writeIndex] = r[n]

            var wetL: Float = 0, wetR: Float = 0
            for v in voices.indices {
                // Read position advances by `ratio` per output sample while
                // write advances by 1, so the LAG between them changes by
                // (1 - ratio). Shifting up means the read catches up.
                //
                // The sign was the other way round, which made the read pointer
                // stand still at an octave up: measured 5 Hz for a 220 Hz tone
                // that should have come out at 440.
                voices[v].phase += 1 - voices[v].ratio
                if voices[v].phase >= Double(length) { voices[v].phase -= Double(length) }
                if voices[v].phase < 0 { voices[v].phase += Double(length) }

                let p0 = voices[v].phase
                let p1 = p0 < half ? p0 + half : p0 - half
                let w0 = window(p0 / Double(length))
                let w1 = window(p1 / Double(length))

                let sampleL = read(bufferL, lag: p0) * w0 + read(bufferL, lag: p1) * w1
                let sampleR = read(bufferR, lag: p0) * w0 + read(bufferR, lag: p1) * w1

                // Equal-power pan, so spreading voices does not change level.
                let angle = (voices[v].pan + 1) * .pi / 4
                wetL += sampleL * Float(cos(angle))
                wetR += sampleR * Float(sin(angle))
            }

            writeIndex = (writeIndex + 1) % length
            let wet = Float(mix), dry = Float(1 - mix)
            outL[n] = l[n] * dry + wetL * gain * wet
            outR[n] = r[n] * dry + wetR * gain * wet
        }
        return (outL, outR)
    }
}

extension PitchVoices: PureStage {
    /// The buffer is only 80 ms and the dry path is unaffected, so there is
    /// nothing meaningful to flush.
    func tail() -> (l: [Float], r: [Float]) { ([], []) }
}

#endif  // !os(watchOS)
