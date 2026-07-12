//
//  FilterShape.swift
//  SwiftPaulStretch
//
//  The sweep filter's response shapes.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// The response shape of ``SweepFilter`` (all three come from one
/// state-variable topology, so switching shapes keeps the same character).
public enum FilterShape: String, CaseIterable, Sendable, Codable {
    case lowPass
    case highPass
    case bandPass

    /// A human-readable name suitable for menus.
    public var displayName: String {
        switch self {
        case .lowPass:  return "Low Pass"
        case .highPass: return "High Pass"
        case .bandPass: return "Band Pass"
        }
    }
}

#endif  // !os(watchOS)
