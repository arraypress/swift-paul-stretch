//
//  AsyncRendering.swift
//  SwiftPaulStretch
//
//  async/await entry points: renders that honour Task cancellation, and a
//  pull-based AsyncSequence of chunks with natural backpressure.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

// MARK: - Task-cancellation bridging

/// Runs a cancellable render off the cooperative thread pool and bridges
/// Swift `Task` cancellation into the library's polling cancellation.
///
/// The work closure receives an `isCancelled` poll; cancelling the awaiting
/// `Task` flips it, the render stops at the next poll, and the call throws
/// `CancellationError`.
func runCancellableRender<T>(
    qos: DispatchQoS.QoSClass = .userInitiated,
    _ work: @escaping (_ isCancelled: @escaping () -> Bool) throws -> T
) async throws -> T {
    let token = CancelToken()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                do {
                    let result = try work { token.isCancelled }
                    if token.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: result)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    } onCancel: {
        token.cancel()
    }
}

// MARK: - Async renders

extension StretchRenderer {

    /// Renders the full pipeline into a single buffer, honouring `Task`
    /// cancellation.
    ///
    /// The heavy lifting runs on a global queue (never blocking the
    /// cooperative pool); cancelling the awaiting task stops the render at
    /// its next cancellation poll and throws `CancellationError`.
    ///
    /// ```swift
    /// let drone = try await StretchRenderer.render(source, parameters: params)
    /// ```
    ///
    /// - Parameters:
    ///   - source: The source audio.
    ///   - parameters: The render settings.
    ///   - seed: The render seed. Defaults to ``PaulStretcher/defaultSeed``.
    ///   - progress: Called with the completed fraction, `0…1`, from worker
    ///     threads.
    /// - Returns: The finished render (empty when the source was empty or
    ///   too short to freeze).
    /// - Throws: `CancellationError` when the task is cancelled.
    public static func render(_ source: StereoBuffer,
                              parameters: StretchParameters,
                              seed: UInt64 = PaulStretcher.defaultSeed,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> StereoBuffer {
        try await runCancellableRender { isCancelled in
            render(source, parameters: parameters, seed: seed,
                   isCancelled: isCancelled, progress: progress)
        }
    }

    /// Renders the full pipeline straight into an audio file, honouring
    /// `Task` cancellation.
    ///
    /// The async equivalent of
    /// ``renderToFile(_:parameters:url:format:chunkFrames:seed:isCancelled:progress:)``:
    /// on cancellation the partial file is deleted and `CancellationError`
    /// is thrown.
    ///
    /// ```swift
    /// try await StretchRenderer.renderToFile(source, parameters: params,
    ///                                        url: exportURL, format: .aac256)
    /// ```
    ///
    /// - Parameters:
    ///   - source: The source audio.
    ///   - parameters: The render settings.
    ///   - url: The destination file URL (overwritten if present).
    ///   - format: The on-disk format. Defaults to ``AudioFileFormat/wav24``.
    ///   - chunkFrames: Frames per streamed chunk. Defaults to
    ///     ``defaultChunkFrames``.
    ///   - seed: The render seed. Defaults to ``PaulStretcher/defaultSeed``.
    ///   - progress: Called with the completed fraction, `0…1`.
    /// - Throws: `CancellationError` when the task is cancelled;
    ///   ``AudioFileIOError`` or `AVAudioFile` errors on I/O failure.
    public static func renderToFile(_ source: StereoBuffer,
                                    parameters: StretchParameters,
                                    url: URL,
                                    format: AudioFileFormat = .wav24,
                                    chunkFrames: Int = defaultChunkFrames,
                                    seed: UInt64 = PaulStretcher.defaultSeed,
                                    progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let completed = try await runCancellableRender { isCancelled in
            try renderToFile(source, parameters: parameters, url: url, format: format,
                             chunkFrames: chunkFrames, seed: seed,
                             isCancelled: isCancelled, progress: progress)
        }
        if !completed { throw CancellationError() }
    }

    /// The render as an `AsyncSequence` of ordered chunks.
    ///
    /// Chunks are computed on demand as the consumer iterates (pull-based,
    /// so a slow consumer never piles up buffered audio), and the sequence
    /// honours `Task` cancellation. The concatenated chunks are bit-for-bit
    /// identical to ``render(_:parameters:seed:isCancelled:progress:)``.
    ///
    /// ```swift
    /// for try await chunk in StretchRenderer.renderChunkSequence(source, parameters: params) {
    ///     try writer.append(l: chunk.l, r: chunk.r)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - source: The source audio.
    ///   - parameters: The render settings.
    ///   - chunkFrames: Frames per chunk. Defaults to ``defaultChunkFrames``.
    ///   - seed: The render seed. Defaults to ``PaulStretcher/defaultSeed``.
    /// - Returns: The chunk sequence. Iterating performs the render.
    public static func renderChunkSequence(_ source: StereoBuffer,
                                           parameters: StretchParameters,
                                           chunkFrames: Int = defaultChunkFrames,
                                           seed: UInt64 = PaulStretcher.defaultSeed) -> RenderChunkSequence {
        RenderChunkSequence(source: source, parameters: parameters,
                            chunkFrames: chunkFrames, seed: seed)
    }
}

extension PaulStretcher {

    /// Stretches `input` by `ratio`, honouring `Task` cancellation — the
    /// async form of
    /// ``stretch(_:ratio:windowSeconds:phaseRandomness:pitchSemitones:onsetSensitivity:seed:isCancelled:progress:)``.
    ///
    /// - Throws: `CancellationError` when the task is cancelled.
    public static func stretch(_ input: StereoBuffer,
                               ratio: Double,
                               windowSeconds: Double = 0.25,
                               phaseRandomness: Double = 1.0,
                               pitchSemitones: Double = 0,
                               onsetSensitivity: Double = 0,
                               seed: UInt64 = defaultSeed,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> StereoBuffer {
        try await runCancellableRender { isCancelled in
            stretch(input, ratio: ratio, windowSeconds: windowSeconds,
                    phaseRandomness: phaseRandomness, pitchSemitones: pitchSemitones,
                    onsetSensitivity: onsetSensitivity, seed: seed,
                    isCancelled: isCancelled, progress: progress)
        }
    }
}

extension SpectralFreezer {

    /// Freezes `input` and resynthesises `targetSeconds` of audio, honouring
    /// `Task` cancellation — the async form of
    /// ``render(_:position:smear:scan:targetSeconds:windowSeconds:seed:isCancelled:progress:)``.
    ///
    /// - Throws: `CancellationError` when the task is cancelled.
    public static func render(_ input: StereoBuffer,
                              position: Double,
                              smear: Double,
                              scan: Double = 0,
                              targetSeconds: Double,
                              windowSeconds: Double = 0.25,
                              seed: UInt64 = PaulStretcher.defaultSeed,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> StereoBuffer {
        try await runCancellableRender { isCancelled in
            render(input, position: position, smear: smear, scan: scan,
                   targetSeconds: targetSeconds, windowSeconds: windowSeconds,
                   seed: seed, isCancelled: isCancelled, progress: progress)
        }
    }
}

// MARK: - Chunk sequence

/// An `AsyncSequence` of ``RenderChunk``s, produced on demand.
///
/// Created by
/// ``StretchRenderer/renderChunkSequence(_:parameters:chunkFrames:seed:)``.
/// The first `next()` runs the peak passes (so it takes the longest); each
/// later `next()` renders exactly one chunk. Work happens on a private
/// queue, never on the cooperative pool, and cancelling the iterating task
/// throws `CancellationError` out of `next()`.
public struct RenderChunkSequence: AsyncSequence {

    public typealias Element = RenderChunk

    let source: StereoBuffer
    let parameters: StretchParameters
    let chunkFrames: Int
    let seed: UInt64

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(source: source, parameters: parameters,
                      chunkFrames: chunkFrames, seed: seed)
    }

    /// The pull-based iterator driving a ``ChunkedRun`` cursor.
    ///
    /// `@unchecked Sendable`: `next()` may only be called from one task at a
    /// time (the `AsyncIteratorProtocol` contract); `run`/`prepared` are
    /// touched exclusively on the private queue and `finished` only between
    /// awaits on the iterating task.
    public final class AsyncIterator: AsyncIteratorProtocol, @unchecked Sendable {

        private let source: StereoBuffer
        private let parameters: StretchParameters
        private let chunkFrames: Int
        private let seed: UInt64
        private let queue = DispatchQueue(label: "PaulStretch.RenderChunkSequence", qos: .userInitiated)
        private let token = CancelToken()
        private var run: ChunkedRun?
        private var prepared = false
        private var finished = false

        init(source: StereoBuffer, parameters: StretchParameters, chunkFrames: Int, seed: UInt64) {
            self.source = source
            self.parameters = parameters
            self.chunkFrames = chunkFrames
            self.seed = seed
        }

        public func next() async throws -> RenderChunk? {
            if finished { return nil }
            let token = self.token
            let result: RenderChunk? = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async { [self] in
                        if token.isCancelled {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        if !prepared {
                            let plan = makeRenderPlan(source, parameters, seed: seed)
                            if case .empty = plan.path {
                                continuation.resume(returning: nil)
                                return
                            }
                            if plan.finalFrames <= 0 {
                                continuation.resume(returning: nil)
                                return
                            }
                            let newRun = ChunkedRun(plan: plan, progress: nil)
                            guard newRun.computeGains(isCancelled: { self.token.isCancelled }) else {
                                continuation.resume(throwing: CancellationError())
                                return
                            }
                            newRun.prepareDelivery(chunkFrames: chunkFrames)
                            run = newRun
                            prepared = true
                        }
                        guard let run else {
                            continuation.resume(returning: nil)
                            return
                        }
                        if let chunk = run.nextChunk(isCancelled: { self.token.isCancelled }) {
                            continuation.resume(returning: chunk)
                        } else if run.wasCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
            } onCancel: {
                token.cancel()
            }
            if result == nil { finished = true }
            return result
        }
    }
}
