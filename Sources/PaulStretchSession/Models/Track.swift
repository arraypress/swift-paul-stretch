//
//  Track.swift
//  SwiftPaulStretch
//
//  One channel of a Session: a voice (sample or generative), its own effect
//  stack, mixer state, loop phasing, and session-time automation.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretch
import PaulStretchEffects

// This product builds on PaulStretchEffects, which compiles to an empty
// module on watchOS.
#if !os(watchOS)

/// One channel of a ``Session``.
///
/// A track holds a single voice — its resolved audio (see
/// ``SessionRenderer/renderVoice(for:sampleRate:isCancelled:)``) is placed
/// on the timeline at ``startSeconds`` and, when ``loops`` is on, repeats at
/// its own natural length until the session ends. Give tracks loops of
/// *different* lengths (61 s against 47 s against 73 s) and the arrangement
/// phases endlessly — generative structure with zero randomness at play
/// time.
public struct Track: Sendable, Codable, Equatable, Identifiable {

    /// Stable identity.
    public var id: UUID = UUID()

    /// The track name.
    public var name: String = "Track"

    /// What this track plays.
    public var source: TrackSource

    /// When the track enters the timeline, in seconds.
    public var startSeconds: Double = 0

    /// Whether the voice repeats until the session ends (at its own length —
    /// this is what makes loop phasing work). Off: the voice plays once.
    public var loops: Bool = true

    /// The initial offset into the loop, in seconds — set different phases
    /// to keep several copies of one loop from starting in unison.
    public var loopPhaseSeconds: Double = 0

    /// Channel gain, linear (`1` = unity).
    public var gain: Float = 1

    /// Stereo balance, `-1` (left) … `0` (centre) … `1` (right).
    /// Unity at centre; the far side attenuates on a cosine law.
    public var pan: Float = 0

    /// Excludes the track from the mix.
    public var isMuted: Bool = false

    /// When any track is soloed, only soloed tracks sound.
    public var isSoloed: Bool = false

    /// The track's channel strip, baked into its voice.
    public var stack: EffectStack = EffectStack()

    /// Optional gain automation over the whole session (lane value `0…1`
    /// multiplies ``gain``) — hour-long swells and fades.
    public var gainLane: AutomationLane? = nil

    /// Optional pan automation over the whole session (lane value `0…1`
    /// maps to `-1…1`, overriding ``pan``).
    public var panLane: AutomationLane? = nil

    /// Creates a track.
    ///
    /// - Parameters:
    ///   - name: The track name.
    ///   - source: What the track plays.
    public init(name: String = "Track", source: TrackSource) {
        self.name = name
        self.source = source
    }

    // MARK: Codable (tolerant — old session files survive new fields)

    private enum CodingKeys: String, CodingKey {
        case id, name, source, startSeconds, loops, loopPhaseSeconds
        case gain, pan, isMuted, isSoloed, stack, gainLane, panLane
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Track"
        source = try c.decode(TrackSource.self, forKey: .source)
        startSeconds = try c.decodeIfPresent(Double.self, forKey: .startSeconds) ?? 0
        loops = try c.decodeIfPresent(Bool.self, forKey: .loops) ?? true
        loopPhaseSeconds = try c.decodeIfPresent(Double.self, forKey: .loopPhaseSeconds) ?? 0
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1
        pan = try c.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSoloed = try c.decodeIfPresent(Bool.self, forKey: .isSoloed) ?? false
        stack = try c.decodeIfPresent(EffectStack.self, forKey: .stack) ?? EffectStack()
        gainLane = try c.decodeIfPresent(AutomationLane.self, forKey: .gainLane)
        panLane = try c.decodeIfPresent(AutomationLane.self, forKey: .panLane)
    }
}

#endif  // !os(watchOS)
