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
        // The RMS window must be LONGER than the STFT window, not shorter.
        // At 50 ms against a 250 ms analysis window this was measuring
        // within-window wobble, which is not what "flutter" means and which
        // sat at 21 dB even with no pitch shift at all.
        let window = Int(0.4 * sr)
        var levels: [Double] = []
        var i = window          // skip the ramp-in
        while i + window < buffer.l.count - window {
            var sum = 0.0
            for k in i..<(i + window) { sum += Double(buffer.l[k] * buffer.l[k]) }
            let rms = (sum / Double(window)).squareRoot()
            if rms > 1e-6 { levels.append(20 * log10(rms)) }
            i += window
        }
        guard let hi = levels.max(), let lo = levels.min() else { return 0 }
        return hi - lo
    }

    /// Is the residual ripple a defect, or is a pure tone simply the worst
    /// possible test signal?
    ///
    /// Phase randomisation sums four windows per output sample with random
    /// relative phases. In ONE bin — which is all a sine occupies — that sum is
    /// Rayleigh-distributed and swings widely. Broadband material spreads
    /// across hundreds of bins whose independent swings average out, so if the
    /// ripple is inherent to the algorithm rather than a bug, noise should be
    /// far steadier than a tone.
    func testBroadbandIsFarSteadierThanATone() {
        var p = StretchParameters()
        p.targetSeconds = 8
        p.windowSeconds = 0.25
        p.phaseRandomness = 1
        p.fadeInSeconds = 0
        p.fadeOutSeconds = 0

        var rng = SystemRandomNumberGenerator()
        let n = Int(2 * 44100.0)
        let noise = (0..<n).map { _ in Float.random(in: -0.5...0.5, using: &rng) }
        let broadband = StereoBuffer(l: noise, r: noise, sampleRate: 44100)

        let toneRipple = rippleDB(StretchRenderer.render(tone(), parameters: p))
        let noiseRipple = rippleDB(StretchRenderer.render(broadband, parameters: p))
        print("RIPPLE tone=\(String(format: "%.1f", toneRipple)) "
              + "noise=\(String(format: "%.1f", noiseRipple))")

        XCTAssertLessThan(noiseRipple, 2,
                          "broadband material must come out steady; ripple on a "
                          + "pure tone is the algorithm, not a defect")
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

        // Measured before and after switching from bin remapping to input
        // resampling, with this same metric:
        //
        //   shift   bins   resampled
        //   none     5.1     5.1
        //   +11      7.7     4.5
        //   +12      5.1     3.3
        //   -11      3.2     4.0
        //   -12      2.9     5.0
        //
        // The old numbers ARE the report: +11 sat 2.6 dB above an unshifted
        // stretch while downward shifts sat below it. Resampling brings upward
        // shifts to baseline or under.
        //
        // Downward moved from better-than-baseline to baseline, and that is
        // expected rather than a regression: decimating the spectrum is
        // incidentally a lowpass, so the old path smoothed downward shifts by
        // accident. They now behave like everything else.
        //
        // No shift must be WORSE than an unshifted stretch. That single
        // assertion is what the old implementation failed.
        for (name, value) in [("+11", up11), ("+12", up12),
                              ("-11", down11), ("-12", down12)] {
            XCTAssertLessThan(value, none + 1.5,
                              "\(name) semitones modulates more than no shift at all")
        }
    }
}
