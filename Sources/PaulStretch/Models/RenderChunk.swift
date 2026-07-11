//
//  RenderChunk.swift
//  SwiftPaulStretch
//
//  One slice of a chunked render, delivered in order to a handler.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// A contiguous slice of a chunked render.
///
/// ``StretchRenderer/renderChunks(_:parameters:chunkFrames:seed:isCancelled:progress:handler:)``
/// delivers these in order, from frame `0` to the end of the render. The
/// concatenation of all chunks is bit-for-bit identical to the buffer the
/// one-shot ``StretchRenderer/render(_:parameters:seed:isCancelled:progress:)``
/// would have produced — chunking changes the memory profile, never the audio.
///
/// ```swift
/// StretchRenderer.renderChunks(source, parameters: params) { chunk in
///     try writer.append(l: chunk.l, r: chunk.r)   // peak RAM: one chunk
/// }
/// ```
public struct RenderChunk: Sendable {

    /// The absolute frame index of the first sample in this chunk.
    public let startFrame: Int

    /// The total frame count of the whole render this chunk belongs to.
    public let totalFrames: Int

    /// Left-channel samples for this chunk.
    public let l: [Float]

    /// Right-channel samples for this chunk.
    public let r: [Float]

    /// The sample rate of the render, in hertz.
    public let sampleRate: Double

    /// The number of frames in this chunk.
    public var frameCount: Int { l.count }

    /// `true` when this is the final chunk of the render.
    public var isLast: Bool { startFrame + frameCount >= totalFrames }

    /// Creates a chunk.
    ///
    /// - Parameters:
    ///   - startFrame: The absolute frame index of the first sample.
    ///   - totalFrames: The total frame count of the whole render.
    ///   - l: Left-channel samples.
    ///   - r: Right-channel samples.
    ///   - sampleRate: The sample rate, in hertz.
    public init(startFrame: Int, totalFrames: Int, l: [Float], r: [Float], sampleRate: Double) {
        self.startFrame = startFrame
        self.totalFrames = totalFrames
        self.l = l
        self.r = r
        self.sampleRate = sampleRate
    }
}
