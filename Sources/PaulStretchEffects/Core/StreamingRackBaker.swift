//
//  StreamingRackBaker.swift
//  SwiftPaulStretch
//
//  Chunk-wise offline baking for arbitrary AppleEffect racks — including
//  the time-stretching units, whose rate makes output frames ≠ input frames.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// Bakes an ``AppleEffect`` rack into a stream of chunks — the
/// memory-bounded companion to ``EffectRack/bake(_:effects:tailSeconds:)``.
///
/// Works for every unit type, including ``AppleEffect/timePitch(_:)`` and
/// ``AppleEffect/varispeed(_:)``: with a combined rate `r`, feeding `n` dry
/// frames yields about `n / r` wet frames, so ``process(l:r:)`` returns
/// whatever output has become safely available (possibly empty), and
/// ``finish()`` flushes the remainder plus any reverb/delay tail.
///
/// Like ``StreamingEffectsBaker``, the baker holds back a safety margin of
/// scheduled input so the player node's queue never drains mid-stream
/// (a drained node restarts one render quantum late, shifting the stream).
///
/// ```swift
/// let baker = StreamingRackBaker(sampleRate: 44_100,
///                                effects: [.varispeed(VarispeedSettings(rate: 0.5)),
///                                          .reverb(ReverbSettings())])!
/// StretchRenderer.renderChunks(source, parameters: params) { chunk in
///     let wet = baker.process(l: chunk.l, r: chunk.r)
///     try writer.append(l: wet.l, r: wet.r)
/// }
/// let flushed = baker.finish()
/// try writer.append(l: flushed.l, r: flushed.r)
/// ```
public final class StreamingRackBaker {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let rack: EffectRack
    private let format: AVAudioFormat
    private var outChunk: AVAudioPCMBuffer?
    private let passthrough: Bool
    private var finished = false
    private var playing = false

    /// Dry frames scheduled on the player so far.
    private var scheduledInput = 0
    /// Wet frames handed to the caller so far.
    private var pulledOutput = 0
    /// The most recent chunk's size (the double-buffer safety margin).
    private var lastChunkFrames = 0

    /// The combined rate of the rack's time units (`1` when none present).
    public let rateProduct: Double

    /// The tail ``finish()`` renders after the input drains, in seconds —
    /// ``EffectsBaker/tailSeconds`` when reverb or delay units are present.
    public let tailSeconds: Double

    /// Creates a streaming rack baker, or returns `nil` when the offline
    /// engine cannot be configured. An empty rack runs in passthrough mode.
    ///
    /// - Parameters:
    ///   - sampleRate: The stream's sample rate, in hertz.
    ///   - effects: The units to apply, in order.
    public init?(sampleRate: Double, effects: [AppleEffect]) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return nil }
        self.format = format
        self.passthrough = effects.isEmpty
        self.rack = EffectRack(effects: effects)
        self.rateProduct = EffectRack.rateProduct(of: effects)
        self.tailSeconds = effects.contains(where: { effect in
            if case .reverb = effect { return true }
            if case .delay = effect { return true }
            return false
        }) ? EffectsBaker.tailSeconds : 0
        guard !passthrough else { return }

        engine.attach(player)
        rack.install(in: engine, from: player, to: engine.mainMixerNode, format: format)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try engine.start()
        } catch {
            return nil
        }
        guard let oc = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else {
            engine.stop()
            return nil
        }
        self.outChunk = oc
    }

    deinit {
        if !passthrough { engine.stop() }
    }

    /// The wet frames a full stream of `inputFrames` will produce
    /// (including the tail) — for pre-sizing writers and progress UIs.
    public func expectedOutputFrames(forInput inputFrames: Int) -> Int {
        Int((Double(inputFrames) / rateProduct).rounded(.up)) + Int(tailSeconds * format.sampleRate)
    }

    /// Queues one dry chunk and returns whatever wet audio has become
    /// safely available (possibly empty — time units and the safety margin
    /// shift output later than input).
    ///
    /// Chunks must arrive in timeline order. After ``finish()``, or on an
    /// internal engine error, the dry input is returned unprocessed.
    ///
    /// - Parameters:
    ///   - l: Left-channel dry samples.
    ///   - r: Right-channel dry samples.
    /// - Returns: The wet audio ready so far.
    public func process(l: [Float], r: [Float]) -> (l: [Float], r: [Float]) {
        let n = min(l.count, r.count)
        if passthrough || finished || n == 0 { return (l: l, r: r) }
        guard let inBuf = AudioFileIO.makePCMBuffer(
            StereoBuffer(l: l, r: r, sampleRate: format.sampleRate), format: format) else { return (l: l, r: r) }
        player.scheduleBuffer(inBuf, at: nil, options: [], completionHandler: nil)
        if !playing { player.play(); playing = true }
        scheduledInput += n
        lastChunkFrames = n

        // Hold back at least the last chunk (and never less than 16k dry
        // frames — time units read ahead) so the queue can't starve.
        let safety = max(lastChunkFrames, 16_384)
        let safeInput = max(0, scheduledInput - safety)
        let targetOutput = Int(Double(safeInput) / rateProduct)
        let toPull = targetOutput - pulledOutput
        guard toPull > 0 else { return (l: [], r: []) }
        let out = renderFrames(toPull) ?? (l: [], r: [])
        pulledOutput += out.l.count
        return out
    }

    /// Flushes everything still inside the pipeline — the held-back input,
    /// the time-unit remainder and the reverb/delay tail — then stops the
    /// engine. Call exactly once, after the last ``process(l:r:)``.
    public func finish() -> (l: [Float], r: [Float]) {
        if passthrough || finished { return (l: [], r: []) }
        finished = true
        defer { engine.stop() }
        let total = Int((Double(scheduledInput) / rateProduct).rounded(.up))
            + Int(tailSeconds * format.sampleRate)
        let toPull = total - pulledOutput
        guard toPull > 0 else { return (l: [], r: []) }
        let out = renderFrames(toPull) ?? (l: [], r: [])
        pulledOutput += out.l.count
        return out
    }

    /// Pulls `count` frames out of the offline engine.
    private func renderFrames(_ count: Int) -> (l: [Float], r: [Float])? {
        guard let outChunk else { return nil }
        var outL = [Float](); outL.reserveCapacity(count)
        var outR = [Float](); outR.reserveCapacity(count)
        var rendered = 0
        while rendered < count {
            let frames = AVAudioFrameCount(min(4096, count - rendered))
            do {
                let status = try engine.renderOffline(frames, to: outChunk)
                guard status == .success else { return (outL, outR) }
            } catch { return (outL, outR) }
            let n = Int(outChunk.frameLength)
            if n == 0 { return (outL, outR) }
            if let ch = outChunk.floatChannelData {
                outL.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
                outR.append(contentsOf: UnsafeBufferPointer(start: ch[1], count: n))
            }
            rendered += n
        }
        return (outL, outR)
    }
}

extension StretchRenderer {

    /// Renders the full pipeline with an ``AppleEffect`` rack baked in,
    /// straight to an audio file, holding only a few chunks in memory.
    ///
    /// The rack equivalent of
    /// ``renderToFile(_:parameters:effects:url:format:chunkFrames:seed:isCancelled:progress:)``:
    /// any units in any order, including time units (the file's duration
    /// scales by `1 / rateProduct`). On cancellation the partial file is
    /// deleted.
    ///
    /// - Parameters:
    ///   - source: The source audio.
    ///   - parameters: The render settings.
    ///   - rack: The effect units to bake, in order.
    ///   - url: The destination file URL (overwritten if present).
    ///   - format: The on-disk format. Defaults to ``AudioFileFormat/wav24``.
    ///   - chunkFrames: Frames per streamed chunk. Defaults to
    ///     ``StretchRenderer/defaultChunkFrames``.
    ///   - seed: The render seed. Defaults to ``PaulStretcher/defaultSeed``.
    ///   - isCancelled: Polled periodically; return `true` to stop early.
    ///   - progress: Called with the completed fraction, `0…1`.
    /// - Returns: `true` when the file was written completely, `false` when
    ///   the render was cancelled (and the partial file removed).
    /// - Throws: ``AudioFileIOError`` when the rack engine cannot be set up,
    ///   or `AVAudioFile` errors on I/O failure.
    @discardableResult
    public static func renderToFile(_ source: StereoBuffer,
                                    parameters: StretchParameters,
                                    rack: [AppleEffect],
                                    url: URL,
                                    format: AudioFileFormat = .wav24,
                                    chunkFrames: Int = defaultChunkFrames,
                                    seed: UInt64 = PaulStretcher.defaultSeed,
                                    isCancelled: () -> Bool = { false },
                                    progress: ((Double) -> Void)? = nil) throws -> Bool {
        guard let baker = StreamingRackBaker(sampleRate: source.sampleRate, effects: rack) else {
            throw AudioFileIOError.conversionFailed("could not configure the offline rack engine")
        }
        let writer = try StreamingAudioWriter(url: url, sampleRate: source.sampleRate, format: format)
        let completed = try renderChunks(source, parameters: parameters,
                                         chunkFrames: chunkFrames, seed: seed,
                                         isCancelled: isCancelled, progress: progress) { chunk in
            let wet = baker.process(l: chunk.l, r: chunk.r)
            if !wet.l.isEmpty { try writer.append(l: wet.l, r: wet.r) }
        }
        if completed {
            let flushed = baker.finish()
            if !flushed.l.isEmpty { try writer.append(l: flushed.l, r: flushed.r) }
        }
        writer.close()
        if !completed {
            try? FileManager.default.removeItem(at: url)
        }
        return completed
    }
}

#endif  // !os(watchOS)
