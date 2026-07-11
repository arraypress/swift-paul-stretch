//
//  AsyncEffectsRendering.swift
//  SwiftPaulStretch
//
//  async/await entry point for effected file exports, honouring Task
//  cancellation.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

extension StretchRenderer {

    /// Renders the full pipeline with effects baked in straight to an audio
    /// file, honouring `Task` cancellation.
    ///
    /// The async equivalent of
    /// ``renderToFile(_:parameters:effects:url:format:chunkFrames:seed:isCancelled:progress:)``:
    /// on cancellation the partial file is deleted and `CancellationError`
    /// is thrown.
    ///
    /// ```swift
    /// try await StretchRenderer.renderToFile(source, parameters: params,
    ///                                        effects: fx, url: exportURL,
    ///                                        format: .aac256)
    /// ```
    ///
    /// - Parameters:
    ///   - source: The source audio.
    ///   - parameters: The render settings.
    ///   - effects: The effect settings to bake into the file.
    ///   - url: The destination file URL (overwritten if present).
    ///   - format: The on-disk format. Defaults to ``AudioFileFormat/wav24``.
    ///   - chunkFrames: Frames per streamed chunk. Defaults to
    ///     ``StretchRenderer/defaultChunkFrames``.
    ///   - seed: The render seed. Defaults to ``PaulStretcher/defaultSeed``.
    ///   - progress: Called with the completed fraction, `0…1`.
    /// - Throws: `CancellationError` when the task is cancelled;
    ///   ``AudioFileIOError`` or `AVAudioFile` errors on setup/I/O failure.
    public static func renderToFile(_ source: StereoBuffer,
                                    parameters: StretchParameters,
                                    effects: EffectsParameters,
                                    url: URL,
                                    format: AudioFileFormat = .wav24,
                                    chunkFrames: Int = defaultChunkFrames,
                                    seed: UInt64 = PaulStretcher.defaultSeed,
                                    progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let token = CancelToken()
        let completed = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let done = try renderToFile(source, parameters: parameters,
                                                    effects: effects, url: url, format: format,
                                                    chunkFrames: chunkFrames, seed: seed,
                                                    isCancelled: { token.isCancelled },
                                                    progress: progress)
                        continuation.resume(returning: done && !token.isCancelled)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            token.cancel()
        }
        if !completed { throw CancellationError() }
    }
}

#endif  // !os(watchOS)
