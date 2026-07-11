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

/// Overlap-adds the stretched block at each tile position with equal-power
/// (sin/cos) crossfade envelopes, restricted to output frames
/// `[rangeStart, rangeEnd)`.
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
                     provider: (Range<Int>, (UnsafePointer<Float>, UnsafePointer<Float>) -> Void) -> Void) {
    let halfPi = Double.pi / 2
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
                    g = sin((localT / fadeInDur) * halfPi)
                } else if fadeOutDur > 0 && localT >= foStartLocal {
                    let fo = min(max((localT - foStartLocal) / fadeOutDur, 0), 1)
                    g = cos(fo * halfPi)
                }
                let gf = Float(g)
                outL[f - rangeStart] += sL[srcIdx - srcLo] * gf
                outR[f - rangeStart] += sR[srcIdx - srcLo] * gf
            }
        }
    }
}
