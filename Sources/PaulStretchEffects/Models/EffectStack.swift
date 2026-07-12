//
//  EffectStack.swift
//  SwiftPaulStretch
//
//  An ordered, reorderable chain of EffectDevices — the channel-strip model:
//  what the audio passes through, top to bottom.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// An ordered chain of ``EffectDevice``s, processed top to bottom.
///
/// This is the channel-strip model: order matters (a filter before a reverb
/// darkens the send; after it, the tail), duplicates are allowed, and each
/// device bypasses independently. Bake a stack with
/// ``EffectStackBaker/bake(_:stack:)``.
///
/// ```swift
/// var strip = EffectStack([
///     EffectDevice(.sweepFilter(filterSettings)),
///     EffectDevice(.shimmer(shimmerSettings)),
///     EffectDevice(.convolutionReverb(spaceSettings)),
/// ])
/// strip.move(fromIndex: 0, toIndex: 2)      // filter the reverb tail instead
/// let wet = EffectStackBaker.bake(dry, stack: strip)
/// ```
public struct EffectStack: Sendable, Codable, Equatable {

    /// The devices, in processing order.
    public var devices: [EffectDevice]

    /// Creates a stack.
    ///
    /// - Parameter devices: The devices, in processing order.
    public init(_ devices: [EffectDevice] = []) {
        self.devices = devices
    }

    /// The devices that will actually process audio (enabled, in order).
    public var activeDevices: [EffectDevice] { devices.filter(\.isEnabled) }

    /// `true` when no enabled device would touch the audio.
    public var isTransparent: Bool { activeDevices.isEmpty }

    /// Moves a device to a new position (indices into ``devices``).
    ///
    /// Out-of-range indices are clamped; moving a device onto itself is a
    /// no-op.
    ///
    /// - Parameters:
    ///   - fromIndex: The device's current position.
    ///   - toIndex: The position it should occupy after the move.
    public mutating func move(fromIndex: Int, toIndex: Int) {
        guard devices.indices.contains(fromIndex) else { return }
        let device = devices.remove(at: fromIndex)
        devices.insert(device, at: max(0, min(devices.count, toIndex)))
    }

    /// Removes the device with `id` (no-op when absent).
    ///
    /// - Parameter id: The device's identity.
    public mutating func remove(id: UUID) {
        devices.removeAll { $0.id == id }
    }

    /// A cache key that changes whenever the stack's audible result would —
    /// device order, bypass states and every setting (custom impulse bytes
    /// are folded in by size + hash).
    ///
    /// Hosts that bake stacks into playback buffers should re-bake when
    /// (and only when) this changes. Compare within a single process only —
    /// `hashValue` is seeded per launch.
    public var signature: String {
        var parts: [String] = []
        for d in activeDevices {
            // Strip bulky impulse bytes down to a size+hash marker; encode
            // the rest of the device verbatim.
            var device = d
            if case .convolutionReverb(var s) = device.kind, let data = s.customIRData {
                s.customIRName = (s.customIRName ?? "") + "#\(data.count),\(data.hashValue)"
                s.customIRData = nil
                device.kind = .convolutionReverb(s)
            }
            device.id = UUID(uuid: UUID_NULL)   // identity must not affect the key
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if let data = try? encoder.encode(device) {
                parts.append(String(decoding: data, as: UTF8.self))
            }
        }
        return parts.joined(separator: "|")
    }
}

#endif  // !os(watchOS)
