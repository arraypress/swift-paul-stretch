//
//  StretchLayer.swift
//  SwiftPaulStretch
//
//  One layer of a multi-pass PaulStretch: duration scale, mix gain and
//  pitch offset. The building block of both the built-in LayerPreset
//  recipes and fully custom layering.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// One stretch pass in a layered ``StretchMode/paulStretch`` render.
///
/// Layers stretch the same source by different multiples of the target
/// duration (``scale``), optionally pitch-shifted (``pitchSemitones``), and
/// are mixed at ``gain``. The built-in ``LayerPreset`` recipes are made of
/// these; set ``StretchParameters/customLayers`` to design your own — for
/// example, to control how fast a shimmer voice evolves:
///
/// ```swift
/// // A shimmer drone whose octave voice drifts at half speed:
/// params.customLayers = [
///     StretchLayer(scale: 0.5, gain: 0.55),
///     StretchLayer(scale: 1.0, gain: 0.70),
///     StretchLayer(scale: 2.0, gain: 0.45, pitchSemitones: 12),   // slow shimmer
/// ]
/// ```
public struct StretchLayer: Sendable, Codable, Equatable {

    /// Duration scale relative to the target: the layer stretches toward
    /// `scale ×` the target length before being tiled to fit. Above `1`
    /// evolves more slowly than the base voice, below `1` faster.
    public var scale: Double

    /// Mix gain for this layer.
    public var gain: Float

    /// Pitch offset for this layer, in semitones, stacked on top of
    /// ``StretchParameters/pitchSemitones``. `+12` is the classic shimmer
    /// octave.
    public var pitchSemitones: Double

    /// Creates a layer.
    ///
    /// - Parameters:
    ///   - scale: Duration scale relative to the target. Defaults to `1`.
    ///   - gain: Mix gain. Defaults to `0.7`.
    ///   - pitchSemitones: Pitch offset in semitones. Defaults to `0`.
    public init(scale: Double = 1, gain: Float = 0.7, pitchSemitones: Double = 0) {
        self.scale = scale
        self.gain = gain
        self.pitchSemitones = pitchSemitones
    }
}
