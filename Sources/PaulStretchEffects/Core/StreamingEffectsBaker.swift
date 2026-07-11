//
//  StreamingEffectsBaker.swift
//  SwiftPaulStretch
//
//  Chunk-wise offline effect baking, so effected exports can stream to disk
//  with the same bounded memory as the chunked renderer.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// Bakes the effect chain into a stream of chunks — the memory-bounded
/// companion to ``EffectsBaker/bake(_:effects:)``.
///
/// Feed render chunks through ``process(l:r:)`` in order, then call
/// ``finish()`` once to flush the pipeline and collect the reverb/delay
/// tail. The engine's state carries across chunks, so the concatenated
/// output matches a whole-buffer bake of the concatenated input.
///
/// The baker runs **one chunk behind**: each `process` call returns the
/// previous chunk's wet audio (the first returns nothing) so the player
/// node's queue never drains mid-stream — a drained node restarts one
/// render quantum late, which would shift the whole stream. `finish()`
/// returns the final chunk plus the tail; total output frames always equal
/// total input frames plus the tail.
///
/// ```swift
/// let baker = StreamingEffectsBaker(sampleRate: 44_100, effects: fx)!
/// StretchRenderer.renderChunks(source, parameters: params) { chunk in
///     let wet = baker.process(l: chunk.l, r: chunk.r)
///     try writer.append(l: wet.l, r: wet.r)
/// }
/// let flushed = baker.finish()
/// try writer.append(l: flushed.l, r: flushed.r)
/// ```
public final class StreamingEffectsBaker {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let chain = EffectChain()
    private let format: AVAudioFormat
    private var outChunk: AVAudioPCMBuffer?
    private let passthrough: Bool
    private var finished = false
    /// The player starts only after the first buffer is queued — starting it
    /// earlier makes the node render silence until the next quantum and
    /// time-shifts the whole stream.
    private var playing = false
    /// Frames scheduled on the player but not yet pulled out of the engine.
    /// Always left ≥ one chunk between calls so the queue never drains.
    private var pendingFrames = 0

    /// The tail ``finish()`` will render, in seconds — ``EffectsBaker/tailSeconds``
    /// when reverb or delay is active, otherwise `0`.
    public let tailSeconds: Double

    /// Creates a streaming baker, or returns `nil` when the offline engine
    /// cannot be configured.
    ///
    /// With no effects enabled the baker runs in passthrough mode: chunks
    /// come back untouched and the tail is empty.
    ///
    /// - Parameters:
    ///   - sampleRate: The stream's sample rate, in hertz.
    ///   - effects: The effect settings to bake.
    public init?(sampleRate: Double, effects: EffectsParameters) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return nil }
        self.format = format
        self.passthrough = !effects.isAnyEnabled
        self.tailSeconds = (effects.reverbEnabled || effects.delayEnabled) ? EffectsBaker.tailSeconds : 0
        guard !passthrough else { return }

        engine.attach(player)
        chain.install(in: engine, from: player, to: engine.mainMixerNode, format: format)
        chain.apply(effects)
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

    /// Queues one dry chunk and returns the previous chunk's wet audio.
    ///
    /// Chunks must be fed in timeline order; effect state (delay lines,
    /// reverb tails) flows from one chunk into the next. The baker keeps one
    /// chunk of latency (see the type docs), so the first call returns
    /// nothing and each later call returns the frames of the call before it.
    /// If the arrays differ in length the shorter one wins. After
    /// ``finish()``, or on an internal engine error, the dry input is
    /// returned unprocessed.
    ///
    /// - Parameters:
    ///   - l: Left-channel dry samples.
    ///   - r: Right-channel dry samples.
    /// - Returns: The wet audio ready so far (possibly empty).
    public func process(l: [Float], r: [Float]) -> (l: [Float], r: [Float]) {
        let n = min(l.count, r.count)
        if passthrough || finished || n == 0 { return (l, r) }
        guard let inBuf = AudioFileIO.makePCMBuffer(
            StereoBuffer(l: l, r: r, sampleRate: format.sampleRate), format: format) else { return (l, r) }
        player.scheduleBuffer(inBuf, at: nil, options: [], completionHandler: nil)
        if !playing { player.play(); playing = true }

        // Pull everything scheduled before this chunk; leave this chunk
        // queued so the player never starves between calls.
        let toRender = pendingFrames
        pendingFrames = n
        guard toRender > 0 else { return ([], []) }
        return renderFrames(toRender) ?? ([], [])
    }

    /// Flushes the last queued chunk, renders the reverb/delay decay tail
    /// and stops the engine. Call exactly once, after the last
    /// ``process(l:r:)``.
    ///
    /// - Returns: The remaining wet audio plus the tail (empty in
    ///   passthrough mode).
    public func finish() -> (l: [Float], r: [Float]) {
        if passthrough || finished { return ([], []) }
        finished = true
        defer { engine.stop() }
        let tailFrames = Int(tailSeconds * format.sampleRate)
        let toRender = pendingFrames + tailFrames
        pendingFrames = 0
        guard toRender > 0 else { return ([], []) }
        return renderFrames(toRender) ?? ([], [])
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
                guard status == .success else { return nil }
            } catch { return nil }
            let n = Int(outChunk.frameLength)
            if n == 0 { return nil }
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

    /// Renders the full pipeline **with effects baked in** straight to an
    /// audio file in any ``AudioFileFormat``, holding only a few chunks in
    /// memory at a time.
    ///
    /// The effected equivalent of
    /// ``StretchRenderer/renderToFile(_:parameters:url:format:chunkFrames:seed:isCancelled:progress:)``:
    /// each rendered chunk is run through a ``StreamingEffectsBaker`` before
    /// hitting disk, and the reverb/delay tail is appended at the end. On
    /// cancellation the partial file is deleted.
    ///
    /// - Parameters:
    ///   - source: The source audio.
    ///   - parameters: The render settings.
    ///   - effects: The effect settings to bake into the file.
    ///   - url: The destination file URL (overwritten if present). Its
    ///     extension must match the format's container
    ///     (``AudioFileFormat/fileExtension``).
    ///   - format: The on-disk format. Defaults to ``AudioFileFormat/wav24``;
    ///     use ``AudioFileFormat/aac256`` for compact iPhone exports.
    ///   - chunkFrames: Frames per streamed chunk. Defaults to
    ///     ``StretchRenderer/defaultChunkFrames``.
    ///   - seed: The render seed. Defaults to ``PaulStretcher/defaultSeed``.
    ///   - isCancelled: Polled periodically; return `true` to stop early.
    ///   - progress: Called with the completed fraction, `0…1`.
    /// - Returns: `true` when the file was written completely, `false` when
    ///   the render was cancelled (and the partial file removed).
    /// - Throws: ``AudioFileIOError`` when the effects engine cannot be set
    ///   up, or `AVAudioFile` errors on I/O failure.
    @discardableResult
    public static func renderToFile(_ source: StereoBuffer,
                                    parameters: StretchParameters,
                                    effects: EffectsParameters,
                                    url: URL,
                                    format: AudioFileFormat = .wav24,
                                    chunkFrames: Int = defaultChunkFrames,
                                    seed: UInt64 = PaulStretcher.defaultSeed,
                                    isCancelled: () -> Bool = { false },
                                    progress: ((Double) -> Void)? = nil) throws -> Bool {
        guard let baker = StreamingEffectsBaker(sampleRate: source.sampleRate, effects: effects) else {
            throw AudioFileIOError.conversionFailed("could not configure the offline effects engine")
        }
        let writer = try StreamingAudioWriter(url: url, sampleRate: source.sampleRate, format: format)
        let completed = try renderChunks(source, parameters: parameters,
                                         chunkFrames: chunkFrames, seed: seed,
                                         isCancelled: isCancelled, progress: progress) { chunk in
            let wet = baker.process(l: chunk.l, r: chunk.r)
            try writer.append(l: wet.l, r: wet.r)
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

    /// Renders the full pipeline with effects baked in straight to a PCM
    /// WAV file — a convenience for
    /// ``renderToFile(_:parameters:effects:url:format:chunkFrames:seed:isCancelled:progress:)``
    /// with ``AudioFileFormat/wav(bitDepth:)``.
    ///
    /// - Parameters:
    ///   - source: The source audio.
    ///   - parameters: The render settings.
    ///   - effects: The effect settings to bake into the file.
    ///   - url: The destination file URL (overwritten if present).
    ///   - bitDepth: PCM bit depth, `16` or `24`. Defaults to `24`.
    ///   - chunkFrames: Frames per streamed chunk. Defaults to
    ///     ``StretchRenderer/defaultChunkFrames``.
    ///   - seed: The render seed. Defaults to ``PaulStretcher/defaultSeed``.
    ///   - isCancelled: Polled periodically; return `true` to stop early.
    ///   - progress: Called with the completed fraction, `0…1`.
    /// - Returns: `true` when the file was written completely, `false` when
    ///   the render was cancelled (and the partial file removed).
    /// - Throws: ``AudioFileIOError`` when the effects engine cannot be set
    ///   up, or `AVAudioFile` errors on I/O failure.
    @discardableResult
    public static func renderToWAVFile(_ source: StereoBuffer,
                                       parameters: StretchParameters,
                                       effects: EffectsParameters,
                                       url: URL,
                                       bitDepth: Int = 24,
                                       chunkFrames: Int = defaultChunkFrames,
                                       seed: UInt64 = PaulStretcher.defaultSeed,
                                       isCancelled: () -> Bool = { false },
                                       progress: ((Double) -> Void)? = nil) throws -> Bool {
        try renderToFile(source, parameters: parameters, effects: effects, url: url,
                         format: .wav(bitDepth: bitDepth), chunkFrames: chunkFrames,
                         seed: seed, isCancelled: isCancelled, progress: progress)
    }
}

#endif  // !os(watchOS)
