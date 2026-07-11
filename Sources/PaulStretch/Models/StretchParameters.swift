//
//  StretchParameters.swift
//  SwiftPaulStretch
//
//  Every knob of the render pipeline in one Codable value.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// The complete parameter set for a render — mode, target length, stretch
/// shaping, source treatment and output envelope.
///
/// The struct is `Codable`, so host apps can persist presets as JSON, and
/// `Equatable`, so UIs can cheaply detect "settings changed since last
/// render". The defaults reproduce the classic layered PaulStretch drone.
///
/// ```swift
/// var params = StretchParameters()
/// params.mode = .paulStretch
/// params.targetSeconds = 300
/// params.seamlessLoop = true
/// let drone = StretchRenderer.render(source, parameters: params)
/// ```
public struct StretchParameters: Sendable, Codable, Equatable {

    // MARK: Mode + length

    /// Which engine renders the source. See ``StretchMode``.
    public var mode: StretchMode = .paulStretch

    /// The desired output duration, in seconds.
    public var targetSeconds: Double = 300

    /// The maximum stretch ratio a single pass may apply.
    ///
    /// If the source can't reach ``targetSeconds`` within this cap, the
    /// stretched block is tiled with equal-power crossfades to fill the
    /// remainder — audible as a periodic swell at each seam. The high
    /// default lets real-world sources fill an hour in one seamless pass;
    /// lower it deliberately for a repeating, breathing character.
    public var maxStretch: Double = 1500

    // MARK: PaulStretch shaping

    /// Multi-pass layering for ``StretchMode/paulStretch``. See ``LayerPreset``.
    public var layering: LayerPreset = .standard

    /// The STFT window length, in seconds. Rounded up to a power-of-two
    /// frame count internally.
    ///
    /// Longer windows are smoother and more pad-like; shorter windows keep
    /// more of the source's texture. The classic PaulStretch sound lives
    /// around `0.25`–`0.4`.
    public var windowSeconds: Double = 0.25

    /// How much each window's phases are randomised, `0…1`.
    ///
    /// `1` is the classic full wash; `0` leaves phases untouched (a plain
    /// smeared stretch); values between rotate each bin by a bounded random
    /// amount.
    public var phaseRandomness: Double = 1.0

    /// FFT-domain pitch shift in semitones, applied inside the stretch
    /// without changing the duration. `0` is off.
    public var pitchSemitones: Double = 0

    /// How strongly rising-energy moments ease off the phase scramble, `0…1`.
    ///
    /// At `0` the wash is uniform; higher values keep attacks and swells
    /// more intact at the cost of a less even drone.
    public var onsetSensitivity: Double = 0

    // MARK: Source treatment

    /// Tape-machine varispeed applied to the source before stretching
    /// (`< 1` = slower and lower). In ``StretchMode/tapeSlow`` this *is* the
    /// effect; in the other modes it pre-colours the source.
    public var tapeSpeed: Double = 1.0

    /// Play the source backwards before stretching.
    public var reverse: Bool = false

    // MARK: Output shaping

    /// Mid/side stereo width of the final render: `1` = unchanged,
    /// `0` = mono, `> 1` = wider.
    public var stereoWidth: Double = 1.0

    /// Where the freeze captures its spectrum, as a normalised position
    /// `0…1` through the source (``StretchMode/spectralFreeze`` only).
    public var freezePosition: Double = 0.5

    /// Magnitude-spectrum blur for the freeze, `0…1`: low values keep the
    /// tonal peaks, high values wash toward coloured noise
    /// (``StretchMode/spectralFreeze`` only).
    public var freezeSmear: Double = 0.1

    /// Render a seamless loop instead of a one-shot.
    ///
    /// The pipeline renders one loop-crossfade longer than
    /// ``targetSeconds`` and equal-power crossfades the tail into the head,
    /// so the file repeats with no audible seam. When enabled the fade
    /// parameters are ignored.
    public var seamlessLoop: Bool = false

    /// Linear fade-in applied to one-shot renders, in seconds. Capped at
    /// 10 % of the render length.
    public var fadeInSeconds: Double = 20

    /// Linear fade-out applied to one-shot renders, in seconds. Capped at
    /// 15 % of the render length.
    public var fadeOutSeconds: Double = 30

    /// Creates a parameter set with the default layered-drone settings.
    public init() {}
}
