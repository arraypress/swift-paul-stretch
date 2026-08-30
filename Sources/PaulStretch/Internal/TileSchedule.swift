//
//  TileSchedule.swift
//  SwiftPaulStretch
//
//  Tile planning + range-based equal-power crossfade scheduling. Tiling fills
//  the target duration when a single stretch pass (capped by maxStretch)
//  falls short.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// One placement of the stretched block on the output timeline, with its
/// crossfade regions. All times in seconds.
struct Tile {
    var start, fadeInEnd, fadeOutStart, end: Double
}

/// Lays stretched blocks end-to-end with `fadeSec` of overlap, until the
/// target duration is covered. The first tile starts at full level (no
/// fade-in); every subsequent tile fades in over the previous tile's
/// fade-out — an equal-power (sin/cos) crossfade at every seam.
func planTiles(stretchedDur: Double, targetSec: Double, fadeSec: Double) -> [Tile] {
    let stride = max(0.01, stretchedDur - fadeSec)
    var tiles: [Tile] = []
    var start = 0.0
    var first = true
    while start < targetSec {
        tiles.append(Tile(start: start,
                          fadeInEnd: first ? start : start + fadeSec,
                          fadeOutStart: start + stretchedDur - fadeSec,
                          end: start + stretchedDur))
        start += stride
        first = false
    }
    return tiles
}

// MARK: - Seam shape

/// How much of a seam's crossfade is equal-power (`1`, sin/cos) versus
/// equal-gain (`0`, linear), given how correlated the two sides are.
///
/// Equal-power keeps the summed POWER flat when the sides are uncorrelated
/// — a stretched block's tail and head, decorrelated by the phase
/// randomisation. On correlated material it overshoots: the same pad
/// crossfading into itself summed to +0.98 dBFS and clipped at every seam
/// of a tape-slow render. Equal-gain is a convex blend, so it can never
/// exceed the louder side — but on uncorrelated material it dips 3 dB at
/// the middle of every seam. Neither is right for both; the blend that
/// keeps the midpoint at unity power for a given correlation `ρ` is solved
/// here in closed form (midpoint power `2m²(1 + ρ)` with per-side gain
/// `m`, so `m = 1 / √(2(1 + ρ))`, mapped between the two shapes' midpoint
/// gains 0.5 and 1/√2).
func seamBlend(correlation rho: Double) -> Double {
    let r = min(max(rho, 0), 1)
    let m = 1 / (2 * (1 + r)).squareRoot()
    let w = (m - 0.5) / (0.70710678118654752 - 0.5)
    return min(max(w, 0), 1)
}

/// The zero-lag normalised cross-correlation between the last `fadeFrames`
/// of a block and its first `fadeFrames` — the two sides of every seam when
/// that block is tiled. `0` for anything too short to have a seam.
func seamCorrelation(l: [Float], r: [Float], fadeFrames: Int) -> Double {
    let n = l.count
    let f = min(fadeFrames, n / 2)
    guard f > 8 else { return 0 }
    var dot = 0.0, tail = 0.0, head = 0.0
    for i in 0..<f {
        let aL = Double(l[n - f + i]), aR = Double(r[n - f + i])
        let bL = Double(l[i]), bR = Double(r[i])
        dot += aL * bL + aR * bR
        tail += aL * aL + aR * aR
        head += bL * bL + bR * bR
    }
    guard tail > 0, head > 0 else { return 0 }
    return dot / (tail * head).squareRoot()
}

/// Overlap-adds the stretched block at each tile position with crossfade
/// envelopes at every seam — equal-power (sin/cos) at `seamBlend` 1, linear
/// at 0, blended between (see ``seamBlend(correlation:)``) — restricted to
/// output frames `[rangeStart, rangeEnd)`.
///
/// `outL`/`outR` are local buffers whose index `0` corresponds to absolute
/// output frame `rangeStart`; contributions are **added**, so callers zero
/// them first. `provider` is called once per overlapping tile with the range
/// of stretched-block frames that tile needs; it must invoke `body` with
/// channel pointers positioned so `pointer[0]` is stretched frame
/// `range.lowerBound`. This lets the in-memory renderer hand out slices of a
/// materialised block while the chunked renderer re-renders just the needed
/// range — both feed the exact same accumulation loop, keeping their outputs
/// bit-identical.
func accumulateTiles(_ tiles: [Tile],
                     sampleRate sr: Double,
                     stretchedLength sLen: Int,
                     rangeStart: Int,
                     rangeEnd: Int,
                     outL: UnsafeMutablePointer<Float>,
                     outR: UnsafeMutablePointer<Float>,
                     seamBlend w: Double = 1,
                     provider: (Range<Int>, (UnsafePointer<Float>, UnsafePointer<Float>) -> Void) -> Void) {
    let halfPi = Double.pi / 2
    // `w == 1` takes the original expressions verbatim, so stretched renders
    // stay bit-identical to what the golden tests pinned.
    let pure = w == 1
    for tile in tiles {
        let startFrame = Int(tile.start * sr)
        let fadeInDur = tile.fadeInEnd - tile.start
        let foStartLocal = tile.fadeOutStart - tile.start
        let fadeOutDur = tile.end - tile.fadeOutStart

        let srcLo = max(0, rangeStart - startFrame)
        let srcHi = min(sLen, rangeEnd - startFrame)
        if srcLo >= srcHi { continue }

        provider(srcLo..<srcHi) { sL, sR in
            for srcIdx in srcLo..<srcHi {
                let f = startFrame + srcIdx
                let localT = Double(srcIdx) / sr
                var g = 1.0
                if fadeInDur > 0 && localT < fadeInDur {
                    if pure {
                        g = sin((localT / fadeInDur) * halfPi)
                    } else {
                        let t = localT / fadeInDur
                        g = (1 - w) * t + w * sin(t * halfPi)
                    }
                } else if fadeOutDur > 0 && localT >= foStartLocal {
                    let fo = min(max((localT - foStartLocal) / fadeOutDur, 0), 1)
                    g = pure ? cos(fo * halfPi) : (1 - w) * (1 - fo) + w * cos(fo * halfPi)
                }
                let gf = Float(g)
                outL[f - rangeStart] += sL[srcIdx - srcLo] * gf
                outR[f - rangeStart] += sR[srcIdx - srcLo] * gf
            }
        }
    }
}
