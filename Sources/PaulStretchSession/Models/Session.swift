//
//  Session.swift
//  SwiftPaulStretch
//
//  The ambient-studio document: a timeline measured in minutes (no tempo),
//  tracks that loop and phase against each other, and a master effect stack.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretchEffects

// This product builds on PaulStretchEffects, which compiles to an empty
// module on watchOS.
#if !os(watchOS)

/// An ambient session: the whole arrangement as one Codable value.
///
/// Sessions are time-based — the ruler is seconds, not bars. Each ``Track``
/// holds one voice (a sample loop or a generative engine) that can loop at
/// its own length; tracks with different loop lengths phase against each
/// other and never line up the same way twice (the tape-loop model behind
/// *Music for Airports*). Bounce with ``SessionRenderer/render(_:voices:isCancelled:progress:)``.
///
/// The tolerant `Codable` conformance means session files survive new
/// fields being added in later versions.
public struct Session: Sendable, Codable, Equatable {

    /// The session name.
    public var name: String = "Untitled"

    /// The sample rate everything renders at, in hertz.
    public var sampleRate: Double = 44_100

    /// The piece's length, in seconds. Looping tracks repeat (and phase)
    /// until this point; the bounce is exactly this long plus any master
    /// effect tail.
    public var durationSeconds: Double = 600

    /// The tracks, top to bottom.
    public var tracks: [Track] = []

    /// The master channel strip, applied to the summed mix.
    public var master: EffectStack = EffectStack()

    /// Creates an empty ten-minute session.
    public init() {}

    /// `true` when any track is soloed (soloing mutes every other track).
    public var isAnySoloed: Bool { tracks.contains { $0.isSoloed } }

    /// Whether a track sounds in the current mute/solo state.
    ///
    /// - Parameter track: The track to test.
    /// - Returns: `true` when the track contributes to the mix.
    public func isAudible(_ track: Track) -> Bool {
        !track.isMuted && (!isAnySoloed || track.isSoloed)
    }

    // MARK: Codable (tolerant — old session files survive new fields)

    private enum CodingKeys: String, CodingKey {
        case name, sampleRate, durationSeconds, tracks, master
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 44_100
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 600
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        master = try c.decodeIfPresent(EffectStack.self, forKey: .master) ?? EffectStack()
    }
}

#endif  // !os(watchOS)
