//
//  StretchPlayerTests.swift
//  Tests for SwiftPaulStretch
//
//  Player state logic (load / seek / region / stop) and the pure-DSP
//  signature that drives host rebake caching.
//
//  Created by David Sherlock on 7/12/26.
//

import XCTest
import PaulStretch
@testable import PaulStretchEffects

@MainActor
final class StretchPlayerTests: XCTestCase {

    private func tone(seconds: Double) -> StereoBuffer {
        let sr = 44_100.0
        let n = Int(sr * seconds)
        var l = [Float](repeating: 0, count: n)
        for i in 0..<n { l[i] = Float(0.3 * sin(2 * Double.pi * 220 * Double(i) / sr)) }
        return StereoBuffer(l: l, r: l, sampleRate: sr)
    }

    func testLoadSetsDurationAndRestingState() {
        let player = StretchPlayer()
        XCTAssertEqual(player.duration, 0)
        player.load(tone(seconds: 2), loop: false)
        XCTAssertEqual(player.duration, 2.0, accuracy: 0.01)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.spectrum.count, 56)
    }

    func testSeekClampsToTheLoadedRange() {
        let player = StretchPlayer()
        player.load(tone(seconds: 2), loop: false)
        player.seek(to: 1.0)
        XCTAssertEqual(player.currentTime, 1.0, accuracy: 1e-6)
        player.seek(to: 99)
        XCTAssertEqual(player.currentTime, 2.0, accuracy: 0.01)
        player.seek(to: -5)
        XCTAssertEqual(player.currentTime, 0, accuracy: 1e-6)
    }

    func testRegionBoundsThePlayheadAndStopReturnsToItsStart() {
        let player = StretchPlayer()
        player.load(tone(seconds: 2), loop: true)
        player.seek(to: 1.9)
        player.setRegion(0.5...1.5)
        XCTAssertEqual(player.currentTime, 0.5, accuracy: 1e-6,
                       "playhead outside the new region snaps to its start")
        player.seek(to: 0.2)
        XCTAssertEqual(player.currentTime, 0.5, accuracy: 1e-6, "seek clamps to the region")
        player.stop()
        XCTAssertEqual(player.currentTime, 0.5, accuracy: 1e-6, "stop returns to the region start")
        player.setRegion(nil)
        player.seek(to: 0.2)
        XCTAssertEqual(player.currentTime, 0.2, accuracy: 1e-6, "clearing the region restores the full range")
    }

    func testDegenerateRegionFallsBackToTheFullBuffer() {
        let player = StretchPlayer()
        player.load(tone(seconds: 2), loop: false, region: 1.0...1.005)
        player.seek(to: 1.8)
        XCTAssertEqual(player.currentTime, 1.8, accuracy: 1e-6)
    }

    func testPlayPauseTogglesStateAndKeepsPosition() {
        let player = StretchPlayer()
        player.load(tone(seconds: 2), loop: false)
        player.seek(to: 0.5)
        player.play()
        XCTAssertTrue(player.isPlaying)
        player.pause()
        XCTAssertFalse(player.isPlaying)
        XCTAssertGreaterThanOrEqual(player.currentTime, 0.5)
        player.stop()
        XCTAssertEqual(player.currentTime, 0, accuracy: 1e-6)
    }

    // MARK: - Pure-DSP signature

    func testPureDSPSignatureIgnoresTheLiveStockChain() {
        let base = EffectsParameters().pureDSPSignature
        var fx = EffectsParameters()
        fx.reverbEnabled = true; fx.reverbMix = 80
        fx.eqEnabled = true; fx.eqLowGain = 6
        fx.filterEnabled = true; fx.filterCutoff = 900
        fx.delayEnabled = true; fx.delayTime = 0.7
        fx.distortionEnabled = true; fx.distortionPreGain = -3
        fx.compressorEnabled = true; fx.compressorThreshold = -25
        fx.limiterEnabled = true; fx.limiterPreGain = 4
        XCTAssertEqual(fx.pureDSPSignature, base,
                       "live stock-chain tweaks must not force a rebake")
    }

    func testPureDSPSignatureTracksEveryBakedField() {
        let mutations: [(String, (inout EffectsParameters) -> Void)] = [
            ("shimmerEnabled", { $0.shimmerEnabled = true }),
            ("shimmerMix", { $0.shimmerMix = 55 }),
            ("shimmerPitch", { $0.shimmerPitch = 7 }),
            ("shimmerFeedback", { $0.shimmerFeedback = 60 }),
            ("shimmerSize", { $0.shimmerSize = 20 }),
            ("shimmerDamping", { $0.shimmerDamping = 90 }),
            ("shimmerClimbSeconds", { $0.shimmerClimbSeconds = 2 }),
            ("convolutionReverbEnabled", { $0.convolutionReverbEnabled = true }),
            ("convolutionReverbProfile", { $0.convolutionReverbProfile = .cathedral }),
            ("convolutionReverbDecaySeconds", { $0.convolutionReverbDecaySeconds = 12 }),
            ("convolutionReverbMix", { $0.convolutionReverbMix = 50 }),
            ("convolutionReverbCustomIRData", { $0.convolutionReverbCustomIRData = Data([1, 2, 3]) }),
            ("convolutionReverbCustomIRName", { $0.convolutionReverbCustomIRName = "stairwell" }),
            ("sweepFilterEnabled", { $0.sweepFilterEnabled = true }),
            ("sweepFilterShape", { $0.sweepFilterShape = .bandPass }),
            ("sweepFilterCutoff", { $0.sweepFilterCutoff = 400 }),
            ("sweepFilterResonance", { $0.sweepFilterResonance = 8 }),
            ("sweepFilterBassCut", { $0.sweepFilterBassCut = 120 }),
            ("sweepFilterLFOPeriod", { $0.sweepFilterLFOPeriod = 60 }),
            ("sweepFilterLFODepth", { $0.sweepFilterLFODepth = 2 }),
            ("wowEnabled", { $0.wowEnabled = true }),
            ("wowAmount", { $0.wowAmount = 1 }),
            ("wowRateHz", { $0.wowRateHz = 2 }),
            ("pumpEnabled", { $0.pumpEnabled = true }),
            ("pumpDepth", { $0.pumpDepth = 1 }),
            ("pumpRateHz", { $0.pumpRateHz = 0.2 }),
            ("autoPanEnabled", { $0.autoPanEnabled = true }),
            ("autoPanDepth", { $0.autoPanDepth = 1 }),
            ("autoPanRateHz", { $0.autoPanRateHz = 0.5 }),
            ("parameterLanes", { $0.parameterLanes["pump.depth"] = AutomationLane(points: [
                AutomationPoint(t: 0, v: 0), AutomationPoint(t: 1, v: 1)]) }),
        ]
        let base = EffectsParameters().pureDSPSignature
        for (name, mutate) in mutations {
            var fx = EffectsParameters()
            mutate(&fx)
            XCTAssertNotEqual(fx.pureDSPSignature, base,
                              "changing \(name) must change the signature (rebake bug)")
        }
    }

    func testPureDSPSignatureDistinguishesCustomImpulses() {
        var a = EffectsParameters()
        a.convolutionReverbEnabled = true
        var b = a
        a.convolutionReverbCustomIRData = Data([1, 2, 3, 4])
        b.convolutionReverbCustomIRData = Data([9, 9, 9, 9])
        XCTAssertNotEqual(a.pureDSPSignature, b.pureDSPSignature)
        XCTAssertNotEqual(a.pureDSPSignature, EffectsParameters().pureDSPSignature,
                          "loading an impulse must change the signature even with the reverb already enabled")
    }
}
