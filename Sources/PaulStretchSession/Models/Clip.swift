//
//  Clip.swift
//  SwiftPaulStretch
//
//  A block on the timeline: where it sits, how long it runs, what audio
//  fills it (a sample or a generative engine), and its fades.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretch

// This product builds on PaulStretchEffects, which compiles to an empty
// module on watchOS.
#if !os(watchOS)

/// What fills a ``Clip``.
public enum ClipSource: Sendable, Codable, Equatable {
    /// An audio file played as-is — field recordings, textures, stems.
    case sample(SampleSource)
    /// A stretch engine rendering a voice from a seed sample. Same source +
    /// parameters + seed always renders the identical voice.
    case generative(GenerativeSource)

    /// The underlying audio reference (embedded bytes or file path).
    public var audio: AudioReference {
        switch self {
        case .sample(let s): return s.audio
        case .generative(let g): return g.audio
        }
    }
}

/// One block on a track's timeline.
///
/// A clip *places* a voice: the voice renders at its natural length
/// (deterministically, so it caches), and the clip decides where it starts,
/// how long it runs (tiling the voice when ``fillsWithLoop`` is on),
/// where in the voice it begins reading (``offsetSeconds`` — the left-trim
/// handle), and how it fades in and out. Dragging, trimming and fading a
/// clip never re-renders its voice.
public struct Clip: Sendable, Codable, Equatable, Identifiable {

    /// Stable identity.
    public var id: UUID = UUID()

    /// The clip name (shown on the block).
    public var name: String = ""

    /// What fills the clip.
    public var source: ClipSource

    /// Where the clip starts on the timeline, in seconds.
    public var startSeconds: Double = 0

    /// The clip's placed length, in seconds.
    public var durationSeconds: Double = 60

    /// Where in the voice the clip begins reading, in seconds (left-trim).
    public var offsetSeconds: Double = 0

    /// Clip gain, linear (`1` = unity).
    public var gain: Float = 1

    /// Fade-in length, in seconds.
    public var fadeInSeconds: Double = 0

    /// Fade-out length, in seconds.
    public var fadeOutSeconds: Double = 0

    /// Tiles the voice to fill the clip when the clip is longer than the
    /// voice (loops of different lengths phase against each other). Off:
    /// the voice plays once and the rest of the clip is silence.
    public var fillsWithLoop: Bool = true

    /// The clip's end on the timeline, in seconds.
    public var endSeconds: Double { startSeconds + durationSeconds }

    /// Creates a clip.
    ///
    /// - Parameters:
    ///   - name: The display name.
    ///   - source: What fills the clip.
    ///   - startSeconds: Timeline position, in seconds.
    ///   - durationSeconds: Placed length, in seconds.
    public init(name: String = "",
                source: ClipSource,
                startSeconds: Double = 0,
                durationSeconds: Double = 60) {
        self.name = name
        self.source = source
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
    }

    // MARK: Codable (tolerant — old session files survive new fields)

    private enum CodingKeys: String, CodingKey {
        case id, name, source, startSeconds, durationSeconds, offsetSeconds
        case gain, fadeInSeconds, fadeOutSeconds, fillsWithLoop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        source = try c.decode(ClipSource.self, forKey: .source)
        startSeconds = try c.decodeIfPresent(Double.self, forKey: .startSeconds) ?? 0
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 60
        offsetSeconds = try c.decodeIfPresent(Double.self, forKey: .offsetSeconds) ?? 0
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1
        fadeInSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeInSeconds) ?? 0
        fadeOutSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeOutSeconds) ?? 0
        fillsWithLoop = try c.decodeIfPresent(Bool.self, forKey: .fillsWithLoop) ?? true
    }
}

#endif  // !os(watchOS)
