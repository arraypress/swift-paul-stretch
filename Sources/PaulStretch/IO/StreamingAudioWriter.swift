//
//  StreamingAudioWriter.swift
//  SwiftPaulStretch
//
//  Incremental audio-file writing in any encodable format (PCM, AAC, ALAC,
//  FLAC, Opus) — the disk end of the chunked render path.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation

/// Writes stereo float chunks to an audio file incrementally, in any
/// ``AudioFileFormat``. Compressed formats are encoded on the fly, so even
/// an hour of AAC never holds more than one chunk of PCM in memory.
///
/// Pair this with
/// ``StretchRenderer/renderChunks(_:parameters:chunkFrames:seed:isCancelled:progress:handler:)``
/// to export renders of any length with a memory footprint of one chunk —
/// or use the one-call convenience
/// ``StretchRenderer/renderToFile(_:parameters:url:format:chunkFrames:seed:isCancelled:progress:)``.
///
/// ```swift
/// let writer = try StreamingAudioWriter(url: outURL, sampleRate: 44_100,
///                                       format: .aac256)
/// StretchRenderer.renderChunks(source, parameters: params) { chunk in
///     try writer.append(l: chunk.l, r: chunk.r)
/// }
/// writer.close()
/// ```
public final class StreamingAudioWriter {

    private var file: AVAudioFile?
    private let format: AVAudioFormat
    /// Reused per-append staging buffer — allocating a fresh
    /// `AVAudioPCMBuffer` per chunk was measurable churn on the render
    /// path; `frameLength` is set per call instead.
    private let scratch: AVAudioPCMBuffer
    private static let scratchCapacity = 65536

    /// The on-disk format being written.
    public let fileFormat: AudioFileFormat

    /// The number of (PCM) frames appended so far.
    public private(set) var framesWritten = 0

    /// Opens an audio file for incremental writing (overwriting any existing
    /// file at `url`).
    ///
    /// The URL's file extension must match the format's container (see
    /// ``AudioFileFormat/fileExtension``) — `AVAudioFile` infers the
    /// container from it, so writing AAC settings to a `.wav` URL fails.
    ///
    /// - Parameters:
    ///   - url: The destination file URL.
    ///   - sampleRate: The stream's sample rate, in hertz. Note that
    ///     ``AudioFileFormat/opusCAF(bitRate:)`` requires 48 kHz.
    ///   - format: The on-disk format. Defaults to ``AudioFileFormat/wav24``.
    /// - Throws: `AVAudioFile` errors when the file cannot be created (an
    ///   extension/container mismatch or an unsupported sample rate for the
    ///   codec are the usual causes).
    public init(url: URL, sampleRate: Double, format fileFormat: AudioFileFormat = .wav24) throws {
        self.fileFormat = fileFormat
        let f = try AVAudioFile(forWriting: url,
                                settings: fileFormat.settings(sampleRate: sampleRate),
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = f
        self.format = f.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat,
                                         frameCapacity: AVAudioFrameCount(Self.scratchCapacity)) else {
            throw AudioFileIOError.cannotAllocateBuffer
        }
        self.scratch = buf
    }

    /// Appends stereo samples to the file, encoding as it goes.
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

        var pos = 0
        while pos < total {
            let n = min(Self.scratchCapacity, total - pos)
            scratch.frameLength = AVAudioFrameCount(n)
            let ch = scratch.floatChannelData!
            l.withUnsafeBufferPointer { lp in
                r.withUnsafeBufferPointer { rp in
                    memcpy(ch[0], lp.baseAddress! + pos, n * MemoryLayout<Float>.size)
                    memcpy(ch[1], rp.baseAddress! + pos, n * MemoryLayout<Float>.size)
                }
            }
            try file.write(from: scratch)
            pos += n
        }
        framesWritten += total
    }

    /// Finalises the file (flushing any encoder tail). Further
    /// ``append(l:r:)`` calls throw. Called automatically when the writer is
    /// deallocated.
    public func close() {
        file = nil
    }
}

/// The historical name of ``StreamingAudioWriter``, kept as an alias so
/// early adopters of the WAV-only writer keep compiling.
public typealias StreamingWAVWriter = StreamingAudioWriter
