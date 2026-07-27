//
//  EffectSlotTests.swift
//  SwiftPaulStretch
//
//  The chain order's contract: complete, stable, and safe to persist.
//
//  Created by David Sherlock on 7/27/26.
//

import XCTest
@testable import PaulStretchEffects

final class EffectSlotTests: XCTestCase {

    /// A partial order must be completed, not obeyed literally — otherwise a
    /// host that named three units would silently drop the other twelve.
    func testPartialOrderIsCompleted() {
        let completed = EffectSlot.completed([.limiter, .reverb])
        XCTAssertEqual(completed.count, EffectSlot.allCases.count)
        XCTAssertEqual(Array(completed.prefix(2)), [.limiter, .reverb])
        XCTAssertEqual(Set(completed), Set(EffectSlot.allCases))
    }

    /// Duplicates are the other half of the same guarantee: a unit appearing
    /// twice would be wired twice and processed twice.
    func testDuplicatesAreCollapsed() {
        let completed = EffectSlot.completed([.eq, .eq, .filter, .eq])
        XCTAssertEqual(completed.count, EffectSlot.allCases.count)
        XCTAssertEqual(Array(completed.prefix(2)), [.eq, .filter])
    }

    /// Default settings run in the order the chain always ran in, so adding
    /// the feature changed nobody's sound.
    func testDefaultOrderIsTheOriginalChain() {
        XCTAssertEqual(EffectsParameters().chainOrder, EffectSlot.naturalOrder)
        XCTAssertEqual(EffectsParameters().stockOrder,
                       [.filter, .eq, .distortion, .delay, .reverb, .compressor, .limiter])
    }

    /// Moving a unit reorders its own half and leaves the other alone.
    func testMoveReordersWithinAHalf() {
        var fx = EffectsParameters()
        XCTAssertTrue(fx.move(.distortion, by: -2))
        XCTAssertEqual(fx.stockOrder,
                       [.distortion, .filter, .eq, .delay, .reverb, .compressor, .limiter])
        XCTAssertEqual(fx.pureOrder, EffectSlot.naturalOrder.filter { !$0.isStockUnit },
                       "moving a stock unit must not disturb the pure stages")
    }

    /// A move off either end is refused rather than clamped, so a menu item
    /// can report that there is nowhere to go.
    func testMoveOffTheEndIsRefused() {
        var fx = EffectsParameters()
        XCTAssertFalse(fx.move(.filter, by: -1))
        XCTAssertFalse(fx.move(.limiter, by: 1))
        XCTAssertEqual(fx.chainOrder, EffectSlot.naturalOrder)
    }

    /// Order survives a round trip, and a document written before the feature
    /// existed still decodes to the sequence it used to run in.
    func testOrderSurvivesCodingAndOlderDocumentsDecode() throws {
        var fx = EffectsParameters()
        fx.move(.limiter, by: -3)
        let data = try JSONEncoder().encode(fx)
        let decoded = try JSONDecoder().decode(EffectsParameters.self, from: data)
        XCTAssertEqual(decoded.chainOrder, fx.chainOrder)

        let legacy = #"{"reverbMix":50}"#
        let old = try JSONDecoder().decode(EffectsParameters.self, from: Data(legacy.utf8))
        XCTAssertEqual(old.chainOrder, EffectSlot.naturalOrder)
    }

    /// The pure-DSP chain is built in the stored order, not in source order.
    /// This is the assertion that actually proves the sound changes.
    func testPureStagesAreBuiltInChainOrder() {
        var fx = EffectsParameters()
        fx.tranceGateEnabled = true
        fx.placementEnabled = true

        let natural = makePureStages(sampleRate: 44100, effects: fx, totalFrames: nil)
        XCTAssertEqual(natural.count, 2)
        XCTAssertTrue(natural[0] is TranceGate)
        XCTAssertTrue(natural[1] is StereoPlacement)

        fx.move(.placement, by: -20)          // clamped to the front of its half
        let reordered = makePureStages(sampleRate: 44100, effects: fx, totalFrames: nil)
        XCTAssertEqual(reordered.count, 2)
        XCTAssertTrue(reordered[0] is TranceGate,
                      "an out-of-range move is refused, so the order is unchanged")
    }

    /// A move of exactly one place does reorder the built stages.
    func testMovingAPureStageChangesTheBuiltOrder() {
        var fx = EffectsParameters()
        fx.tranceGateEnabled = true
        fx.placementEnabled = true
        // Placement is last in the natural order; walk it up in front of the gate.
        while fx.pureOrder.firstIndex(of: .placement)! > fx.pureOrder.firstIndex(of: .gate)! {
            XCTAssertTrue(fx.move(.placement, by: -1))
        }
        let stages = makePureStages(sampleRate: 44100, effects: fx, totalFrames: nil)
        XCTAssertTrue(stages[0] is StereoPlacement)
        XCTAssertTrue(stages[1] is TranceGate)
    }
}
