//
//  PitchFlutterTests.swift
//  SwiftPaulStretch
//
//  Measuring the amplitude ripple an upward pitch shift produces.
//

import XCTest
@testable import PaulStretch

final class PitchFlutterTests: XCTestCase {

    /// A steady tone. Anything that is not flat in the output came from us.
    private func tone(seconds: Double = 2, hz: Double = 440) -> StereoBuffer {
        let sr = 44100.0
        let n = Int(seconds * sr)
        let l = (0..<n).map { 0.5 * sinf(Float(Double($0) * 2 * .pi * hz / sr)) }
        return StereoBuffer(l: l, r: l, sampleRate: sr)
    }

    /// Peak-to-trough spread of short-window RMS, in dB. A steady tone stretched
    /// with no pitch shift should be nearly flat; ripple here is modulation the
    /// renderer introduced.
    private func rippleDB(_ buffer: StereoBuffer) -> Double {
        let sr = buffer.sampleRate
        let window = Int(0.05 * sr)
        var levels: [Double] = []
        var i = window * 4          // skip the ramp-in
        while i + window < buffer.l.count - window * 4 {
            var sum = 0.0
            for k in i..<(i + window) { sum += Double(buffer.l[k] * buffer.l[k]) }
            let rms = (sum / Double(window)).squareRoot()
            if rms > 1e-6 { levels.append(20 * log10(rms)) }
            i += window
        }
        guard let hi = levels.max(), let lo = levels.min() else { return 0 }
        return hi - lo
    }

    /// The report: "+11 or +12 flutters, negative does not".
    func testUpwardPitchShiftRipple() throws {
        let source = tone()
        var flat = StretchParameters()
        flat.targetSeconds = 8
        flat.windowSeconds = 0.25
        // Phase randomisation is itself an amplitude modulator on a pure tone —
        // at 1.0 it swamped the measurement at 25 dB and told us nothing about
        // pitch. Zero isolates the pitch mechanism.
        flat.phaseRandomness = 0

        func ripple(_ semitones: Double) -> Double {
            var p = flat
            p.pitchSemitones = semitones
            p.fadeInSeconds = 0
            p.fadeOutSeconds = 0
            return rippleDB(StretchRenderer.render(source, parameters: p))
        }

        let none = ripple(0)
        let up11 = ripple(11)
        let up12 = ripple(12)
        let down11 = ripple(-11)
        let down12 = ripple(-12)
        print("RIPPLE dB  none=\(String(format: "%.1f", none)) "
              + "+11=\(String(format: "%.1f", up11)) +12=\(String(format: "%.1f", up12)) "
              + "-11=\(String(format: "%.1f", down11)) -12=\(String(format: "%.1f", down12))")

        // The asymmetry is the finding, and it matches the report: shifting UP
        // modulates more than shifting DOWN by the same interval. Measured at
        // ~19-20 dB up against ~14-17 dB down.
        //
        // This is a REGRESSION GUARD, not a claim that the current numbers are
        // acceptable — they are not. `pitchShiftBins` linearly interpolates
        // complex bins, which is not phase-coherent: the real and imaginary
        // parts of adjacent bins of a windowed sinusoid have a fixed phase
        // relationship that interpolation destroys, and the error depends on
        // where the fractional bin position falls. Shifting up reads source
        // positions less than one bin apart, so consecutive output bins
        // interpolate repeatedly within the SAME adjacent pair; shifting down
        // steps more than a bin at a time and interpolates less.
        //
        // The known-correct fix is to shift pitch by RESAMPLING the input and
        // compensating the stretch ratio, which is what PaulStretch itself
        // does, rather than remapping bins. That is a real change to the DSP
        // and wants listening tests, not just this number.
        XCTAssertLessThan(up12, 24, "upward pitch ripple must not get worse")
        XCTAssertLessThan(down12, 24, "downward pitch ripple must not get worse")
    }
}
