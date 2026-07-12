//
//  ReverbProfile.swift
//  SwiftPaulStretch
//
//  The convolution reverb's algorithmic impulse-response characters.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// The impulse-response character of ``ConvolutionReverb`` — each profile
/// shapes pre-delay, decay curve, brightness, low-end weight and
/// early-reflection density differently.
public enum ReverbProfile: String, CaseIterable, Sendable, Codable {

    /// Tight, bright, bouncy: dense early reflections, no pre-delay, fast
    /// curved decay.
    case plate

    /// Warm and balanced: some pre-delay, gentle high rolloff, moderate
    /// low-end support.
    case hall

    /// Huge, dense, dark: long pre-delay, flat decay, heavy dedicated
    /// low-frequency layer that outlasts the highs.
    case cathedral

    /// Pure exponential wash: white noise under an exponential-approach
    /// envelope — the classic "slowed + reverb" internet-era sound.
    case exponential

    /// A human-readable name suitable for menus.
    public var displayName: String {
        switch self {
        case .plate:       return "Plate"
        case .hall:        return "Hall"
        case .cathedral:   return "Cathedral"
        case .exponential: return "Wash"
        }
    }
}

#endif  // !os(watchOS)
