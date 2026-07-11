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

    /// How far the freeze's capture point drifts through the source over
    /// the render, `0…1` (``StretchMode/spectralFreeze`` only).
    ///
    /// `0` is the classic static freeze; above zero the captured spectrum
    /// slowly scans from ``freezePosition`` toward the end of the source —
    /// "frozen but alive". With ``seamlessLoop`` the loop crossfade blends
    /// the scan back to its starting spectrum.
    public var freezeScan: Double = 0

    // MARK: Granular cloud (``StretchMode/granularCloud`` only)

    /// The length of each grain, in seconds.
    public var grainSeconds: Double = 0.15

    /// How many grains overlap at any instant (grain spacing =
    /// ``grainSeconds`` / density). Higher is denser and smoother.
    public var grainDensity: Double = 8

    /// Random offset of each grain's source position, as a fraction of the
    /// source duration (`0…1`). Higher values blur the scrub position into
    /// a wider cloud.
    public var grainPositionJitter: Double = 0.05

    /// Random per-grain pitch, in ± semitones. `12` scatters grains across
    /// a full octave; ``pitchSemitones`` shifts the whole cloud.
    public var grainPitchSpread: Double = 0

    /// Random per-grain stereo position, `0…1` (`0` = centred mono cloud,
    /// `1` = grains spread across the full stereo field).
    public var grainPanSpread: Double = 0.6

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

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case mode, targetSeconds, maxStretch, layering, windowSeconds,
             phaseRandomness, pitchSemitones, onsetSensitivity, tapeSpeed,
             reverse, stereoWidth, freezePosition, freezeSmear, freezeScan,
             grainSeconds, grainDensity, grainPositionJitter,
             grainPitchSpread, grainPanSpread,
             seamlessLoop, fadeInSeconds, fadeOutSeconds
    }

    /// Tolerant decoding: any field missing from the JSON (a preset saved
    /// by an older library version) keeps its default, so stored presets
    /// survive library upgrades.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(StretchMode.self, forKey: .mode) ?? mode
        targetSeconds = try c.decodeIfPresent(Double.self, forKey: .targetSeconds) ?? targetSeconds
        maxStretch = try c.decodeIfPresent(Double.self, forKey: .maxStretch) ?? maxStretch
        layering = try c.decodeIfPresent(LayerPreset.self, forKey: .layering) ?? layering
        windowSeconds = try c.decodeIfPresent(Double.self, forKey: .windowSeconds) ?? windowSeconds
        phaseRandomness = try c.decodeIfPresent(Double.self, forKey: .phaseRandomness) ?? phaseRandomness
        pitchSemitones = try c.decodeIfPresent(Double.self, forKey: .pitchSemitones) ?? pitchSemitones
        onsetSensitivity = try c.decodeIfPresent(Double.self, forKey: .onsetSensitivity) ?? onsetSensitivity
        tapeSpeed = try c.decodeIfPresent(Double.self, forKey: .tapeSpeed) ?? tapeSpeed
        reverse = try c.decodeIfPresent(Bool.self, forKey: .reverse) ?? reverse
        stereoWidth = try c.decodeIfPresent(Double.self, forKey: .stereoWidth) ?? stereoWidth
        freezePosition = try c.decodeIfPresent(Double.self, forKey: .freezePosition) ?? freezePosition
        freezeSmear = try c.decodeIfPresent(Double.self, forKey: .freezeSmear) ?? freezeSmear
        freezeScan = try c.decodeIfPresent(Double.self, forKey: .freezeScan) ?? freezeScan
        grainSeconds = try c.decodeIfPresent(Double.self, forKey: .grainSeconds) ?? grainSeconds
        grainDensity = try c.decodeIfPresent(Double.self, forKey: .grainDensity) ?? grainDensity
        grainPositionJitter = try c.decodeIfPresent(Double.self, forKey: .grainPositionJitter) ?? grainPositionJitter
        grainPitchSpread = try c.decodeIfPresent(Double.self, forKey: .grainPitchSpread) ?? grainPitchSpread
        grainPanSpread = try c.decodeIfPresent(Double.self, forKey: .grainPanSpread) ?? grainPanSpread
        seamlessLoop = try c.decodeIfPresent(Bool.self, forKey: .seamlessLoop) ?? seamlessLoop
        fadeInSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeInSeconds) ?? fadeInSeconds
        fadeOutSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeOutSeconds) ?? fadeOutSeconds
    }
}
