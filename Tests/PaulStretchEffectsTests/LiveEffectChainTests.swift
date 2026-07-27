//
//  LiveEffectChainTests.swift
//  Proves the live chain produces the same audio as the offline bake, so
//  moving effects onto the audio thread is not a change in sound.
//

import XCTest
import PaulStretch
@testable import PaulStretchEffects

#if !os(watchOS)

final class LiveEffectChainTests: XCTestCase {

    private let sr = 44100.0

    private func source(_ seconds: Double) -> StereoBuffer {
        let n = Int(sr * seconds)
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            let t = Double(i) / sr
            l[i] = Float(0.3 * sin(2 * .pi * 180 * t) + 0.2 * sin(2 * .pi * 447 * t))
            r[i] = Float(0.3 * sin(2 * .pi * 181 * t) + 0.2 * sin(2 * .pi * 443 * t))
        }
        return StereoBuffer(l: l, r: r, sampleRate: sr)
    }

    /// Runs `src` through the live chain in `quantum`-sized blocks, exactly
    /// as a render callback would.
    private func live(_ src: StereoBuffer, _ fx: EffectsParameters, quantum: Int = 512) -> StereoBuffer {
        let chain = LiveEffectChain(sampleRate: sr, effects: fx)
        var outL = [Float](), outR = [Float]()
        outL.reserveCapacity(src.frameCount); outR.reserveCapacity(src.frameCount)
        var pos = 0
        while pos < src.frameCount {
            let n = min(quantum, src.frameCount - pos)
            var l = Array(src.l[pos..<pos+n])
            var r = Array(src.r[pos..<pos+n])
            chain.render(l: &l, r: &r)
            outL.append(contentsOf: l); outR.append(contentsOf: r)
            pos += n
        }
        return StereoBuffer(l: outL, r: outR, sampleRate: sr)
    }

    /// The tail-less stages must match the offline bake sample-for-sample:
    /// they hold no lookahead, so block boundaries are irrelevant to them.
    func testTaillessStagesMatchOfflineBake() {
        let src = source(3)
        var fx = EffectsParameters()
        fx.wowEnabled = true; fx.wowAmount = 0.4
        fx.sweepFilterEnabled = true; fx.sweepFilterCutoff = 1800
        fx.pumpEnabled = true; fx.autoPanEnabled = true

        let offline = EffectsBaker.bakePureStages(src, effects: fx)
        let online = live(src, fx)

        XCTAssertEqual(online.frameCount, src.frameCount, "live render must be length-preserving")
        let n = min(offline.frameCount, online.frameCount)
        var worst: Float = 0
        for i in 0..<n { worst = max(worst, abs(offline.l[i] - online.l[i])) }
        XCTAssertLessThan(worst, 1e-6, "live chain diverged from the offline bake by \(worst)")
    }

    /// Block size must not change the result for tail-less stages.
    func testResultIsIndependentOfQuantumSize() {
        let src = source(2)
        var fx = EffectsParameters()
        fx.wowEnabled = true; fx.wowAmount = 0.3
        fx.pumpEnabled = true

        let a = live(src, fx, quantum: 256)
        let b = live(src, fx, quantum: 1024)
        let n = min(a.frameCount, b.frameCount)
        var worst: Float = 0
        for i in 0..<n { worst = max(worst, abs(a.l[i] - b.l[i])) }
        XCTAssertLessThan(worst, 1e-6, "quantum size changed the output by \(worst)")
    }

    /// Feedback stages (shimmer) can't match the bake sample-for-sample —
    /// the bake appends a ring-out the live path never sees — but the live
    /// render must stay length-preserving, finite and audible.
    func testShimmerRendersLiveWithoutBlowingUp() {
        let src = source(3)
        var fx = EffectsParameters()
        fx.shimmerEnabled = true; fx.shimmerMix = 0.5

        let online = live(src, fx)
        XCTAssertEqual(online.frameCount, src.frameCount)
        var peak: Float = 0
        for v in online.l { XCTAssertTrue(v.isFinite, "shimmer produced a non-finite sample"); peak = max(peak, abs(v)) }
        XCTAssertGreaterThan(peak, 0.01, "shimmer produced silence")
        XCTAssertLessThan(peak, 4.0, "shimmer feedback ran away")
    }

    /// The convolver withholds frames until it has a whole block. Serving
    /// those short returns as silence gates the audio at the block rate — it
    /// sounded like a trance gate. The output must be continuous.
    func testConvolutionReverbDoesNotGateTheOutput() {
        let src = source(4)
        var fx = EffectsParameters()
        fx.convolutionReverbEnabled = true
        fx.convolutionReverbMix = 0.6

        let online = live(src, fx)
        XCTAssertEqual(online.frameCount, src.frameCount)

        // Ignore the priming head, then assert no run of near-silence long
        // enough to be heard as a gap.
        let head = Int(sr * 0.5)
        var run = 0, worstRun = 0
        for i in head..<online.frameCount {
            if abs(online.l[i]) < 1e-5 && abs(online.r[i]) < 1e-5 {
                run += 1; worstRun = max(worstRun, run)
            } else { run = 0 }
        }
        XCTAssertLessThan(worstRun, 64,
                          "output is gated — longest silent run was \(worstRun) frames")
    }

    /// The same failure, measured as periodicity: a gate makes block-rate
    /// amplitude modulation. Compare energy across consecutive small windows.
    func testConvolutionEnergyIsSteadyAcrossBlocks() {
        let src = source(4)
        var fx = EffectsParameters()
        fx.convolutionReverbEnabled = true
        fx.convolutionReverbMix = 0.6

        let online = live(src, fx)
        let head = Int(sr * 0.5)
        let win = 128
        var energies = [Float]()
        var i = head
        while i + win < online.frameCount {
            var e: Float = 0
            for j in i..<(i + win) { e += online.l[j] * online.l[j] }
            energies.append((e / Float(win)).squareRoot())
            i += win
        }
        let mean = energies.reduce(0, +) / Float(energies.count)
        let minE = energies.min() ?? 0
        XCTAssertGreaterThan(minE, mean * 0.2,
                             "block-rate amplitude dropouts: min \(minE) vs mean \(mean)")
    }

    /// Changing parameters mid-stream must not stall, crash or emit garbage —
    /// this is the whole point of the class.
    func testParameterChangeMidStreamIsSafe() {
        let src = source(2)
        var fx = EffectsParameters()
        fx.wowEnabled = true; fx.wowAmount = 0.2
        let chain = LiveEffectChain(sampleRate: sr, effects: fx)

        var pos = 0, swaps = 0
        while pos < src.frameCount {
            let n = min(512, src.frameCount - pos)
            var l = Array(src.l[pos..<pos+n]), r = Array(src.r[pos..<pos+n])
            chain.render(l: &l, r: &r)
            for v in l { XCTAssertTrue(v.isFinite) }
            XCTAssertEqual(l.count, n, "render must preserve quantum length")
            if pos % 2048 == 0 {                       // tweak while "playing"
                fx.wowAmount = Float(swaps % 5) * 0.2
                fx.sweepFilterEnabled = (swaps % 2 == 0)
                chain.setEffects(fx)
                swaps += 1
            }
            pos += n
        }
        XCTAssertGreaterThan(swaps, 3, "test should have exercised several swaps")
    }
}

#endif
