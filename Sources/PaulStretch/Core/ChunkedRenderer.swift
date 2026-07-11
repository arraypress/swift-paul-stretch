//
//  ChunkedRenderer.swift
//  SwiftPaulStretch
//
//  Memory-bounded rendering: the same pipeline as StretchRenderer.render,
//  executed as ordered chunks so the whole output never has to exist in RAM.
//  Peak-scan passes stand in for the reference's in-place normalisation, so
//  the streamed audio is bit-identical to the in-memory render.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import Accelerate

extension StretchRenderer {

    /// The default chunk size for streaming renders (~5.9 s at 44.1 kHz,
    /// ~2 MB of stereo floats per chunk).
    public static let defaultChunkFrames = 262_144

    /// The exact frame count a render of `source` with `parameters` will
    /// produce, without rendering anything.
    ///
    /// Useful for pre-sizing progress UIs and file writers around a chunked
    /// render. Returns `0` when there is nothing to render (empty source, or
    /// a source too short to freeze).
    ///
    /// - Parameters:
    ///   - source: The source audio.
    ///   - parameters: The render settings.
    /// - Returns: The output length, in frames.
    public static func outputFrameCount(_ source: StereoBuffer,
                                        parameters p: StretchParameters) -> Int {
        let sr = source.sampleRate
        var srcFrames = source.frameCount
        if abs(p.tapeSpeed - 1) > 0.001 {
            srcFrames = max(1, Int((Double(srcFrames) / p.tapeSpeed).rounded(.up)))
        }
        guard srcFrames > 0 else { return 0 }
        let renderSeconds = p.seamlessLoop ? p.targetSeconds + loopCrossfadeSeconds : p.targetSeconds

        let preLoopFrames: Int
        if p.mode == .spectralFreeze {
            if srcFrames < 32 { return 0 }
            let windowSize = nextPow2(Int(p.windowSeconds * sr))
            preLoopFrames = max(windowSize, Int(renderSeconds * sr))
        } else {
            preLoopFrames = Int(renderSeconds * sr)
        }

        var loopCrossfadeFrames = 0
        if p.seamlessLoop, preLoopFrames > 0 {
            let xf = min(Int(loopCrossfadeSeconds * sr), preLoopFrames / 4)
            if xf >= 256 { loopCrossfadeFrames = xf }
        }
        return max(0, preLoopFrames - loopCrossfadeFrames)
    }

    /// Renders the full pipeline as ordered, memory-bounded chunks.
    ///
    /// The concatenated chunks are **bit-for-bit identical** to the buffer
    /// ``render(_:parameters:seed:isCancelled:progress:)`` returns; only the
    /// memory profile differs. Where the in-memory renderer normalises
    /// buffers in place, the chunked renderer first sweeps the timeline to
    /// measure the same peaks (rendering and discarding), then streams the
    /// final pass — trading roughly 2× the compute (3× for layered renders)
    /// for a peak footprint of a few chunks. On iOS that is the difference
    /// between a render that works and one the system jetsam-kills.
    ///
    /// - Parameters:
    ///   - source: The source audio.
    ///   - parameters: The render settings.
    ///   - chunkFrames: Frames per delivered chunk. Defaults to
    ///     ``defaultChunkFrames``.
    ///   - seed: The render seed. Defaults to ``PaulStretcher/defaultSeed``.
    ///   - isCancelled: Polled periodically; return `true` to stop early.
    ///   - progress: Called with the completed fraction, `0…1`, across all
    ///     passes.
    ///   - handler: Receives each ``RenderChunk`` in timeline order. Throwing
    ///     aborts the render and propagates the error.
    /// - Returns: `true` when the render ran to completion, `false` when it
    ///   was cancelled.
    @discardableResult
    public static func renderChunks(_ source: StereoBuffer,
                                    parameters: StretchParameters,
                                    chunkFrames: Int = defaultChunkFrames,
                                    seed: UInt64 = PaulStretcher.defaultSeed,
                                    isCancelled: () -> Bool = { false },
                                    progress: ((Double) -> Void)? = nil,
                                    handler: (RenderChunk) throws -> Void) rethrows -> Bool {
        let plan = makeRenderPlan(source, parameters, seed: seed)
        if case .empty = plan.path { progress?(1); return true }
        if plan.finalFrames <= 0 { progress?(1); return true }

        let run = ChunkedRun(plan: plan, progress: progress)
        guard run.computeGains(isCancelled: isCancelled) else { return false }
        return try run.deliver(chunkFrames: max(1024, chunkFrames),
                               isCancelled: isCancelled, handler: handler)
    }

    /// Renders the full pipeline straight into an audio file in any
    /// ``AudioFileFormat``, holding only a few chunks in memory at a time.
    ///
    /// This is the iOS-safe export path for long renders: a 60-minute file
    /// streams to disk with a peak footprint of a few megabytes instead of
    /// gigabytes, encoding on the fly for the compressed formats (a
    /// 60-minute render is ~950 MB as 24-bit WAV but ~115 MB as 256 kbps
    /// AAC — see ``AudioFileFormat``). On cancellation the partial file is
    /// deleted. The URL's extension must match the format's container
    /// (``AudioFileFormat/fileExtension``).
    ///
    /// - Parameters:
    ///   - source: The source audio.
    ///   - parameters: The render settings.
    ///   - url: The destination file URL (overwritten if present).
    ///   - format: The on-disk format. Defaults to ``AudioFileFormat/wav24``;
    ///     use ``AudioFileFormat/aac256`` for compact iPhone exports.
    ///   - chunkFrames: Frames per streamed chunk. Defaults to
    ///     ``defaultChunkFrames``.
    ///   - seed: The render seed. Defaults to ``PaulStretcher/defaultSeed``.
    ///   - isCancelled: Polled periodically; return `true` to stop early.
    ///   - progress: Called with the completed fraction, `0…1`.
    /// - Returns: `true` when the file was written completely, `false` when
    ///   the render was cancelled (and the partial file removed).
    /// - Throws: ``AudioFileIOError`` or `AVAudioFile` errors on I/O failure.
    @discardableResult
    public static func renderToFile(_ source: StereoBuffer,
                                    parameters: StretchParameters,
                                    url: URL,
                                    format: AudioFileFormat = .wav24,
                                    chunkFrames: Int = defaultChunkFrames,
                                    seed: UInt64 = PaulStretcher.defaultSeed,
                                    isCancelled: () -> Bool = { false },
                                    progress: ((Double) -> Void)? = nil) throws -> Bool {
        let writer = try StreamingAudioWriter(url: url, sampleRate: source.sampleRate, format: format)
        let completed = try renderChunks(source, parameters: parameters,
                                         chunkFrames: chunkFrames, seed: seed,
                                         isCancelled: isCancelled, progress: progress) { chunk in
            try writer.append(l: chunk.l, r: chunk.r)
        }
        writer.close()
        if !completed {
            try? FileManager.default.removeItem(at: url)
        }
        return completed
    }

    /// Renders the full pipeline straight into a PCM WAV file.
    ///
    /// A convenience for
    /// ``renderToFile(_:parameters:url:format:chunkFrames:seed:isCancelled:progress:)``
    /// with ``AudioFileFormat/wav(bitDepth:)``.
    ///
    /// - Parameters:
    ///   - source: The source audio.
    ///   - parameters: The render settings.
    ///   - url: The destination file URL (overwritten if present).
    ///   - bitDepth: PCM bit depth, `16` or `24`. Defaults to `24`.
    ///   - chunkFrames: Frames per streamed chunk. Defaults to
    ///     ``defaultChunkFrames``.
    ///   - seed: The render seed. Defaults to ``PaulStretcher/defaultSeed``.
    ///   - isCancelled: Polled periodically; return `true` to stop early.
    ///   - progress: Called with the completed fraction, `0…1`.
    /// - Returns: `true` when the file was written completely, `false` when
    ///   the render was cancelled (and the partial file removed).
    /// - Throws: ``AudioFileIOError`` or `AVAudioFile` errors on I/O failure.
    @discardableResult
    public static func renderToWAVFile(_ source: StereoBuffer,
                                       parameters: StretchParameters,
                                       url: URL,
                                       bitDepth: Int = 24,
                                       chunkFrames: Int = defaultChunkFrames,
                                       seed: UInt64 = PaulStretcher.defaultSeed,
                                       isCancelled: () -> Bool = { false },
                                       progress: ((Double) -> Void)? = nil) throws -> Bool {
        try renderToFile(source, parameters: parameters, url: url,
                         format: .wav(bitDepth: bitDepth), chunkFrames: chunkFrames,
                         seed: seed, isCancelled: isCancelled, progress: progress)
    }
}

// MARK: - Chunked execution

/// Executes a ``RenderPlan`` in memory-bounded passes:
///
/// 1. **Peak passes** — render each stretch layer (and the freeze) in sweeps,
///    tracking the absolute peak the in-memory renderer would have measured,
///    to recover the exact normalisation gains.
/// 2. **Mix-peak pass** (layered renders only) — sweep the mixed timeline for
///    the final 0.92 normalisation gain.
/// 3. **Delivery pass** — render the final timeline chunk by chunk: mix →
///    mix gain → stereo width → loop crossfade or fades → handler.
///
/// Every pass re-renders ranges through the same kernels and the same
/// accumulation loops as the in-memory driver, so all arithmetic — order
/// included — matches sample for sample.
private final class ChunkedRun {
    let plan: RenderPlan
    let progress: ((Double) -> Void)?

    /// Per-layer normalisation gain (`nil` = no scaling: passthrough layer
    /// or an all-silent stretch).
    var stretchGains: [Float?] = []
    var freezeGain: Float?
    var mixGain: Float?

    /// Sweep granularity for the peak passes (~12 s at 44.1 kHz).
    let sweepFrames = 1 << 19

    // Frame-based progress accounting across all passes.
    var unitsDone = 0.0
    var unitsTotal = 1.0

    init(plan: RenderPlan, progress: ((Double) -> Void)?) {
        self.plan = plan
        self.progress = progress

        var total = Double(plan.finalFrames)
        switch plan.path {
        case .tiled(let layers, let layeredNormalize):
            for layer in layers where layer.kernel != nil {
                total += Double(layer.stretchedFrames)
            }
            if layeredNormalize { total += Double(plan.preLoopFrames) }
            stretchGains = [Float?](repeating: nil, count: layers.count)
        case .freeze(let kernel):
            total += Double(kernel.outputLength)
        case .empty:
            break
        }
        unitsTotal = max(1, total)
    }

    private func addUnits(_ n: Int) {
        unitsDone += Double(n)
        progress?(min(1.0, unitsDone / unitsTotal))
    }

    // MARK: Peak passes

    /// Runs the peak passes. Returns `false` when cancelled.
    func computeGains(isCancelled: () -> Bool) -> Bool {
        switch plan.path {
        case .empty:
            return true

        case .freeze(let kernel):
            var peak: Float = 0
            var scratchL = [Float](repeating: 0, count: sweepFrames)
            var scratchR = [Float](repeating: 0, count: sweepFrames)
            var s = 0
            while s < kernel.outputLength {
                if isCancelled() { return false }
                let e = min(kernel.outputLength, s + sweepFrames)
                let n = e - s
                scratchL.withUnsafeMutableBufferPointer { lp in
                    scratchR.withUnsafeMutableBufferPointer { rp in
                        vDSP_vclr(lp.baseAddress!, 1, vDSP_Length(n))
                        vDSP_vclr(rp.baseAddress!, 1, vDSP_Length(n))
                        kernel.renderRangeParallel(s, e, outL: lp.baseAddress!, outR: rp.baseAddress!,
                                                   isCancelled: isCancelled, onBlocksDone: nil)
                        var pL: Float = 0, pR: Float = 0
                        vDSP_maxmgv(lp.baseAddress!, 1, &pL, vDSP_Length(n))
                        vDSP_maxmgv(rp.baseAddress!, 1, &pR, vDSP_Length(n))
                        peak = max(peak, max(pL, pR))
                    }
                }
                addUnits(n)
                s = e
            }
            if isCancelled() { return false }
            freezeGain = peak > 0 ? 0.92 / peak : nil
            return true

        case .tiled(let layers, let layeredNormalize):
            var scratchL = [Float](repeating: 0, count: sweepFrames)
            var scratchR = [Float](repeating: 0, count: sweepFrames)
            for (i, layer) in layers.enumerated() {
                guard let kernel = layer.kernel else { continue }
                var peak: Float = 0
                var s = 0
                while s < kernel.outputLength {
                    if isCancelled() { return false }
                    let e = min(kernel.outputLength, s + sweepFrames)
                    let n = e - s
                    scratchL.withUnsafeMutableBufferPointer { lp in
                        scratchR.withUnsafeMutableBufferPointer { rp in
                            vDSP_vclr(lp.baseAddress!, 1, vDSP_Length(n))
                            vDSP_vclr(rp.baseAddress!, 1, vDSP_Length(n))
                            kernel.renderRangeParallel(s, e, outL: lp.baseAddress!, outR: rp.baseAddress!,
                                                       isCancelled: isCancelled, onBlocksDone: nil)
                            var pL: Float = 0, pR: Float = 0
                            vDSP_maxmgv(lp.baseAddress!, 1, &pL, vDSP_Length(n))
                            vDSP_maxmgv(rp.baseAddress!, 1, &pR, vDSP_Length(n))
                            peak = max(peak, max(pL, pR))
                        }
                    }
                    addUnits(n)
                    s = e
                }
                if isCancelled() { return false }
                stretchGains[i] = peak > 0 ? 0.92 / peak : nil
            }

            if layeredNormalize {
                var peak: Float = 0
                var mixL = [Float](repeating: 0, count: sweepFrames)
                var mixR = [Float](repeating: 0, count: sweepFrames)
                var s = 0
                while s < plan.preLoopFrames {
                    if isCancelled() { return false }
                    let e = min(plan.preLoopFrames, s + sweepFrames)
                    let n = e - s
                    guard renderMixRange(s, e, mixL: &mixL, mixR: &mixR, isCancelled: isCancelled) else { return false }
                    for f in 0..<n {
                        let a = abs(mixL[f]); let b = abs(mixR[f])
                        if a > peak { peak = a }
                        if b > peak { peak = b }
                    }
                    addUnits(n)
                    s = e
                }
                mixGain = peak > 0 ? 0.92 / peak : nil
            }
            return true
        }
    }

    // MARK: Mix timeline

    /// Renders pre-loop timeline frames `[a, b)` into the front of
    /// `mixL`/`mixR`: tiles × layers with the recovered stretch gains
    /// applied, **before** the layered mix normalisation and stereo width.
    /// Returns `false` when cancelled.
    func renderMixRange(_ a: Int, _ b: Int,
                        mixL: inout [Float], mixR: inout [Float],
                        isCancelled: () -> Bool) -> Bool {
        let n = b - a
        var cancelled = false

        mixL.withUnsafeMutableBufferPointer { mlp in
        mixR.withUnsafeMutableBufferPointer { mrp in
            let outL = mlp.baseAddress!
            let outR = mrp.baseAddress!
            vDSP_vclr(outL, 1, vDSP_Length(n))
            vDSP_vclr(outR, 1, vDSP_Length(n))

            switch plan.path {
            case .empty:
                return

            case .freeze(let kernel):
                kernel.renderRangeParallel(a, b, outL: outL, outR: outR,
                                           isCancelled: isCancelled, onBlocksDone: nil)
                if isCancelled() { cancelled = true; return }
                if let g = freezeGain {
                    var gg = g
                    vDSP_vsmul(outL, 1, &gg, outL, 1, vDSP_Length(n))
                    vDSP_vsmul(outR, 1, &gg, outR, 1, vDSP_Length(n))
                }

            case .tiled(let layers, let layeredNormalize):
                var layerL = layeredNormalize ? [Float](repeating: 0, count: n) : []
                var layerR = layeredNormalize ? [Float](repeating: 0, count: n) : []
                var stretchL = [Float](repeating: 0, count: n)
                var stretchR = [Float](repeating: 0, count: n)

                for (i, layer) in layers.enumerated() {
                    if isCancelled() { cancelled = true; return }

                    func accumulate(_ tL: UnsafeMutablePointer<Float>, _ tR: UnsafeMutablePointer<Float>) {
                        accumulateTiles(layer.tiles, sampleRate: self.plan.sampleRate,
                                        stretchedLength: layer.stretchedFrames,
                                        rangeStart: a, rangeEnd: b,
                                        outL: tL, outR: tR) { range, body in
                            if let kernel = layer.kernel {
                                // Re-render just the stretched frames these
                                // tiles need, then apply the layer's exact
                                // normalisation gain.
                                stretchL.withUnsafeMutableBufferPointer { slp in
                                    stretchR.withUnsafeMutableBufferPointer { srp in
                                        let sL = slp.baseAddress!
                                        let sR = srp.baseAddress!
                                        let cnt = range.count
                                        vDSP_vclr(sL, 1, vDSP_Length(cnt))
                                        vDSP_vclr(sR, 1, vDSP_Length(cnt))
                                        kernel.renderRangeParallel(range.lowerBound, range.upperBound,
                                                                   outL: sL, outR: sR,
                                                                   isCancelled: isCancelled, onBlocksDone: nil)
                                        if let g = self.stretchGains[i] {
                                            var gg = g
                                            vDSP_vsmul(sL, 1, &gg, sL, 1, vDSP_Length(cnt))
                                            vDSP_vsmul(sR, 1, &gg, sR, 1, vDSP_Length(cnt))
                                        }
                                        body(sL, sR)
                                    }
                                }
                            } else {
                                // Passthrough layer: tiles read the shaped
                                // source directly (never normalised).
                                self.plan.src.l.withUnsafeBufferPointer { sl in
                                    self.plan.src.r.withUnsafeBufferPointer { sr in
                                        body(sl.baseAddress! + range.lowerBound,
                                             sr.baseAddress! + range.lowerBound)
                                    }
                                }
                            }
                        }
                    }

                    if layeredNormalize {
                        layerL.withUnsafeMutableBufferPointer { llp in
                            layerR.withUnsafeMutableBufferPointer { lrp in
                                let tL = llp.baseAddress!
                                let tR = lrp.baseAddress!
                                vDSP_vclr(tL, 1, vDSP_Length(n))
                                vDSP_vclr(tR, 1, vDSP_Length(n))
                                accumulate(tL, tR)
                                let gain = layer.gain
                                for f in 0..<n { outL[f] += tL[f] * gain; outR[f] += tR[f] * gain }
                            }
                        }
                    } else {
                        accumulate(outL, outR)
                    }
                }
                if isCancelled() { cancelled = true }
            }
        }}
        return !cancelled
    }

    // MARK: Delivery pass

    /// Streams the final timeline to `handler` chunk by chunk, applying the
    /// mix gain, stereo width and the loop crossfade or fade envelopes.
    func deliver(chunkFrames: Int,
                 isCancelled: () -> Bool,
                 handler: (RenderChunk) throws -> Void) rethrows -> Bool {
        let total = plan.finalFrames
        let p = plan.params
        let sr = plan.sampleRate
        let xf = plan.loopCrossfadeFrames
        let width = p.stereoWidth
        let applyWidth = abs(width - 1) >= 0.001
        let w = Float(width)

        // Fade geometry (one-shot renders only), from the final length —
        // exactly how the in-memory path derives it.
        var fadeIn = 0, fadeOut = 0
        if !p.seamlessLoop {
            let (efi, efo) = effectiveFades(p.fadeInSeconds, p.fadeOutSeconds, Double(total) / sr)
            fadeIn = max(0, min(total, Int(efi * sr)))
            fadeOut = max(0, min(total - fadeIn, Int(efo * sr)))
        }

        var mixL = [Float](repeating: 0, count: chunkFrames)
        var mixR = [Float](repeating: 0, count: chunkFrames)
        var tailL = [Float](repeating: 0, count: chunkFrames)
        var tailR = [Float](repeating: 0, count: chunkFrames)

        var a = 0
        while a < total {
            if isCancelled() { return false }
            let b = min(total, a + chunkFrames)
            let n = b - a

            guard renderMixRange(a, b, mixL: &mixL, mixR: &mixR, isCancelled: isCancelled) else { return false }
            if let g = mixGain {
                for f in 0..<n { mixL[f] *= g; mixR[f] *= g }
            }
            if applyWidth {
                for f in 0..<n {
                    let mid = (mixL[f] + mixR[f]) * 0.5
                    let side = (mixL[f] - mixR[f]) * 0.5 * w
                    mixL[f] = mid + side
                    mixR[f] = mid - side
                }
            }

            if xf > 0 && a < xf {
                // Loop head: crossfade in the matching tail of the pre-loop
                // timeline (rendered through the identical pipeline).
                let headEnd = min(b, xf)
                let tailStart = total + a
                let tailEnd = total + headEnd
                guard renderMixRange(tailStart, tailEnd, mixL: &tailL, mixR: &tailR, isCancelled: isCancelled) else { return false }
                let tn = tailEnd - tailStart
                if let g = mixGain {
                    for f in 0..<tn { tailL[f] *= g; tailR[f] *= g }
                }
                if applyWidth {
                    for f in 0..<tn {
                        let mid = (tailL[f] + tailR[f]) * 0.5
                        let side = (tailL[f] - tailR[f]) * 0.5 * w
                        tailL[f] = mid + side
                        tailR[f] = mid - side
                    }
                }
                for i in a..<headEnd {
                    let k = Float(i) / Float(xf)
                    let fin = k.squareRoot(); let fout = (1 - k).squareRoot()
                    mixL[i - a] = mixL[i - a] * fin + tailL[i - a] * fout
                    mixR[i - a] = mixR[i - a] * fin + tailR[i - a] * fout
                }
            } else if !p.seamlessLoop {
                if fadeIn > 0 && a < fadeIn {
                    for j in a..<min(b, fadeIn) {
                        let g = Float(j) / Float(fadeIn)
                        mixL[j - a] *= g; mixR[j - a] *= g
                    }
                }
                if fadeOut > 0 && b > total - fadeOut {
                    for j in max(a, total - fadeOut)..<b {
                        let g = Float(total - 1 - j) / Float(fadeOut)
                        mixL[j - a] *= g; mixR[j - a] *= g
                    }
                }
            }

            let chunk = RenderChunk(startFrame: a,
                                    totalFrames: total,
                                    l: Array(mixL[0..<n]),
                                    r: Array(mixR[0..<n]),
                                    sampleRate: sr)
            try handler(chunk)
            addUnits(n)
            a = b
        }
        progress?(1)
        return true
    }
}
