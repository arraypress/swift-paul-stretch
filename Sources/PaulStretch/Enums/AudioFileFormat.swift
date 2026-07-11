//
//  AudioFileFormat.swift
//  SwiftPaulStretch
//
//  Every audio format Apple platforms can encode through AVAudioFile:
//  PCM (WAV/AIFF/CAF), AAC (CBR, VBR, HE), Apple Lossless, FLAC and Opus.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation

/// The on-disk formats ``StreamingAudioWriter`` (and the `renderToFile`
/// entry points) can produce — every encoder Apple platforms expose through
/// `AVAudioFile`.
///
/// Rough sizes for a 60-minute stereo render at 44.1 kHz:
///
/// | Format | Size | Notes |
/// | --- | --- | --- |
/// | `.wav(bitDepth: 24)` | ~950 MB | Uncompressed, universal, loop-safe |
/// | `.aiff(bitDepth: 24)` | ~950 MB | Uncompressed, big-endian sibling |
/// | `.caf(bitDepth: 32)` | ~1.3 GB | Float PCM; no 4 GB cap — best for huge intermediates |
/// | `.m4aALAC(bitDepth: 24)` | ~400–600 MB | Lossless, native Apple container |
/// | `.flac(bitDepth: 24)` | ~350–550 MB | Lossless, cross-platform |
/// | `.m4aAAC(bitRate: 256_000, …)` | ~115 MB | Lossy but transparent for ambient washes |
/// | `.m4aAACVBR(quality: .high)` | ~80–120 MB | Lossy, quality-targeted VBR |
/// | `.m4aHEAAC(bitRate: 64_000)` | ~29 MB | Very lossy; background-ambience grade |
/// | `.opusCAF(bitRate: 96_000)` | varies | 48 kHz streams **only** (Opus limitation) |
///
/// On iPhone, `.m4aAAC` around 192–256 kbps is usually the right export
/// choice — a PaulStretch wash is noise-like and encodes transparently.
/// Note that WAV/AIFF containers cap at 4 GB (~3.7 hours of 24-bit stereo);
/// use CAF, ALAC or FLAC beyond that.
///
/// > Important: the lossy MPEG-4 formats carry encoder priming/padding.
/// > Reading an `.m4a` back through `AVAudioFile` (or
/// > ``AudioFileIO/readStereo(url:sampleRate:)``) trims it automatically, so
/// > decode-then-loop stays seamless — but players that stream the file
/// > without honouring its gapless metadata may click at the loop seam. For
/// > files meant to loop directly, prefer PCM or a lossless format.
public enum AudioFileFormat: Sendable, Equatable {

    /// PCM WAV. `bitDepth` `16` or `24` (integer), or `32` (float).
    case wav(bitDepth: Int)

    /// PCM AIFF (big-endian integer). `bitDepth` `16` or `24`.
    case aiff(bitDepth: Int)

    /// PCM in a Core Audio Format container. `bitDepth` `16` or `24`
    /// (integer), or `32` (float). CAF has no 4 GB size cap, making it the
    /// safest choice for very long uncompressed renders.
    case caf(bitDepth: Int)

    /// AAC in an MPEG-4 container (`.m4a`), constant/long-term-average bit
    /// rate. Sensible rates for 44.1 kHz stereo run 128_000…320_000;
    /// `256_000` is transparent for most material. `quality` trades encoder
    /// effort for fidelity — use ``AVAudioQuality/max`` for offline exports.
    case m4aAAC(bitRate: Int, quality: AVAudioQuality)

    /// AAC in an MPEG-4 container (`.m4a`) with true variable bit rate: the
    /// encoder targets a quality level and spends bits where the audio needs
    /// them. Typically smaller than CBR at the same perceived quality.
    case m4aAACVBR(quality: AVAudioQuality)

    /// High-Efficiency AAC (`.m4a`) — very small files (a 60-minute render
    /// at 64 kbps is ~29 MB) at clearly reduced fidelity. Good enough for
    /// background ambience on a phone; not for critical listening.
    case m4aHEAAC(bitRate: Int)

    /// Apple Lossless in an MPEG-4 container (`.m4a`). `bitDepth` `16` or
    /// `24` (the hint the encoder quantises to).
    case m4aALAC(bitDepth: Int)

    /// FLAC (lossless, cross-platform). `bitDepth` `16` or `24`.
    case flac(bitDepth: Int)

    /// Opus in a Core Audio Format container.
    ///
    /// > Important: Opus only encodes 48 kHz-family streams — render (and
    /// > decode your source) at `sampleRate: 48_000` or file creation fails.
    /// > Bit-rate handling varies by OS encoder version.
    case opusCAF(bitRate: Int)

    // MARK: Conveniences

    /// 24-bit WAV — the library's default export format.
    public static let wav24 = AudioFileFormat.wav(bitDepth: 24)

    /// 256 kbps max-quality AAC — the recommended iPhone export format.
    public static let aac256 = AudioFileFormat.m4aAAC(bitRate: 256_000, quality: .max)

    /// 24-bit Apple Lossless.
    public static let alac = AudioFileFormat.m4aALAC(bitDepth: 24)

    // MARK: Properties

    /// The conventional file extension for the format.
    ///
    /// `AVAudioFile` infers the container from the destination URL's
    /// extension, so the URL you write to must use this (writing AAC
    /// settings to a `.wav` URL fails).
    public var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .caf, .opusCAF: return "caf"
        case .m4aAAC, .m4aAACVBR, .m4aHEAAC, .m4aALAC: return "m4a"
        case .flac: return "flac"
        }
    }

    /// `true` for the perceptually-coded formats (AAC family and Opus),
    /// `false` for PCM and the lossless codecs.
    public var isLossy: Bool {
        switch self {
        case .m4aAAC, .m4aAACVBR, .m4aHEAAC, .opusCAF: return true
        case .wav, .aiff, .caf, .m4aALAC, .flac: return false
        }
    }

    /// The `AVAudioFile` settings dictionary for this format.
    func settings(sampleRate: Double, channels: Int = 2) -> [String: Any] {
        func pcm(_ bitDepth: Int, bigEndian: Bool) -> [String: Any] {
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: bitDepth,
                AVLinearPCMIsFloatKey: bitDepth == 32,
                AVLinearPCMIsBigEndianKey: bigEndian,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
        switch self {
        case .wav(let bitDepth):
            return pcm(bitDepth, bigEndian: false)
        case .aiff(let bitDepth):
            return pcm(bitDepth, bigEndian: true)
        case .caf(let bitDepth):
            return pcm(bitDepth, bigEndian: false)
        case .m4aAAC(let bitRate, let quality):
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitRate,
                AVEncoderAudioQualityKey: quality.rawValue,
            ]
        case .m4aAACVBR(let quality):
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Variable,
                AVEncoderAudioQualityForVBRKey: quality.rawValue,
            ]
        case .m4aHEAAC(let bitRate):
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC_HE,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitRate,
            ]
        case .m4aALAC(let bitDepth):
            return [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitDepthHintKey: bitDepth,
            ]
        case .flac(let bitDepth):
            return [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitDepthHintKey: bitDepth,
            ]
        case .opusCAF(let bitRate):
            return [
                AVFormatIDKey: kAudioFormatOpus,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitRate,
            ]
        }
    }
}
