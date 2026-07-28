//
//  PitchVoicesTests.swift
//  SwiftPaulStretch
//
//  Does the live pitch shifter actually shift pitch?
//

import XCTest
@testable import PaulStretchEffects

final class PitchVoicesTests: XCTestCase {

    private let sr = 44100.0

    private func tone(_ hz: Double, seconds: Double = 1) -> [Float] {
        (0..<Int(seconds * sr)).map { Float(sin(Double($0) * 2 * .pi * hz / sr)) * 0.5 }
    }

    /// Dominant frequency, by counting zero crossings over the steady middle.
    ///
    /// Crude next to an FFT and entirely sufficient here: the input is one
    /// sine, so the crossing rate IS the frequency, and it needs no windowing
    /// argument to be believed.
    private func dominantHz(_ x: [Float]) -> Double {
        let start = x.count / 4, end = x.count * 3 / 4
        var crossings = 0
        for i in (start + 1)..<end where (x[i - 1] < 0) != (x[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(end - start) / sr)
    }

    private func run(_ stage: PitchVoices, _ input: [Float]) -> [Float] {
        // In blocks, as the live chain calls it — state has to carry across.
        var out: [Float] = []
        var i = 0
        while i < input.count {
            let n = min(512, input.count - i)
            let chunk = Array(input[i..<(i + n)])
            let processed = stage.process(l: chunk, r: chunk)
            out += processed.l
            i += n
        }
        return out
    }

    /// An octave up doubles the frequency. Fully wet, so the dry does not
    /// confuse the measurement.
    func testShiftsUpAnOctave() {
        let input = tone(220)
        let stage = PitchVoices(sampleRate: sr, semitones: 12, cents: 0,
                                spread: 0, voiceCount: 1, mix: 100)
        let hz = dominantHz(run(stage, input))
        XCTAssertEqual(hz, 440, accuracy: 12, "an octave up must double the pitch")
    }

    /// And down halves it.
    func testShiftsDownAnOctave() {
        let input = tone(440)
        let stage = PitchVoices(sampleRate: sr, semitones: -12, cents: 0,
                                spread: 0, voiceCount: 1, mix: 100)
        let hz = dominantHz(run(stage, input))
        XCTAssertEqual(hz, 220, accuracy: 12, "an octave down must halve the pitch")
    }

    /// A fifth is 7 semitones: 220 -> ~329.6.
    func testShiftsAFifth() {
        let stage = PitchVoices(sampleRate: sr, semitones: 7, cents: 0,
                                spread: 0, voiceCount: 1, mix: 100)
        XCTAssertEqual(dominantHz(run(stage, tone(220))), 329.6, accuracy: 10)
    }

    /// Cents are a hundredth of a semitone, so +100 cents is a semitone.
    func testCentsAreAHundredthOfASemitone() {
        let stage = PitchVoices(sampleRate: sr, semitones: 0, cents: 100,
                                spread: 0, voiceCount: 1, mix: 100)
        XCTAssertEqual(dominantHz(run(stage, tone(440))), 466.2, accuracy: 8)
    }

    /// At zero shift and full wet the output must still be the input — the
    /// crossfade has to be transparent when nothing is being shifted, or every
    /// setting rides on a broken baseline.
    func testUnityShiftIsTransparent() {
        let input = tone(440)
        let stage = PitchVoices(sampleRate: sr, semitones: 0, cents: 0,
                                spread: 0, voiceCount: 1, mix: 100)
        let out = run(stage, input)
        XCTAssertEqual(dominantHz(out), 440, accuracy: 2)
        // And it must not collapse in level.
        let peak = out[out.count / 2..<out.count].map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.3, "a unity shift must not lose the signal")
    }

    /// Spread detunes the voices apart. With no spread they are identical and
    /// sum coherently; with spread they beat, so the envelope moves.
    func testSpreadMakesTheVoicesBeat() {
        func envelopeSwing(spread: Double) -> Float {
            let stage = PitchVoices(sampleRate: sr, semitones: 0, cents: 0,
                                    spread: spread, voiceCount: 3, mix: 100)
            let out = run(stage, tone(220, seconds: 2))
            // Peak level per 100 ms window over the steady portion.
            let window = Int(0.1 * sr)
            var levels: [Float] = []
            var i = out.count / 4
            while i + window < out.count * 3 / 4 {
                levels.append(out[i..<(i + window)].map { abs($0) }.max() ?? 0)
                i += window
            }
            return (levels.max() ?? 0) - (levels.min() ?? 0)
        }
        XCTAssertGreaterThan(envelopeSwing(spread: 30), envelopeSwing(spread: 0) + 0.02,
                             "detuned voices must beat against each other")
    }

    /// Mix at zero leaves the signal completely alone.
    func testZeroMixIsBypass() {
        let input = tone(440)
        let stage = PitchVoices(sampleRate: sr, semitones: 12, cents: 0,
                                spread: 0, voiceCount: 1, mix: 0)
        let out = run(stage, input)
        for i in 0..<min(out.count, input.count) {
            XCTAssertEqual(out[i], input[i], accuracy: 0.0001)
        }
    }
}
