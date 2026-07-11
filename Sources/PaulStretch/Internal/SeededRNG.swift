//
//  SeededRNG.swift
//  SwiftPaulStretch
//
//  Deterministic PRNG + seed derivation for per-window phase randomisation.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// xorshift64 mapped to `[0, 1)`.
///
/// Every random decision in the library flows through a seeded `FastRNG`, so
/// renders are fully reproducible: the same source, parameters and seed
/// always produce bit-identical output. That reproducibility is also what
/// makes multicore and chunked rendering possible — any worker can recreate
/// the exact phase sequence for any window from the window's seed alone.
struct FastRNG {
    var s: UInt64

    init(seed: UInt64) { s = seed != 0 ? seed : 0x9E3779B97F4A7C15 }

    /// The next value in `[0, 1)`.
    mutating func unit() -> Double {
        s ^= s << 13
        s ^= s >> 7
        s ^= s << 17
        return Double(s >> 11) * (1.0 / 9007199254740992.0)
    }
}

/// splitmix64 finaliser — turns sequential/linear inputs into full-entropy,
/// well-decorrelated 64-bit values.
///
/// Seeding adjacent windows with a *linear* function of the window index
/// gives correlated phase sequences between neighbours, which is audible as
/// amplitude flutter in the overlap-add. Mixing through splitmix64 removes
/// the correlation. (Measured, not guessed.)
@inline(__always)
func mixSeed(_ x: UInt64) -> UInt64 {
    var z = x &+ 0x9E3779B97F4A7C15
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    return z ^ (z >> 31)
}

/// Deterministic, well-mixed PRNG seed for window/hop `b` of a render seeded
/// with `base`. Any worker (or chunk) computing window `b` derives the same
/// seed, so shared boundary windows come out identical everywhere.
@inline(__always)
func blockSeed(_ base: UInt64, _ b: Int) -> UInt64 {
    mixSeed(base ^ mixSeed(UInt64(bitPattern: Int64(b)) &+ 1))
}

/// The smallest power of two that is `>= x`.
func nextPow2(_ x: Int) -> Int {
    var n = 1
    while n < x { n <<= 1 }
    return n
}
