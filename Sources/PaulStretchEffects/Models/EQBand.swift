//
//  EQBand.swift
//  SwiftPaulStretch
//
//  A single band of the parametric EQ.
//
//  Created by David Sherlock on 7/27/26.
//

import Foundation
import AVFAudio

#if !os(watchOS)

/// The filter shapes an ``EQBand`` can take.
///
/// A subset of `AVAudioUnitEQFilterType` — the shapes that earn their place
/// on a mastering-style EQ. The resonant variants are omitted because the
/// bandwidth control already provides resonance where it is musical.
public enum EQBandType: String, Codable, CaseIterable, Sendable {
    /// Removes everything below ``EQBand/frequency`` (gain is ignored).
    case highPass
    /// Lifts or cuts everything below ``EQBand/frequency``.
    case lowShelf
    /// A bell centred on ``EQBand/frequency``, width set by ``EQBand/bandwidth``.
    case parametric
    /// Lifts or cuts everything above ``EQBand/frequency``.
    case highShelf
    /// Removes everything above ``EQBand/frequency`` (gain is ignored).
    case lowPass
    /// Passes a band around ``EQBand/frequency`` (gain is ignored).
    case bandPass
    /// Notches out a band around ``EQBand/frequency`` (gain is ignored).
    case bandStop

    /// A short label for pickers.
    public var label: String {
        switch self {
        case .highPass:   return "High-pass"
        case .lowShelf:   return "Low shelf"
        case .parametric: return "Bell"
        case .highShelf:  return "High shelf"
        case .lowPass:    return "Low-pass"
        case .bandPass:   return "Band-pass"
        case .bandStop:   return "Notch"
        }
    }

    /// `true` when the band's gain does nothing, so the UI can hide it.
    public var usesGain: Bool {
        switch self {
        case .lowShelf, .parametric, .highShelf: return true
        case .highPass, .lowPass, .bandPass, .bandStop: return false
        }
    }

    var avFilterType: AVAudioUnitEQFilterType {
        switch self {
        case .highPass:   return .highPass
        case .lowShelf:   return .lowShelf
        case .parametric: return .parametric
        case .highShelf:  return .highShelf
        case .lowPass:    return .lowPass
        case .bandPass:   return .bandPass
        case .bandStop:   return .bandStop
        }
    }
}

/// One band of the parametric EQ.
public struct EQBand: Codable, Equatable, Sendable, Identifiable {

    /// Position in the band list, and the band's stable identity for
    /// SwiftUI's `ForEach`.
    public var id: Int
    /// Whether this band affects the signal.
    public var enabled: Bool
    /// The band's filter shape.
    public var type: EQBandType
    /// Centre or corner frequency, in hertz (20…20000).
    public var frequency: Float
    /// Gain in decibels (−24…24). Ignored by pass/notch shapes.
    public var gain: Float
    /// Bandwidth in octaves (0.05…5). `AVAudioUnitEQ` expresses band width
    /// this way rather than as a Q factor; smaller is narrower.
    public var bandwidth: Float

    /// Creates a band.
    ///
    /// - Parameters:
    ///   - id: Position in the band list.
    ///   - enabled: Whether the band affects the signal.
    ///   - type: The filter shape.
    ///   - frequency: Centre or corner frequency, in hertz.
    ///   - gain: Gain in decibels. Ignored by pass and notch shapes.
    ///   - bandwidth: Width in octaves; smaller is narrower.
    public init(id: Int, enabled: Bool, type: EQBandType,
                frequency: Float, gain: Float = 0, bandwidth: Float = 1.0) {
        self.id = id
        self.enabled = enabled
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.bandwidth = bandwidth
    }

    /// The default 7-band layout: a high-pass, three shaping bands across
    /// the spectrum, two shelves and a low-pass.
    ///
    /// Every band starts disabled and flat, so switching the EQ on is
    /// silent until a band is actually dialled in.
    public static var defaultBands: [EQBand] {
        [
            EQBand(id: 0, enabled: false, type: .highPass,   frequency: 40),
            EQBand(id: 1, enabled: false, type: .lowShelf,   frequency: 120),
            EQBand(id: 2, enabled: false, type: .parametric, frequency: 400),
            EQBand(id: 3, enabled: false, type: .parametric, frequency: 1500),
            EQBand(id: 4, enabled: false, type: .parametric, frequency: 4000),
            EQBand(id: 5, enabled: false, type: .highShelf,  frequency: 6000),
            EQBand(id: 6, enabled: false, type: .lowPass,    frequency: 18000),
        ]
    }
}

#endif  // !os(watchOS)
