//
//  DistortionPreset.swift
//  SwiftPaulStretch
//
//  All 22 Apple distortion factory presets, as a Codable enum with display
//  names.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// The complete set of `AVAudioUnitDistortionPreset` factory characters —
/// from bit-crush drums through broken speakers to alien speech mangling.
public enum DistortionPreset: String, CaseIterable, Sendable, Codable {

    case drumsBitBrush
    case drumsBufferBeats
    case drumsLoFi
    case multiBrokenSpeaker
    case multiCellphoneConcert
    case multiDecimated1
    case multiDecimated2
    case multiDecimated3
    case multiDecimated4
    case multiDistortedFunk
    case multiDistortedCubed
    case multiDistortedSquared
    case multiEcho1
    case multiEcho2
    case multiEchoTight1
    case multiEchoTight2
    case multiEverythingIsBroken
    case speechAlienChatter
    case speechCosmicInterference
    case speechGoldenPi
    case speechRadioTower
    case speechWaves

    /// A human-readable name suitable for menus.
    public var displayName: String {
        switch self {
        case .drumsBitBrush:            return "Bit Brush"
        case .drumsBufferBeats:         return "Buffer Beats"
        case .drumsLoFi:                return "Lo-Fi"
        case .multiBrokenSpeaker:       return "Broken Speaker"
        case .multiCellphoneConcert:    return "Cellphone Concert"
        case .multiDecimated1:          return "Decimated 1"
        case .multiDecimated2:          return "Decimated 2"
        case .multiDecimated3:          return "Decimated 3"
        case .multiDecimated4:          return "Decimated 4"
        case .multiDistortedFunk:       return "Distorted Funk"
        case .multiDistortedCubed:      return "Distorted Cubed"
        case .multiDistortedSquared:    return "Distorted Squared"
        case .multiEcho1:               return "Echo 1"
        case .multiEcho2:               return "Echo 2"
        case .multiEchoTight1:          return "Echo Tight 1"
        case .multiEchoTight2:          return "Echo Tight 2"
        case .multiEverythingIsBroken:  return "Everything Is Broken"
        case .speechAlienChatter:       return "Alien Chatter"
        case .speechCosmicInterference: return "Cosmic Interference"
        case .speechGoldenPi:           return "Golden Pi"
        case .speechRadioTower:         return "Radio Tower"
        case .speechWaves:              return "Waves"
        }
    }

    /// The corresponding Apple factory preset.
    public var avPreset: AVAudioUnitDistortionPreset {
        switch self {
        case .drumsBitBrush:            return .drumsBitBrush
        case .drumsBufferBeats:         return .drumsBufferBeats
        case .drumsLoFi:                return .drumsLoFi
        case .multiBrokenSpeaker:       return .multiBrokenSpeaker
        case .multiCellphoneConcert:    return .multiCellphoneConcert
        case .multiDecimated1:          return .multiDecimated1
        case .multiDecimated2:          return .multiDecimated2
        case .multiDecimated3:          return .multiDecimated3
        case .multiDecimated4:          return .multiDecimated4
        case .multiDistortedFunk:       return .multiDistortedFunk
        case .multiDistortedCubed:      return .multiDistortedCubed
        case .multiDistortedSquared:    return .multiDistortedSquared
        case .multiEcho1:               return .multiEcho1
        case .multiEcho2:               return .multiEcho2
        case .multiEchoTight1:          return .multiEchoTight1
        case .multiEchoTight2:          return .multiEchoTight2
        case .multiEverythingIsBroken:  return .multiEverythingIsBroken
        case .speechAlienChatter:       return .speechAlienChatter
        case .speechCosmicInterference: return .speechCosmicInterference
        case .speechGoldenPi:           return .speechGoldenPi
        case .speechRadioTower:         return .speechRadioTower
        case .speechWaves:              return .speechWaves
        }
    }
}

#endif  // !os(watchOS)
