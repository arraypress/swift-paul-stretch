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

    // The first eight cases predate the full set — their `allCases`
    // positions are load-bearing (hosts migrated legacy integer indices
    // against this order), so new presets are appended after them.
    case smallRoom
    case mediumRoom
    case largeRoom
    case mediumHall
    case largeHall
    case plate
    case cathedral
    case largeChamber
    case mediumChamber
    case largeRoom2
    case mediumHall2
    case mediumHall3
    case largeHall2

    /// A human-readable name suitable for menus.
    public var displayName: String {
        switch self {
        case .smallRoom:     return "Small Room"
        case .mediumRoom:    return "Medium Room"
        case .largeRoom:     return "Large Room"
        case .largeRoom2:    return "Large Room 2"
        case .mediumHall:    return "Medium Hall"
        case .mediumHall2:   return "Medium Hall 2"
        case .mediumHall3:   return "Medium Hall 3"
        case .largeHall:     return "Large Hall"
        case .largeHall2:    return "Large Hall 2"
        case .plate:         return "Plate"
        case .mediumChamber: return "Medium Chamber"
        case .largeChamber:  return "Large Chamber"
        case .cathedral:     return "Cathedral"
        }
    }

    /// The corresponding Apple factory preset.
    public var avPreset: AVAudioUnitReverbPreset {
        switch self {
        case .smallRoom:     return .smallRoom
        case .mediumRoom:    return .mediumRoom
        case .largeRoom:     return .largeRoom
        case .largeRoom2:    return .largeRoom2
        case .mediumHall:    return .mediumHall
        case .mediumHall2:   return .mediumHall2
        case .mediumHall3:   return .mediumHall3
        case .largeHall:     return .largeHall
        case .largeHall2:    return .largeHall2
        case .plate:         return .plate
        case .mediumChamber: return .mediumChamber
        case .largeChamber:  return .largeChamber
        case .cathedral:     return .cathedral
        }
    }
}

#endif  // !os(watchOS)
