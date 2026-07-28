//
//  EffectsParameters.swift
//  SwiftPaulStretch
//
//  The effect-chain settings: Filter → EQ → Delay → Reverb.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// Settings for the stock effect chain (Filter → EQ → Delay → Reverb).
///
/// One `EffectsParameters` value drives both halves of the
/// what-you-hear-is-what-you-export pattern: apply it to a live
/// ``EffectChain`` on a playback graph *and* pass it to
/// ``EffectsBaker/bake(_:effects:)`` (or ``StreamingEffectsBaker``) when
/// exporting, and the rendered file matches the monitored audio.
///
/// The struct is `Codable` so host apps can persist it inside their presets.
/// All effects default to off.
public struct EffectsParameters: Sendable, Equatable, Codable {

    // MARK: Reverb

    /// Whether the reverb is active.
    public var reverbEnabled = false

    /// The reverb space. Defaults to ``ReverbPreset/cathedral``, the classic
    /// PaulStretch pairing.
    public var reverbPreset: ReverbPreset = .cathedral

    /// Reverb wet/dry mix, `0…100`.
    public var reverbMix: Float = 35

    // MARK: 3-band EQ

    /// Whether the EQ is active.
    public var eqEnabled = false

    /// Low-shelf gain at 120 Hz, in decibels.
    /// The parametric EQ bands, low to high.
    ///
    /// A high-pass, two shelves, three bells and a low-pass. Every band
    /// starts disabled and flat, so enabling the EQ is silent until a band
    /// is dialled in.
    public var eqBands: [EQBand] = EQBand.defaultBands


    // MARK: Resonant low-pass filter

    /// Whether the filter is active.
    public var filterEnabled = false

    /// Filter cutoff frequency, in hertz (clamped to `20…20000`).
    public var filterCutoff: Float = 8000

    /// Resonance peak at the cutoff, in decibels (`0…24`). At `0` the filter
    /// runs non-resonant.
    public var filterResonance: Float = 0

    // MARK: Delay

    /// Whether the delay is active.
    public var delayEnabled = false

    /// Delay time, in seconds.
    public var delayTime: Float = 0.35

    /// Delay feedback, `-100…100` (negative values invert).
    public var delayFeedback: Float = 35

    /// Delay wet/dry mix, `0…100`.
    public var delayMix: Float = 25

    /// Low-pass cutoff inside the delay's feedback path, in hertz
    /// (`10…22050`) — darkens each successive echo.
    public var delayLowPassCutoff: Float = 8000

    // MARK: Distortion

    /// Whether the distortion is active.
    public var distortionEnabled = false

    /// The distortion character. See ``DistortionPreset`` for all 22
    /// factory presets.
    public var distortionPreset: DistortionPreset = .multiDecimated1

    /// Gain applied before the distortion stage, in decibels (`-80…20`) —
    /// the drive control.
    public var distortionPreGain: Float = -6

    /// Distortion wet/dry mix, `0…100`.
    public var distortionMix: Float = 50

    // MARK: Dynamics processor (compressor/expander)

    /// Whether the compressor is active.
    public var compressorEnabled = false

    /// Compression threshold, in decibels (`-40…20`).
    public var compressorThreshold: Float = -20

    /// Headroom above the threshold, in decibels (`0.1…40`). **Lower**
    /// headroom means **harder** compression — Apple's dynamics processor
    /// derives the ratio from this rather than exposing one directly.
    public var compressorHeadroom: Float = 5

    /// Expansion ratio below the expansion threshold (`1…50`). `1` disables
    /// downward expansion.
    public var compressorExpansionRatio: Float = 1

    /// Expansion threshold, in decibels.
    public var compressorExpansionThreshold: Float = -100

    /// Attack time, in seconds (`0.0001…0.2`).
    public var compressorAttack: Float = 0.01

    /// Release time, in seconds (`0.01…3`).
    public var compressorRelease: Float = 0.25

    /// Make-up gain after compression, in decibels (`-40…40`).
    public var compressorGain: Float = 0

    // MARK: Peak limiter

    /// Whether the peak limiter is active (last in the chain — a safety
    /// ceiling for hot mixes).
    public var limiterEnabled = false

    /// Gain applied before limiting, in decibels (`-40…40`).
    public var limiterPreGain: Float = 0

    /// Attack time, in seconds (`0.001…0.03`).
    public var limiterAttack: Float = 0.012

    /// Decay time, in seconds (`0.001…0.06`).
    public var limiterDecay: Float = 0.024

    // MARK: Shimmer reverb

    /// Whether the shimmer reverb is active.
    ///
    /// Shimmer is the library's own DSP (see ``ShimmerReverb``): a reverb
    /// tank whose output is pitch-shifted and fed back into itself, so the
    /// wash climbs in ethereal octaves. Because `AVAudioEngine` graphs
    /// cannot contain feedback cycles, shimmer exists only in the *baked*
    /// path (``EffectsBaker``/``StreamingEffectsBaker``) — a live
    /// ``EffectChain`` ignores it; hosts re-bake to audition it.
    public var shimmerEnabled = false

    /// Shimmer wet/dry mix, `0…100`.
    public var shimmerMix: Float = 30

    /// The feedback pitch shift, in semitones. `+12` is the classic
    /// octave-up shimmer; `+7` gives fifths, negative values darken.
    public var shimmerPitch: Float = 12

    /// How much pitched wash feeds back into the tank, `0…100`. Higher
    /// values bloom longer and climb further.
    public var shimmerFeedback: Float = 45

    /// The reverb tank size, `0…100` (larger = longer, slower bloom).
    public var shimmerSize: Float = 80

    /// High-frequency damping inside the tank, `0…100`.
    public var shimmerDamping: Float = 40

    /// The climb rate of the shimmer, in seconds per octave step (`0…8`).
    ///
    /// A pre-delay in the pitched feedback path: each pass through the loop
    /// waits this long before re-entering the tank, so the bloom steps up
    /// audibly — `0` (the default) is the classic dense instant halo,
    /// `1`–`3` s turns it into a slow, deliberate ascent.
    public var shimmerClimbSeconds: Float = 0

    // MARK: Convolution reverb (algorithmic impulse responses)

    /// Whether the convolution reverb is active (baked path — see
    /// ``ConvolutionReverb``).
    public var convolutionReverbEnabled = false

    /// The impulse-response character. See ``ReverbProfile``.
    public var convolutionReverbProfile: ReverbProfile = .hall

    /// The reverb decay, in seconds (`0.1…30`) — the control the stock
    /// reverb doesn't have.
    public var convolutionReverbDecaySeconds: Float = 6

    /// Wet/dry mix, `0…100`.
    public var convolutionReverbMix: Float = 35

    /// A custom impulse response as encoded audio bytes (WAV/AIFF/anything
    /// AVFoundation decodes). When set, it **replaces** the generated
    /// profile — record a stairwell clap and drone inside it. Rides along
    /// inside saved presets (base64 in the JSON).
    public var convolutionReverbCustomIRData: Data? = nil

    /// A display name for the custom impulse (the file it came from).
    public var convolutionReverbCustomIRName: String? = nil

    // MARK: Sweep filter

    /// Whether the sweep filter is active (baked path — see ``SweepFilter``).
    public var sweepFilterEnabled = false

    /// The response shape.
    public var sweepFilterShape: FilterShape = .lowPass

    /// Static cutoff, in hertz (`20…20000`).
    public var sweepFilterCutoff: Float = 1200

    /// Resonance Q (`0.5…12`).
    public var sweepFilterResonance: Float = 2

    /// A companion high-pass ahead of the main filter, in hertz; `0`
    /// disables it.
    public var sweepFilterBassCut: Float = 0

    /// The LFO sweep period, in seconds (`1…120`).
    public var sweepFilterLFOPeriod: Float = 20

    /// The LFO sweep depth in ± octaves around the cutoff; `0` disables
    /// the LFO.
    public var sweepFilterLFODepth: Float = 0

    // MARK: Tape wow & flutter

    /// Whether wow/flutter is active (baked path — see ``WowFlutter``).
    public var wowEnabled = false

    /// Intensity `0…1` (±0.5 % pitch deviation at `1`).
    public var wowAmount: Float = 0.5

    /// The wow rate, in hertz (`0.05…8`); flutter runs at 10×.
    public var wowRateHz: Float = 0.6

    // MARK: Breathing pump

    /// Whether the breathing pump is active (baked path — see
    /// ``BreathingPump``).
    public var pumpEnabled = false

    /// Swell depth `0…1` (`1` = ±25 % gain).
    public var pumpDepth: Float = 0.5

    /// The breath rate, in hertz (`0.02…14` — tidal to tremolo).
    public var pumpRateHz: Float = 0.05

    // MARK: Auto-pan

    /// Whether the auto-pan is active (baked path — see ``AutoPan``).
    // MARK: - Placement (pure DSP)

    /// Whether static stereo placement is applied.
    public var placementEnabled = false

    /// Stereo position, `-1` hard left to `+1` hard right. Equal-power.
    public var placementPan: Float = 0

    /// Stereo width: `0` collapses to mono, `1` is unchanged, `2` doubles
    /// the side signal. Mid/side based.
    public var placementWidth: Float = 1

    // MARK: - Trance gate (pure DSP)

    /// Whether the rhythmic gate is applied.
    public var tranceGateEnabled = false

    /// Gate rate in steps per second.
    public var tranceGateRateHz: Float = 4

    /// How far closed steps duck, `0` (no gating) to `1` (full silence).
    public var tranceGateDepth: Float = 1

    /// Edge smoothing in milliseconds — the ramp between open and closed.
    /// Below about 2 ms the switching itself clicks.
    public var tranceGateSmoothingMs: Float = 8

    /// Which steps are open, as a 16-slot on/off pattern.
    public var tranceGatePattern: [Bool] = TranceGatePattern.eighths

    /// Offsets the right channel by this many steps, for a ping-pong feel.
    /// `0` gates both channels together.
    public var tranceGateStereoOffset: Int = 0

    public var autoPanEnabled = false

    /// Sweep width `0…1`.
    public var autoPanDepth: Float = 0.6

    /// The sweep rate, in hertz (`0.01…8`).
    public var autoPanRateHz: Float = 0.03

    // MARK: Automation lanes

    /// Parameter automation over the render's timeline, keyed by target.
    ///
    /// Supported keys: `"sweepFilter.cutoff"`, `"sweepFilter.resonance"`,
    /// `"wow.amount"`, `"wow.rate"`, `"pump.depth"`, `"pump.rate"`,
    /// `"autoPan.depth"`, `"autoPan.rate"`, `"convolutionReverb.mix"`.
    /// Unknown keys are ignored. Lanes evaluate against the dry render's
    /// full length; see ``AutomationLane`` for curve semantics.
    public var parameterLanes: [String: AutomationLane] = [:]

    // MARK: Chain order

    /// The order the units run in.
    ///
    /// Stored as a plain list so a host can reorder the chain — distortion
    /// before a filter is a different sound from distortion after it, and a
    /// limiter anywhere but last is not a limiter. Read through
    /// ``chainOrder`` rather than directly: that accessor fills in any slot the
    /// stored list is missing, so adding a unit to the library never
    /// invalidates a saved chain.
    private var storedChainOrder: [EffectSlot] = EffectSlot.naturalOrder

    /// Which units are IN the chain, whether or not they are switched on.
    ///
    /// Membership and on/off are different questions. A device you added,
    /// dialled in, and then switched off to compare is still part of the chain
    /// — deriving membership from `enabled` meant it vanished on the next
    /// save, taking its settings with it.
    ///
    /// `nil` means "never recorded", which is what every document written
    /// before this existed says. Read through ``devices``, which answers that
    /// case from the enabled flags so an old chain opens as the chain it was.
    private var storedDevices: Set<EffectSlot>?

    /// The units in the chain.
    public var devices: Set<EffectSlot> {
        get { storedDevices ?? Set(EffectSlot.allCases.filter { isEnabled($0) }) }
        set { storedDevices = newValue }
    }

    /// Adds a unit to the chain and switches it on.
    ///
    /// Added means ON: dropping a device in and hearing nothing would read as
    /// the add having failed.
    public mutating func addDevice(_ slot: EffectSlot) {
        var d = devices
        d.insert(slot)
        devices = d
        setEnabled(slot, true)
    }

    /// Removes a unit from the chain and switches it off — a device out of the
    /// chain that carried on processing would be a ghost.
    public mutating func removeDevice(_ slot: EffectSlot) {
        var d = devices
        d.remove(slot)
        devices = d
        setEnabled(slot, false)
    }

    /// Whether a unit is switched on.
    public func isEnabled(_ slot: EffectSlot) -> Bool {
        switch slot {
        case .filter:      return filterEnabled
        case .eq:          return eqEnabled
        case .distortion:  return distortionEnabled
        case .delay:       return delayEnabled
        case .reverb:      return reverbEnabled
        case .compressor:  return compressorEnabled
        case .limiter:     return limiterEnabled
        case .wow:         return wowEnabled
        case .sweepFilter: return sweepFilterEnabled
        case .gate:        return tranceGateEnabled
        case .pump:        return pumpEnabled
        case .autoPan:     return autoPanEnabled
        case .shimmer:     return shimmerEnabled
        case .space:       return convolutionReverbEnabled
        case .placement:   return placementEnabled
        }
    }

    /// Switches a unit on or off, leaving its membership alone.
    public mutating func setEnabled(_ slot: EffectSlot, _ on: Bool) {
        switch slot {
        case .filter:      filterEnabled = on
        case .eq:          eqEnabled = on
        case .distortion:  distortionEnabled = on
        case .delay:       delayEnabled = on
        case .reverb:      reverbEnabled = on
        case .compressor:  compressorEnabled = on
        case .limiter:     limiterEnabled = on
        case .wow:         wowEnabled = on
        case .sweepFilter: sweepFilterEnabled = on
        case .gate:        tranceGateEnabled = on
        case .pump:        pumpEnabled = on
        case .autoPan:     autoPanEnabled = on
        case .shimmer:     shimmerEnabled = on
        case .space:       convolutionReverbEnabled = on
        case .placement:   placementEnabled = on
        }
    }

    /// Every unit exactly once, in running order.
    ///
    /// Setting it accepts a partial list; the rest is appended in
    /// ``EffectSlot/naturalOrder``.
    public var chainOrder: [EffectSlot] {
        get { EffectSlot.completed(storedChainOrder) }
        set { storedChainOrder = EffectSlot.completed(newValue) }
    }

    /// The stock `AVAudioUnit` slots in running order.
    public var stockOrder: [EffectSlot] { chainOrder.filter(\.isStockUnit) }

    /// The pure-DSP slots in running order.
    public var pureOrder: [EffectSlot] { chainOrder.filter { !$0.isStockUnit } }

    /// Moves a unit to a new index among its own half of the chain.
    ///
    /// Confined to its half because the two cannot interleave: the stock units
    /// are separate nodes in the engine graph, and every pure stage runs inside
    /// one node. A move across the boundary would silently do nothing, so it is
    /// refused instead.
    ///
    /// - Parameters:
    ///   - slot: The unit to move.
    ///   - offset: How far to move it: `-1` is one earlier, `+1` one later.
    /// - Returns: `true` if the chain changed.
    @discardableResult
    public mutating func move(_ slot: EffectSlot, by offset: Int) -> Bool {
        var half = slot.isStockUnit ? stockOrder : pureOrder
        guard let from = half.firstIndex(of: slot) else { return false }
        let to = from + offset
        guard half.indices.contains(to) else { return false }
        half.remove(at: from)
        half.insert(slot, at: to)
        // Reassemble with the other half untouched and in place.
        let others = slot.isStockUnit ? pureOrder : stockOrder
        chainOrder = slot.isStockUnit ? half + others : others + half
        return true
    }

    /// Puts the chain back the way it shipped.
    public mutating func resetChainOrder() { storedChainOrder = EffectSlot.naturalOrder }

    /// `true` when any effect on the stock `AVAudioUnit` chain is enabled
    /// (everything except the library's own pure-DSP stages).
    public var isStockChainEnabled: Bool {
        reverbEnabled || eqEnabled || filterEnabled || delayEnabled
            || distortionEnabled || compressorEnabled || limiterEnabled
    }

    /// Enables the EQ's shelf and mid bands and sets their gains — the
    /// broad-strokes tone move, without hand-indexing the band list.
    ///
    /// Passing `nil` leaves that band untouched; passing `0` flattens and
    /// disables it.
    ///
    /// - Parameters:
    ///   - low: Low-shelf gain in decibels.
    ///   - mid: Mid bell gain in decibels.
    ///   - high: High-shelf gain in decibels.
    public mutating func setEQTone(low: Float? = nil, mid: Float? = nil, high: Float? = nil) {
        func set(_ index: Int, _ gain: Float?) {
            guard let gain, index < eqBands.count else { return }
            eqBands[index].gain = gain
            eqBands[index].enabled = gain != 0
        }
        set(1, low)     // low shelf, 120 Hz
        set(3, mid)     // mid bell, 1.5 kHz
        set(5, high)    // high shelf, 6 kHz
    }

    /// `true` when any of the library's own pure-DSP stages is enabled
    /// (shimmer, convolution reverb, sweep filter, trance gate, wow, pump,
    /// auto-pan, placement).
    ///
    /// These run live via ``LiveEffectChain`` when the host installs a
    /// ``LiveEffectNode``, and are baked into the buffer otherwise; export
    /// always bakes them.
    public var isPureDSPEnabled: Bool {
        shimmerEnabled || convolutionReverbEnabled || sweepFilterEnabled
            || wowEnabled || pumpEnabled || autoPanEnabled
            || tranceGateEnabled || placementEnabled
    }

    /// `true` when at least one effect is enabled — baking with everything
    /// off is a no-op and returns the dry audio untouched.
    public var isAnyEnabled: Bool {
        isStockChainEnabled || isPureDSPEnabled
    }

    /// A cache key over exactly the settings that change the *baked*
    /// pure-DSP output — shimmer, convolution reverb (including a custom
    /// impulse), sweep filter, wow, pump, auto-pan and the automation lanes.
    ///
    /// Hosts that bake the pure-DSP stages into a playback buffer should
    /// re-bake when (and only when) this string changes; live stock-chain
    /// fields are deliberately excluded so tweaking the EQ never triggers a
    /// rebake. Owning the key here means it can never drift out of sync
    /// with the parameter set the way a hand-maintained copy can.
    ///
    /// Compare within a single process only — embedded impulse bytes are
    /// folded in via `hashValue`, which is seeded per launch.
    public var pureDSPSignature: String {
        var s = "\(shimmerEnabled),\(shimmerMix),\(shimmerPitch),\(shimmerFeedback),\(shimmerSize),\(shimmerDamping),\(shimmerClimbSeconds)"
        s += "|\(convolutionReverbEnabled),\(convolutionReverbProfile.rawValue),\(convolutionReverbDecaySeconds),\(convolutionReverbMix)"
        s += ",\(convolutionReverbCustomIRData?.count ?? -1),\(convolutionReverbCustomIRData?.hashValue ?? 0),\(convolutionReverbCustomIRName ?? "")"
        s += "|\(sweepFilterEnabled),\(sweepFilterShape.rawValue),\(sweepFilterCutoff),\(sweepFilterResonance),\(sweepFilterBassCut),\(sweepFilterLFOPeriod),\(sweepFilterLFODepth)"
        s += "|\(wowEnabled),\(wowAmount),\(wowRateHz)"
        s += "|\(pumpEnabled),\(pumpDepth),\(pumpRateHz)"
        s += "|\(autoPanEnabled),\(autoPanDepth),\(autoPanRateHz)"
        s += "|\(tranceGateEnabled),\(tranceGateRateHz),\(tranceGateDepth),\(tranceGateSmoothingMs),\(tranceGateStereoOffset)"
        s += "," + tranceGatePattern.map { $0 ? "1" : "0" }.joined()
        s += "|\(placementEnabled),\(placementPan),\(placementWidth)"
        if !parameterLanes.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if let data = try? encoder.encode(parameterLanes) {
                s += "|" + String(decoding: data, as: UTF8.self)
            }
        }
        return s
    }

    /// Creates the all-off default settings.
    public init() {}

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case reverbEnabled, reverbPreset, reverbMix
        case eqEnabled, eqBands
        case filterEnabled, filterCutoff, filterResonance
        case delayEnabled, delayTime, delayFeedback, delayMix, delayLowPassCutoff
        case distortionEnabled, distortionPreset, distortionPreGain, distortionMix
        case compressorEnabled, compressorThreshold, compressorHeadroom,
             compressorExpansionRatio, compressorExpansionThreshold,
             compressorAttack, compressorRelease, compressorGain
        case limiterEnabled, limiterPreGain, limiterAttack, limiterDecay
        case shimmerEnabled, shimmerMix, shimmerPitch, shimmerFeedback,
             shimmerSize, shimmerDamping, shimmerClimbSeconds
        case convolutionReverbEnabled, convolutionReverbProfile,
             convolutionReverbDecaySeconds, convolutionReverbMix,
             convolutionReverbCustomIRData, convolutionReverbCustomIRName
        case sweepFilterEnabled, sweepFilterShape, sweepFilterCutoff,
             sweepFilterResonance, sweepFilterBassCut,
             sweepFilterLFOPeriod, sweepFilterLFODepth
        case wowEnabled, wowAmount, wowRateHz
        case pumpEnabled, pumpDepth, pumpRateHz
        case autoPanEnabled, autoPanDepth, autoPanRateHz
        case placementEnabled, placementPan, placementWidth
        case tranceGateEnabled, tranceGateRateHz, tranceGateDepth,
             tranceGateSmoothingMs, tranceGatePattern, tranceGateStereoOffset
        case parameterLanes
        case storedChainOrder
        case storedDevices
    }

    /// Tolerant decoding: any field missing from the JSON (a preset saved
    /// by an older library version) keeps its default, so stored presets
    /// survive library upgrades.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reverbEnabled = try c.decodeIfPresent(Bool.self, forKey: .reverbEnabled) ?? reverbEnabled
        reverbPreset = try c.decodeIfPresent(ReverbPreset.self, forKey: .reverbPreset) ?? reverbPreset
        reverbMix = try c.decodeIfPresent(Float.self, forKey: .reverbMix) ?? reverbMix
        eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? eqEnabled
        eqBands = try c.decodeIfPresent([EQBand].self, forKey: .eqBands) ?? eqBands
        filterEnabled = try c.decodeIfPresent(Bool.self, forKey: .filterEnabled) ?? filterEnabled
        filterCutoff = try c.decodeIfPresent(Float.self, forKey: .filterCutoff) ?? filterCutoff
        filterResonance = try c.decodeIfPresent(Float.self, forKey: .filterResonance) ?? filterResonance
        delayEnabled = try c.decodeIfPresent(Bool.self, forKey: .delayEnabled) ?? delayEnabled
        delayTime = try c.decodeIfPresent(Float.self, forKey: .delayTime) ?? delayTime
        delayFeedback = try c.decodeIfPresent(Float.self, forKey: .delayFeedback) ?? delayFeedback
        delayMix = try c.decodeIfPresent(Float.self, forKey: .delayMix) ?? delayMix
        delayLowPassCutoff = try c.decodeIfPresent(Float.self, forKey: .delayLowPassCutoff) ?? delayLowPassCutoff
        distortionEnabled = try c.decodeIfPresent(Bool.self, forKey: .distortionEnabled) ?? distortionEnabled
        distortionPreset = try c.decodeIfPresent(DistortionPreset.self, forKey: .distortionPreset) ?? distortionPreset
        distortionPreGain = try c.decodeIfPresent(Float.self, forKey: .distortionPreGain) ?? distortionPreGain
        distortionMix = try c.decodeIfPresent(Float.self, forKey: .distortionMix) ?? distortionMix
        compressorEnabled = try c.decodeIfPresent(Bool.self, forKey: .compressorEnabled) ?? compressorEnabled
        compressorThreshold = try c.decodeIfPresent(Float.self, forKey: .compressorThreshold) ?? compressorThreshold
        compressorHeadroom = try c.decodeIfPresent(Float.self, forKey: .compressorHeadroom) ?? compressorHeadroom
        compressorExpansionRatio = try c.decodeIfPresent(Float.self, forKey: .compressorExpansionRatio) ?? compressorExpansionRatio
        compressorExpansionThreshold = try c.decodeIfPresent(Float.self, forKey: .compressorExpansionThreshold) ?? compressorExpansionThreshold
        compressorAttack = try c.decodeIfPresent(Float.self, forKey: .compressorAttack) ?? compressorAttack
        compressorRelease = try c.decodeIfPresent(Float.self, forKey: .compressorRelease) ?? compressorRelease
        compressorGain = try c.decodeIfPresent(Float.self, forKey: .compressorGain) ?? compressorGain
        limiterEnabled = try c.decodeIfPresent(Bool.self, forKey: .limiterEnabled) ?? limiterEnabled
        limiterPreGain = try c.decodeIfPresent(Float.self, forKey: .limiterPreGain) ?? limiterPreGain
        limiterAttack = try c.decodeIfPresent(Float.self, forKey: .limiterAttack) ?? limiterAttack
        limiterDecay = try c.decodeIfPresent(Float.self, forKey: .limiterDecay) ?? limiterDecay
        shimmerEnabled = try c.decodeIfPresent(Bool.self, forKey: .shimmerEnabled) ?? shimmerEnabled
        shimmerMix = try c.decodeIfPresent(Float.self, forKey: .shimmerMix) ?? shimmerMix
        shimmerPitch = try c.decodeIfPresent(Float.self, forKey: .shimmerPitch) ?? shimmerPitch
        shimmerFeedback = try c.decodeIfPresent(Float.self, forKey: .shimmerFeedback) ?? shimmerFeedback
        shimmerSize = try c.decodeIfPresent(Float.self, forKey: .shimmerSize) ?? shimmerSize
        shimmerDamping = try c.decodeIfPresent(Float.self, forKey: .shimmerDamping) ?? shimmerDamping
        shimmerClimbSeconds = try c.decodeIfPresent(Float.self, forKey: .shimmerClimbSeconds) ?? shimmerClimbSeconds
        convolutionReverbEnabled = try c.decodeIfPresent(Bool.self, forKey: .convolutionReverbEnabled) ?? convolutionReverbEnabled
        convolutionReverbProfile = try c.decodeIfPresent(ReverbProfile.self, forKey: .convolutionReverbProfile) ?? convolutionReverbProfile
        convolutionReverbDecaySeconds = try c.decodeIfPresent(Float.self, forKey: .convolutionReverbDecaySeconds) ?? convolutionReverbDecaySeconds
        convolutionReverbMix = try c.decodeIfPresent(Float.self, forKey: .convolutionReverbMix) ?? convolutionReverbMix
        convolutionReverbCustomIRData = try c.decodeIfPresent(Data.self, forKey: .convolutionReverbCustomIRData) ?? convolutionReverbCustomIRData
        convolutionReverbCustomIRName = try c.decodeIfPresent(String.self, forKey: .convolutionReverbCustomIRName) ?? convolutionReverbCustomIRName
        sweepFilterEnabled = try c.decodeIfPresent(Bool.self, forKey: .sweepFilterEnabled) ?? sweepFilterEnabled
        sweepFilterShape = try c.decodeIfPresent(FilterShape.self, forKey: .sweepFilterShape) ?? sweepFilterShape
        sweepFilterCutoff = try c.decodeIfPresent(Float.self, forKey: .sweepFilterCutoff) ?? sweepFilterCutoff
        sweepFilterResonance = try c.decodeIfPresent(Float.self, forKey: .sweepFilterResonance) ?? sweepFilterResonance
        sweepFilterBassCut = try c.decodeIfPresent(Float.self, forKey: .sweepFilterBassCut) ?? sweepFilterBassCut
        sweepFilterLFOPeriod = try c.decodeIfPresent(Float.self, forKey: .sweepFilterLFOPeriod) ?? sweepFilterLFOPeriod
        sweepFilterLFODepth = try c.decodeIfPresent(Float.self, forKey: .sweepFilterLFODepth) ?? sweepFilterLFODepth
        wowEnabled = try c.decodeIfPresent(Bool.self, forKey: .wowEnabled) ?? wowEnabled
        wowAmount = try c.decodeIfPresent(Float.self, forKey: .wowAmount) ?? wowAmount
        wowRateHz = try c.decodeIfPresent(Float.self, forKey: .wowRateHz) ?? wowRateHz
        pumpEnabled = try c.decodeIfPresent(Bool.self, forKey: .pumpEnabled) ?? pumpEnabled
        pumpDepth = try c.decodeIfPresent(Float.self, forKey: .pumpDepth) ?? pumpDepth
        pumpRateHz = try c.decodeIfPresent(Float.self, forKey: .pumpRateHz) ?? pumpRateHz
        autoPanEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoPanEnabled) ?? autoPanEnabled
        autoPanDepth = try c.decodeIfPresent(Float.self, forKey: .autoPanDepth) ?? autoPanDepth
        autoPanRateHz = try c.decodeIfPresent(Float.self, forKey: .autoPanRateHz) ?? autoPanRateHz
        placementEnabled = try c.decodeIfPresent(Bool.self, forKey: .placementEnabled) ?? placementEnabled
        placementPan = try c.decodeIfPresent(Float.self, forKey: .placementPan) ?? placementPan
        placementWidth = try c.decodeIfPresent(Float.self, forKey: .placementWidth) ?? placementWidth
        tranceGateEnabled = try c.decodeIfPresent(Bool.self, forKey: .tranceGateEnabled) ?? tranceGateEnabled
        tranceGateRateHz = try c.decodeIfPresent(Float.self, forKey: .tranceGateRateHz) ?? tranceGateRateHz
        tranceGateDepth = try c.decodeIfPresent(Float.self, forKey: .tranceGateDepth) ?? tranceGateDepth
        tranceGateSmoothingMs = try c.decodeIfPresent(Float.self, forKey: .tranceGateSmoothingMs) ?? tranceGateSmoothingMs
        tranceGatePattern = try c.decodeIfPresent([Bool].self, forKey: .tranceGatePattern) ?? tranceGatePattern
        tranceGateStereoOffset = try c.decodeIfPresent(Int.self, forKey: .tranceGateStereoOffset) ?? tranceGateStereoOffset
        parameterLanes = try c.decodeIfPresent([String: AutomationLane].self, forKey: .parameterLanes) ?? parameterLanes
        // A document written before the chain was reorderable has no order at
        // all; `completed` turns that into the sequence it used to run in.
        storedChainOrder = EffectSlot.completed(
            try c.decodeIfPresent([EffectSlot].self, forKey: .storedChainOrder) ?? [])
        // Absent in every document written before membership was recorded;
        // `devices` answers that case from the enabled flags.
        storedDevices = try c.decodeIfPresent(Set<EffectSlot>.self, forKey: .storedDevices)
    }
}

#endif  // !os(watchOS)
