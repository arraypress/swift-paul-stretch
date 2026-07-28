//
//  EffectSlot.swift
//  SwiftPaulStretch
//
//  Every unit in the chain, and the order they run in.
//
//  Created by David Sherlock on 7/27/26.
//

import Foundation

#if !os(watchOS)

/// One unit in an effect chain.
///
/// The chain used to be a hard-coded sequence in two places — the `AVAudioUnit`
/// wiring in ``EffectChain/install(in:from:to:format:)`` and the `if enabled`
/// ladder in `makePureStages`. That made order an implementation detail nobody
/// could change, and order is not a detail: distortion before a filter is a
/// different sound from distortion after it, and a limiter anywhere but last is
/// not a limiter.
///
/// So the order lives in the settings, as a list of these, and both halves of
/// the chain read it.
public enum EffectSlot: String, Codable, CaseIterable, Sendable {

    // Stock AVAudioUnits, wired into the engine graph.
    case filter, eq, distortion, delay, reverb, compressor, limiter
    // Pure-DSP stages, run in sequence inside one node.
    case wow, sweepFilter, gate, pump, autoPan, shimmer, space, placement, pitch

    /// `true` when this slot is an `AVAudioUnit` in the engine graph rather
    /// than a pure-DSP stage.
    ///
    /// The two halves cannot be interleaved with each other: the stock units
    /// are nodes in the graph and the pure stages all live inside a single
    /// node, so reordering is meaningful WITHIN each half. Callers that present
    /// a chain should group by this.
    public var isStockUnit: Bool {
        switch self {
        case .filter, .eq, .distortion, .delay, .reverb, .compressor, .limiter:
            return true
        default:
            return false
        }
    }

    /// A short label for a rack or a menu.
    public var label: String {
        switch self {
        case .filter:      return "Filter"
        case .eq:          return "EQ"
        case .distortion:  return "Drive"
        case .delay:       return "Delay"
        case .reverb:      return "Reverb"
        case .compressor:  return "Comp"
        case .limiter:     return "Limit"
        case .wow:         return "Motion"
        case .sweepFilter: return "Sweep"
        case .gate:        return "Gate"
        case .pump:        return "Pump"
        case .autoPan:     return "Auto Pan"
        case .shimmer:     return "Shimmer"
        case .space:       return "Space"
        case .placement:   return "Place"
        case .pitch:       return "Pitch"
        }
    }

    /// The order the chain ran in before it was configurable. New settings
    /// start here, and any slot missing from a decoded order is appended in
    /// this sequence, so a document written by an older build behaves exactly
    /// as it did.
    public static let naturalOrder: [EffectSlot] = [
        .filter, .eq, .distortion, .delay, .reverb, .compressor, .limiter,
        // Pitch sits before the reverbs: shifting a tail smears it, where
        // shifting into them lets each voice ring out in the same space.
        .wow, .pitch, .sweepFilter, .gate, .pump, .autoPan, .shimmer, .space, .placement,
    ]

    /// Completes a partial order.
    ///
    /// Anything the caller left out is appended in ``naturalOrder``, and
    /// anything unrecognised is dropped. This is what makes the order safe to
    /// persist: adding a unit to the library must never invalidate a saved
    /// chain, and it must never silently disappear from it either.
    ///
    /// - Parameter order: A possibly partial or duplicated list.
    /// - Returns: Every slot exactly once.
    public static func completed(_ order: [EffectSlot]) -> [EffectSlot] {
        var seen = Set<EffectSlot>()
        var result: [EffectSlot] = []
        for slot in order where !seen.contains(slot) {
            seen.insert(slot)
            result.append(slot)
        }
        for slot in naturalOrder where !seen.contains(slot) {
            result.append(slot)
        }
        return result
    }
}

#endif  // !os(watchOS)
