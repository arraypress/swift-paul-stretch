//
//  TrackSource.swift
//  SwiftPaulStretch
//
//  What a track plays: a sample loop, or a generative engine rendering from
//  a seed sample. Audio travels embedded (bytes inside the session) or by
//  file reference.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretch

// This product builds on PaulStretchEffects, which compiles to an empty
// module on watchOS.
#if !os(watchOS)

/// What a ``Track`` plays.
public enum TrackSource: Sendable, Codable, Equatable {
    /// An audio file played as-is (usually looped) — field recordings,
    /// texture WAVs, bounced stems.
    case sample(SampleSource)
    /// A stretch engine rendering a voice from a seed sample — the
    /// generative half of the studio. Same source + parameters + seed
    /// always renders the identical voice.
    case generative(GenerativeSource)

    /// The underlying audio reference (embedded bytes or file path).
    public var audio: AudioReference {
        switch self {
        case .sample(let s): return s.audio
        case .generative(let g): return g.audio
        }
    }
}

/// A reference to source audio: embedded bytes (the session file is
/// self-contained) or a path the host resolves.
public struct AudioReference: Sendable, Codable, Equatable {

    /// Encoded audio bytes (WAV/AIFF/M4A/MP3…), when embedded.
    public var data: Data? = nil

    /// An absolute file path, when referenced externally. Ignored while
    /// `data` is set.
    public var path: String? = nil

    /// A display name for the audio.
    public var name: String = ""

    /// Creates an embedded reference.
    ///
    /// - Parameters:
    ///   - data: The encoded audio bytes.
    ///   - name: A display name.
    public init(data: Data, name: String = "") {
        self.data = data
        self.name = name
    }

    /// Creates an external file reference.
    ///
    /// - Parameters:
    ///   - path: The absolute file path.
    ///   - name: A display name (defaults to the file name).
    public init(path: String, name: String? = nil) {
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
    }

    /// Decodes the referenced audio at a sample rate.
    ///
    /// - Parameter sampleRate: The rate to decode/resample to, in hertz.
    /// - Returns: The audio, or `nil` when the bytes/file don't resolve.
    public func resolve(sampleRate: Double) -> StereoBuffer? {
        if let data {
            return AudioFileIO.decodeStereo(data, sampleRate: sampleRate)
        }
        if let path {
            return try? AudioFileIO.readStereo(url: URL(fileURLWithPath: path),
                                               sampleRate: sampleRate)
        }
        return nil
    }
}

/// A sample voice: the referenced audio, optionally loop-crossfaded.
public struct SampleSource: Sendable, Codable, Equatable {

    /// The audio.
    public var audio: AudioReference

    /// Crossfades the tail into the head on resolve so the loop seam is
    /// inaudible. Defaults to `true`.
    public var seamlessLoop: Bool = true

    /// Creates a sample source.
    ///
    /// - Parameters:
    ///   - audio: The audio reference.
    ///   - seamlessLoop: Whether to crossfade the loop seam.
    public init(audio: AudioReference, seamlessLoop: Bool = true) {
        self.audio = audio
        self.seamlessLoop = seamlessLoop
    }
}

/// A generative voice: a stretch engine, its seed sample, parameters and
/// seed. `parameters.targetSeconds` is the voice's natural (loop) length.
public struct GenerativeSource: Sendable, Codable, Equatable {

    /// The seed sample the engine stretches.
    public var audio: AudioReference

    /// The engine settings — mode, length, layering, everything.
    public var parameters: StretchParameters = StretchParameters()

    /// The render seed; change it for a different take of the same settings.
    public var seed: UInt64 = 0

    /// Creates a generative source.
    ///
    /// - Parameters:
    ///   - audio: The seed sample.
    ///   - parameters: The engine settings.
    ///   - seed: The render seed.
    public init(audio: AudioReference,
                parameters: StretchParameters = StretchParameters(),
                seed: UInt64 = 0) {
        self.audio = audio
        self.parameters = parameters
        self.seed = seed
    }
}

#endif  // !os(watchOS)
