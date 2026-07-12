//
//  Track.swift
//  SwiftPaulStretch
//
//  One lane of the arrangement: its clips, its channel strip, mixer state
//  and session-time automation.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretch
import PaulStretchEffects

// This product builds on PaulStretchEffects, which compiles to an empty
// module on watchOS.
#if !os(watchOS)

/// One lane of a ``Session``: an ordered set of ``Clip``s plus the channel.
///
/// The track's ``stack`` (its insert strip) is baked into each clip's voice
/// — every clip gets its own effect tail. Gain, pan, mute and solo are the
/// live mixer channel; ``gainLane``/``panLane`` automate them over the
/// whole session.
public struct Track: Sendable, Codable, Equatable, Identifiable {

    /// Stable identity.
    public var id: UUID = UUID()

    /// The track name.
    public var name: String = "Track"

    /// The clips on this lane (any order; positions live on the clips).
    public var clips: [Clip] = []

    /// Channel gain, linear (`1` = unity).
    public var gain: Float = 1

    /// Stereo balance, `-1` (left) … `0` (centre) … `1` (right).
    /// Unity at centre; the far side attenuates on a cosine law.
    public var pan: Float = 0

    /// Excludes the track from the mix.
    public var isMuted: Bool = false

    /// When any track is soloed, only soloed tracks sound.
    public var isSoloed: Bool = false

    /// The track's channel strip, baked into each clip's voice.
    public var stack: EffectStack = EffectStack()

    /// Optional gain automation over the whole session (lane value `0…1`
    /// multiplies ``gain``) — hour-long swells and fades.
    public var gainLane: AutomationLane? = nil

    /// Optional pan automation over the whole session (lane value `0…1`
    /// maps to `-1…1`, overriding ``pan``).
    public var panLane: AutomationLane? = nil

    /// Creates a track.
    ///
    /// - Parameter name: The track name.
    public init(name: String = "Track") {
        self.name = name
    }

    // MARK: Codable (tolerant — old session files survive new fields)

    private enum CodingKeys: String, CodingKey {
        case id, name, clips, gain, pan, isMuted, isSoloed, stack, gainLane, panLane
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Track"
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
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
