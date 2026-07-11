//
//  StretchRenderer.swift
//  SwiftPaulStretch
//
//  The full render pipeline: source shaping → stretch / tape-slow / freeze
//  → tiling + layering → stereo width → seamless loop or fades. In-memory
//  entry points live here; the chunked/streaming entry points extend this
//  type in ChunkedRenderer.swift.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// The top-level render pipeline.
///
/// `StretchRenderer` turns a source buffer and a ``StretchParameters`` into
/// a finished ambient render: it shapes the source (reverse, tape speed),
/// runs the selected engine (``StretchMode``), tiles and layers the result
/// to the target duration, then applies stereo width and either a seamless
/// loop crossfade or fade envelopes.
///
/// Two families of entry points produce **bit-identical audio**:
///
/// - ``render(_:parameters:seed:isCancelled:progress:)`` — everything in
///   memory. Simple, and fine on the Mac; a 60-minute stereo render holds
///   ~1.3 GB (plus intermediates).
/// - ``renderChunks(_:parameters:chunkFrames:seed:isCancelled:progress:handler:)``
///   and ``renderToWAVFile(_:parameters:url:bitDepth:chunkFrames:seed:isCancelled:progress:)``
///   — memory-bounded streaming for iOS, where holding a full hour in RAM
///   gets the process jetsam-killed. Peak memory stays at a few chunks
///   regardless of render length.
///
/// ```swift
/// var params = StretchParameters()
/// params.targetSeconds = 45
/// params.seamlessLoop = true                 // loop-and-play: the iOS-friendly default
/// let loop = StretchRenderer.render(source, parameters: params)
/// ```
public enum StretchRenderer {

    /// The crossfade length used by ``StretchParameters/seamlessLoop``
    /// renders, in seconds. Loop renders are produced this much longer than
    /// the target and the excess tail is equal-power crossfaded into the head.
    public static let loopCrossfadeSeconds = 6.0

    /// A well-decorrelated seed for variation `index` of a render.
    ///
    /// Use this for batch workflows ("give me ten different versions of
    /// these settings"): each index yields an audibly different wash from
    /// the same source and parameters, deterministically.
    ///
    /// - Parameters:
    ///   - index: The variation number, `0, 1, 2, …` (`0` returns `base`).
    ///   - base: The base seed. Defaults to ``PaulStretcher/defaultSeed``.
    /// - Returns: The seed for that variation.
    public static func variationSeed(_ index: Int, from base: UInt64 = PaulStretcher.defaultSeed) -> UInt64 {
        base &+ UInt64(index) &* 0x9E3779B97F4A7C15
    }

    /// Renders the full pipeline into a single in-memory buffer.
    ///
    /// - Parameters:
    ///   - source: The source audio (already trimmed/normalised as desired —
    ///     see ``StereoBuffer/trimmed(fromSeconds:toSeconds:)`` and
    ///     ``StereoBuffer/peakNormalized(to:)``).
    ///   - parameters: The render settings.
    ///   - seed: The render seed. Defaults to ``PaulStretcher/defaultSeed``.
    ///   - isCancelled: Polled periodically; return `true` to stop early.
    ///   - progress: Called with the completed fraction, `0…1`, from worker
    ///     threads.
    /// - Returns: The finished render — or an empty buffer if cancelled (or
    ///   the source was empty / too short to freeze).
    public static func render(_ source: StereoBuffer,
                              parameters: StretchParameters,
                              seed: UInt64 = PaulStretcher.defaultSeed,
                              isCancelled: () -> Bool = { false },
                              progress: ((Double) -> Void)? = nil) -> StereoBuffer {
        let plan = makeRenderPlan(source, parameters, seed: seed)

        var out: StereoBuffer
        switch plan.path {
        case .empty:
            return StereoBuffer(l: [], r: [], sampleRate: plan.sampleRate)

        case .freeze(let kernel):
            out = SpectralFreezer.renderFull(kernel, sampleRate: plan.sampleRate,
                                             isCancelled: isCancelled, progress: progress)
            if out.isEmpty { return out }

        case .granular(let kernel):
            let totalFrames = plan.preLoopFrames
            var outL = [Float](repeating: 0, count: totalFrames)
            var outR = [Float](repeating: 0, count: totalFrames)
            if totalFrames > 0 {
                outL.withUnsafeMutableBufferPointer { lp in
                    outR.withUnsafeMutableBufferPointer { rp in
                        kernel.renderRangeParallel(0, totalFrames,
                                                   outL: lp.baseAddress!, outR: rp.baseAddress!,
                                                   isCancelled: isCancelled, onGrainsDone: nil)
                    }
                }
            }
            if isCancelled() { return StereoBuffer(l: [], r: [], sampleRate: plan.sampleRate) }
            normalizeToPeak(&outL, &outR, target: 0.92)
            progress?(1)
            out = StereoBuffer(l: outL, r: outR, sampleRate: plan.sampleRate)

        case .phaseVocoder(let spec):
            let totalFrames = plan.preLoopFrames
            guard let stream = spec.makeStream() else {
                return StereoBuffer(l: [], r: [], sampleRate: plan.sampleRate)
            }
            var outL = [Float](repeating: 0, count: totalFrames)
            var outR = [Float](repeating: 0, count: totalFrames)
            var ok = true
            if totalFrames > 0 {
                outL.withUnsafeMutableBufferPointer { lp in
                    outR.withUnsafeMutableBufferPointer { rp in
                        ok = stream.render(into: lp.baseAddress!, rp.baseAddress!,
                                           count: totalFrames, isCancelled: isCancelled)
                    }
                }
            }
            if !ok || isCancelled() { return StereoBuffer(l: [], r: [], sampleRate: plan.sampleRate) }
            normalizeToPeak(&outL, &outR, target: 0.92)
            progress?(1)
            out = StereoBuffer(l: outL, r: outR, sampleRate: plan.sampleRate)

        case .tiled(let layers, let layeredNormalize):
            guard let mixed = renderTiledFull(plan, layers: layers,
                                              layeredNormalize: layeredNormalize,
                                              isCancelled: isCancelled, progress: progress) else {
                return StereoBuffer(l: [], r: [], sampleRate: plan.sampleRate)
            }
            out = mixed
        }

        applyStereoWidthInPlace(&out, width: parameters.stereoWidth)

        if parameters.seamlessLoop {
            out = out.seamlesslyLooped(crossfadeSeconds: loopCrossfadeSeconds)
        } else {
            applyFadesInPlace(&out, fadeInSeconds: parameters.fadeInSeconds,
                              fadeOutSeconds: parameters.fadeOutSeconds)
        }
        return out
    }

    /// Materialises each layer's stretched block in memory, tiles it onto
    /// the output timeline and mixes the layers — the memory-for-speed
    /// driver behind ``render(_:parameters:seed:isCancelled:progress:)``.
    /// Returns `nil` when cancelled.
    private static func renderTiledFull(_ plan: RenderPlan,
                                        layers: [LayerPlan],
                                        layeredNormalize: Bool,
                                        isCancelled: () -> Bool,
                                        progress: ((Double) -> Void)?) -> StereoBuffer? {
        let totalFrames = plan.preLoopFrames
        var mixL = [Float](repeating: 0, count: totalFrames)
        var mixR = [Float](repeating: 0, count: totalFrames)
        let layerCount = layers.count

        for (i, layer) in layers.enumerated() {
            if isCancelled() { return nil }

            // Materialise this layer's block: a normalised stretch, or the
            // shaped source itself for passthrough layers.
            let stretched: StereoBuffer
            if let kernel = layer.kernel {
                let layerProgress: ((Double) -> Void)? = progress.map { report in
                    { frac in report((Double(i) + frac * 0.85) / Double(layerCount)) }
                }
                stretched = PaulStretcher.renderFull(kernel, sampleRate: plan.sampleRate,
                                                     isCancelled: isCancelled,
                                                     progress: layerProgress)
                if stretched.isEmpty { return nil }
            } else {
                stretched = plan.src
            }

            let provider: (Range<Int>, (UnsafePointer<Float>, UnsafePointer<Float>) -> Void) -> Void = { range, body in
                stretched.l.withUnsafeBufferPointer { sl in
                    stretched.r.withUnsafeBufferPointer { sr in
                        body(sl.baseAddress! + range.lowerBound, sr.baseAddress! + range.lowerBound)
                    }
                }
            }

            if layeredNormalize {
                var layerL = [Float](repeating: 0, count: totalFrames)
                var layerR = [Float](repeating: 0, count: totalFrames)
                layerL.withUnsafeMutableBufferPointer { llp in
                    layerR.withUnsafeMutableBufferPointer { lrp in
                        accumulateTiles(layer.tiles, sampleRate: plan.sampleRate,
                                        stretchedLength: layer.stretchedFrames,
                                        rangeStart: 0, rangeEnd: totalFrames,
                                        outL: llp.baseAddress!, outR: lrp.baseAddress!,
                                        provider: provider)
                    }
                }
                let gain = layer.gain
                for f in 0..<totalFrames { mixL[f] += layerL[f] * gain; mixR[f] += layerR[f] * gain }
            } else {
                mixL.withUnsafeMutableBufferPointer { mlp in
                    mixR.withUnsafeMutableBufferPointer { mrp in
                        accumulateTiles(layer.tiles, sampleRate: plan.sampleRate,
                                        stretchedLength: layer.stretchedFrames,
                                        rangeStart: 0, rangeEnd: totalFrames,
                                        outL: mlp.baseAddress!, outR: mrp.baseAddress!,
                                        provider: provider)
                    }
                }
            }
            progress?(Double(i + 1) / Double(layerCount))
        }

        if layeredNormalize {
            var peak: Float = 0
            for f in 0..<totalFrames {
                let a = abs(mixL[f]); let b = abs(mixR[f])
                if a > peak { peak = a }
                if b > peak { peak = b }
            }
            if peak > 0 {
                let g = 0.92 / peak
                for f in 0..<totalFrames { mixL[f] *= g; mixR[f] *= g }
            }
        }
        return StereoBuffer(l: mixL, r: mixR, sampleRate: plan.sampleRate)
    }
}
