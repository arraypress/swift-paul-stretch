//
//  ReverbPreset.swift
//  SwiftPaulStretch
//
//  The Apple reverb factory presets, as a Codable enum with display names.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// The reverb spaces available to ``EffectsParameters/reverbPreset``.
///
/// These wrap `AVAudioUnitReverbPreset` factory presets in a `Codable`,
/// display-friendly enum so host apps can persist and list them directly.
/// ``cathedral`` is the classic PaulStretch pairing — it masks the fast
/// amplitude "grain" inherent to the stretch.
public enum ReverbPreset: String, CaseIterable, Sendable, Codable {

    case smallRoom
    case mediumRoom
    case largeRoom
    case mediumHall
    case largeHall
    case plate
    case cathedral
    case largeChamber

    /// A human-readable name suitable for menus.
    public var displayName: String {
        switch self {
        case .smallRoom:    return "Small Room"
        case .mediumRoom:   return "Medium Room"
        case .largeRoom:    return "Large Room"
        case .mediumHall:   return "Medium Hall"
        case .largeHall:    return "Large Hall"
        case .plate:        return "Plate"
        case .cathedral:    return "Cathedral"
        case .largeChamber: return "Large Chamber"
        }
    }

    /// The corresponding Apple factory preset.
    public var avPreset: AVAudioUnitReverbPreset {
        switch self {
        case .smallRoom:    return .smallRoom
        case .mediumRoom:   return .mediumRoom
        case .largeRoom:    return .largeRoom
        case .mediumHall:   return .mediumHall
        case .largeHall:    return .largeHall
        case .plate:        return .plate
        case .cathedral:    return .cathedral
        case .largeChamber: return .largeChamber
        }
    }
}

#endif  // !os(watchOS)
