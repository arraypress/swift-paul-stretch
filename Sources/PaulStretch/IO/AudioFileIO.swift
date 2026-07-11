//
//  AudioFileIO.swift
//  SwiftPaulStretch
//
//  File decode → stereo Float StereoBuffer, WAV export, and AVAudioPCMBuffer
//  bridging for playback engines.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation

/// Audio file reading and writing for ``StereoBuffer``s.
///
/// Reading decodes anything AVFoundation can open (WAV, AIFF, MP3, AAC, …)
/// and resamples to a uniform stereo float format so the DSP only ever sees
/// one shape of data. Writing produces PCM WAV. Both work identically on
/// macOS and iOS.
public enum AudioFileIO {

    /// The sample rate sources are decoded to by default, in hertz.
    public static let defaultSampleRate = 44_100.0

    /// Decodes an audio file into a stereo float buffer at `sampleRate`.
    ///
    /// Mono sources are duplicated to both channels; multi-channel sources
    /// are downmixed by the system converter.
    ///
    /// - Parameters:
    ///   - url: The audio file to read.
    ///   - sampleRate: The target sample rate. Defaults to
    ///     ``defaultSampleRate`` (44.1 kHz).
    /// - Returns: The decoded, resampled stereo buffer.
    /// - Throws: ``AudioFileIOError`` or `AVAudioFile` errors when the file
    ///   cannot be read or converted.
    public static func readStereo(url: URL, sampleRate: Double = defaultSampleRate) throws -> StereoBuffer {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let srcFrames = AVAudioFrameCount(file.length)

        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: max(1, srcFrames)) else {
            throw AudioFileIOError.cannotAllocateBuffer
        }
        try file.read(into: srcBuf)

        guard let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sampleRate,
                                            channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw AudioFileIOError.conversionFailed("no converter")
        }

        let ratio = sampleRate / srcFormat.sampleRate
        let dstCap = AVAudioFrameCount(Double(srcFrames) * ratio + 8192)
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: max(1, dstCap)) else {
            throw AudioFileIOError.cannotAllocateBuffer
        }

        var fed = false
        var convErr: NSError?
        converter.convert(to: dstBuf, error: &convErr) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return srcBuf
        }
        if let e = convErr { throw AudioFileIOError.conversionFailed(e.localizedDescription) }

        let n = Int(dstBuf.frameLength)
        guard let ch = dstBuf.floatChannelData else { throw AudioFileIOError.conversionFailed("no channel data") }
        let l = Array(UnsafeBufferPointer(start: ch[0], count: n))
        let r = dstBuf.format.channelCount > 1
            ? Array(UnsafeBufferPointer(start: ch[1], count: n)) : l
        return StereoBuffer(l: l, r: r, sampleRate: sampleRate)
    }

    /// Writes a stereo buffer to a PCM WAV file.
    ///
    /// - Parameters:
    ///   - buffer: The audio to write.
    ///   - url: The destination file URL (overwritten if present).
    ///   - bitDepth: PCM bit depth, `16` or `24`. Defaults to `24`.
    /// - Throws: ``AudioFileIOError`` or `AVAudioFile` errors on I/O failure.
    public static func writeWAV(_ buffer: StereoBuffer, to url: URL, bitDepth: Int = 24) throws {
        let writer = try StreamingWAVWriter(url: url, sampleRate: buffer.sampleRate, bitDepth: bitDepth)
        try writer.append(l: buffer.l, r: buffer.r)
        writer.close()
    }

    /// Builds a deinterleaved float `AVAudioPCMBuffer` from a stereo buffer,
    /// ready to schedule on an `AVAudioPlayerNode`.
    ///
    /// - Parameters:
    ///   - buffer: The audio to copy.
    ///   - format: The destination format (float32, 2 channels,
    ///     non-interleaved).
    /// - Returns: The PCM buffer, or `nil` if allocation fails or the format
    ///   has no float channel data.
    public static func makePCMBuffer(_ buffer: StereoBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(max(1, buffer.frameCount))) else { return nil }
        buf.frameLength = AVAudioFrameCount(buffer.frameCount)
        guard let ch = buf.floatChannelData else { return nil }
        let bytes = buffer.frameCount * MemoryLayout<Float>.size
        buffer.l.withUnsafeBufferPointer { _ = memcpy(ch[0], $0.baseAddress!, bytes) }
        buffer.r.withUnsafeBufferPointer { _ = memcpy(ch[1], $0.baseAddress!, bytes) }
        return buf
    }
}
