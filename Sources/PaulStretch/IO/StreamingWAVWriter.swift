//
//  StreamingWAVWriter.swift
//  SwiftPaulStretch
//
//  Incremental PCM WAV writing — the disk end of the chunked render path.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation

/// Writes stereo float chunks to a PCM WAV file incrementally.
///
/// Pair this with
/// ``StretchRenderer/renderChunks(_:parameters:chunkFrames:seed:isCancelled:progress:handler:)``
/// to export renders of any length with a memory footprint of one chunk —
/// or use the one-call convenience
/// ``StretchRenderer/renderToWAVFile(_:parameters:url:bitDepth:chunkFrames:seed:isCancelled:progress:)``.
///
/// ```swift
/// let writer = try StreamingWAVWriter(url: outURL, sampleRate: 44_100)
/// StretchRenderer.renderChunks(source, parameters: params) { chunk in
///     try writer.append(l: chunk.l, r: chunk.r)
/// }
/// writer.close()
/// ```
public final class StreamingWAVWriter {

    private var file: AVAudioFile?
    private let format: AVAudioFormat

    /// The number of frames written so far.
    public private(set) var framesWritten = 0

    /// Opens a WAV file for incremental writing (overwriting any existing
    /// file at `url`).
    ///
    /// - Parameters:
    ///   - url: The destination file URL.
    ///   - sampleRate: The file's sample rate, in hertz.
    ///   - bitDepth: PCM bit depth, `16` or `24`. Defaults to `24`.
    /// - Throws: `AVAudioFile` errors when the file cannot be created.
    public init(url: URL, sampleRate: Double, bitDepth: Int = 24) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let f = try AVAudioFile(forWriting: url, settings: settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = f
        self.format = f.processingFormat
    }

    /// Appends stereo samples to the file.
    ///
    /// Channels are written in lockstep; if the arrays differ in length the
    /// shorter one wins.
    ///
    /// - Parameters:
    ///   - l: Left-channel samples.
    ///   - r: Right-channel samples.
    /// - Throws: ``AudioFileIOError/writerClosed`` after ``close()``,
    ///   ``AudioFileIOError/cannotAllocateBuffer`` or `AVAudioFile` write
    ///   errors otherwise.
    public func append(l: [Float], r: [Float]) throws {
        guard let file else { throw AudioFileIOError.writerClosed }
        let total = min(l.count, r.count)
        guard total > 0 else { return }

        let chunk = 65536
        var pos = 0
        while pos < total {
            let n = min(chunk, total - pos)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else {
                throw AudioFileIOError.cannotAllocateBuffer
            }
            buf.frameLength = AVAudioFrameCount(n)
            let ch = buf.floatChannelData!
            for i in 0..<n { ch[0][i] = l[pos + i]; ch[1][i] = r[pos + i] }
            try file.write(from: buf)
            pos += n
        }
        framesWritten += total
    }

    /// Finalises the file. Further ``append(l:r:)`` calls throw. Called
    /// automatically when the writer is deallocated.
    public func close() {
        file = nil
    }
}
