//
//  RenderPlan.swift
//  SwiftPaulStretch
//
//  Resolves (source, parameters, seed) into a fully-determined description
//  of the render: shaped source, per-layer kernels + tile schedules, and the
//  output geometry. The in-memory and chunked renderers both execute plans,
//  which is what keeps their outputs bit-identical.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// One stretch layer of a tiled render: its kernel (or the passthrough
/// source), the stretched block's length, its tile schedule and mix gain.
struct LayerPlan {
    /// Mix gain applied when layering is active (`1` in single-layer plans).
    let gain: Float
    /// `true` when the stretch ratio collapsed to ≤ 1.001 — tiles then read
    /// the shaped source directly, with no stretch and no normalisation.
    let passthrough: Bool
    /// The stretch kernel, or `nil` for a passthrough layer.
    let kernel: StretchKernel?
    /// The frame count of the (stretched or passthrough) block tiles read from.
    let stretchedFrames: Int
    /// The tile schedule filling the target duration with this layer's block.
    let tiles: [Tile]
}

/// A fully-resolved render: shaped source, engine path and output geometry.
struct RenderPlan {

    /// Which engine executes the plan.
    enum Path {
        /// PaulStretch or tape-slow: one or more layers, each tiled to the
        /// target. `layeredNormalize` is `true` when layering is active
        /// (the mix is then peak-normalised to 0.92 like the reference).
        case tiled([LayerPlan], layeredNormalize: Bool)
        /// Spectral freeze (static or scanning).
        case freeze(FreezeKernel)
        /// Granular cloud.
        case granular(GranularKernel)
        /// Phase-vocoder stretch (sequential — rendered through streams).
        case phaseVocoder(PVSpec)
        /// Nothing to render (source empty or too short to freeze).
        case empty
    }

    /// The source after reverse and tape-speed shaping.
    let src: StereoBuffer
    let sampleRate: Double
    let params: StretchParameters
    let seed: UInt64
    let path: Path
    /// Frames rendered before any loop trim (the "pre-loop timeline").
    let preLoopFrames: Int
    /// The loop crossfade length in frames, or `0` when not looping (or the
    /// render is too short to donate a crossfade).
    let loopCrossfadeFrames: Int
    /// Frames in the delivered render (after the loop trim, if any).
    var finalFrames: Int { max(0, preLoopFrames - loopCrossfadeFrames) }
}

/// Builds the plan for a render, mirroring the reference pipeline exactly:
/// reverse → tape speed → engine selection → per-layer ratio/tile planning →
/// loop-trim geometry.
func makeRenderPlan(_ source: StereoBuffer, _ p: StretchParameters, seed: UInt64) -> RenderPlan {
    var src = source
    if p.reverse { src = src.reversed() }
    if abs(p.tapeSpeed - 1) > 0.001 { src = src.applyingTapeSpeed(p.tapeSpeed) }
    let sr = src.sampleRate
    let renderSeconds = p.seamlessLoop
        ? p.targetSeconds + StretchRenderer.loopCrossfadeSeconds
        : p.targetSeconds

    let path: RenderPlan.Path
    let preLoopFrames: Int

    if src.frameCount == 0 {
        path = .empty
        preLoopFrames = 0
    } else if p.mode == .spectralFreeze {
        if let kernel = FreezeKernel(input: src,
                                     positionNorm: p.freezePosition,
                                     smear: p.freezeSmear,
                                     scan: p.freezeScan,
                                     targetSeconds: renderSeconds,
                                     windowSeconds: p.windowSeconds,
                                     seed: seed) {
            path = .freeze(kernel)
            preLoopFrames = kernel.outputLength
        } else {
            path = .empty
            preLoopFrames = 0
        }
    } else if p.mode == .granularCloud {
        preLoopFrames = Int(renderSeconds * sr)
        let kernel = GranularKernel(input: src,
                                    outputLength: preLoopFrames,
                                    grainSeconds: p.grainSeconds,
                                    density: p.grainDensity,
                                    positionJitter: p.grainPositionJitter,
                                    timeJitter: p.grainTimeJitter,
                                    pitchSpread: p.grainPitchSpread,
                                    basePitch: p.pitchSemitones,
                                    panSpread: p.grainPanSpread,
                                    seed: seed)
        path = .granular(kernel)
    } else if p.mode == .phaseVocoder {
        // The vocoder stretches (or compresses) to the target in one pass —
        // no tiling, no layering (see StretchMode.phaseVocoder docs).
        let desiredRatio = renderSeconds / src.duration
        let spec = PVSpec(input: src,
                          ratio: max(0.05, desiredRatio),
                          windowSeconds: p.windowSeconds,
                          pitchSemitones: p.pitchSemitones)
        path = .phaseVocoder(spec)
        preLoopFrames = Int(renderSeconds * sr)
    } else {
        // Tape-slow caps the stretch ratio at 1 (no PaulStretch) — the
        // varispeed source is just tile-looped to fill the target.
        let effMaxStretch = p.mode == .tapeSlow ? 1.0 : p.maxStretch
        let layered = (p.mode == .paulStretch && p.layering != .off)
        let recipes: [(scale: Double, gain: Float, pitch: Double)] = layered
            ? (p.layering.layers ?? [(1.0, 1.0, 0)])
            : [(1.0, 1.0, 0)]
        let inputDur = src.duration

        var layers: [LayerPlan] = []
        for (i, recipe) in recipes.enumerated() {
            let layerSeed = layered ? seed &+ UInt64(i) &* 0x9E3779B97F4A7C15 : seed
            let desiredRatio = (renderSeconds * recipe.scale) / inputDur
            let ratio = max(1, min(desiredRatio, effMaxStretch * max(1, recipe.scale)))
            let passthrough = ratio <= 1.001
            let kernel: StretchKernel? = passthrough ? nil
                : StretchKernel(input: src,
                                ratio: ratio,
                                windowSeconds: p.windowSeconds,
                                phaseRandomness: p.phaseRandomness,
                                pitchSemitones: p.pitchSemitones + recipe.pitch,
                                onsetSensitivity: p.onsetSensitivity,
                                seed: layerSeed)
            let stretchedFrames = kernel?.outputLength ?? src.frameCount
            let stretchedDur = Double(stretchedFrames) / sr
            let tileFade = min(2, stretchedDur / 4)
            let tiles = planTiles(stretchedDur: stretchedDur,
                                  targetSec: renderSeconds,
                                  fadeSec: tileFade)
            layers.append(LayerPlan(gain: recipe.gain,
                                    passthrough: passthrough,
                                    kernel: kernel,
                                    stretchedFrames: stretchedFrames,
                                    tiles: tiles))
        }
        path = .tiled(layers, layeredNormalize: layered)
        preLoopFrames = Int(renderSeconds * sr)
    }

    var loopCrossfadeFrames = 0
    if p.seamlessLoop, preLoopFrames > 0 {
        let xf = min(Int(StretchRenderer.loopCrossfadeSeconds * sr), preLoopFrames / 4)
        if xf >= 256 { loopCrossfadeFrames = xf }
    }

    return RenderPlan(src: src,
                      sampleRate: sr,
                      params: p,
                      seed: seed,
                      path: path,
                      preLoopFrames: preLoopFrames,
                      loopCrossfadeFrames: loopCrossfadeFrames)
}
