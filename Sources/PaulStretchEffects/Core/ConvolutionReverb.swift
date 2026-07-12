//
//  ConvolutionReverb.swift
//  SwiftPaulStretch
//
//  Convolution reverb over algorithmically-generated impulse responses:
//  four IR characters (plate/hall/cathedral/exponential wash) with a real
//  decay-time control — the reverb ambient actually needs. Seeded, so
//  renders stay deterministic.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// Convolution reverb with algorithmic impulse responses.
///
/// Unlike the stock reverb's fixed spaces, the impulse response is
/// *generated* from a ``ReverbProfile`` — pre-delay, decay-curve exponent,
/// brightness (one-pole low-pass on the noise field), a dedicated
/// slow-decaying low-frequency layer, and early-reflection density — with a
/// free **decay time** up to 30 seconds. Left and right draw independent
/// noise streams, giving natural per-sample stereo decorrelation.
///
/// The convolution itself runs in uniform FFT partitions, so it streams:
/// state carries across ``process(l:r:)`` calls and ``tail()`` drains the
/// full IR-length ring-out. IR noise comes from a seeded generator, keeping
/// the library's everything-is-reproducible guarantee.
public final class ConvolutionReverb: PureStage {

    /// The largest decay the generator will build, in seconds.
    public static let maxDecaySeconds = 30.0

    private let sampleRate: Double
    private let wet: Float
    private let dry: Float
    private let mixLane: AutomationLane?
    private let totalFrames: Int?
    private let irFrames: Int

    private let convL: PartitionedConvolver?
    private let convR: PartitionedConvolver?
    private let blockSize = 4096
    /// Dry frames awaiting convolution (always < blockSize after process).
    private var bufferedL: [Float] = []
    private var bufferedR: [Float] = []
    /// Dry frames received but not yet emitted (waiting for their wet).
    private var dryPendingL: [Float] = []
    private var dryPendingR: [Float] = []
    /// Wet frames from completed blocks, not yet emitted. `wetBase` is the
    /// absolute frame index of `wetL[0]` — consumed prefixes are trimmed so
    /// memory stays bounded regardless of stream length.
    private var wetL: [Float] = []
    private var wetR: [Float] = []
    private var wetBase = 0
    private var emitted = 0

    /// Creates a convolution reverb.
    ///
    /// - Parameters:
    ///   - sampleRate: The stream's sample rate, in hertz.
    ///   - profile: The impulse-response character.
    ///   - decaySeconds: The reverb decay (`0.1…30 s`).
    ///   - mix: Wet/dry mix, `0…100`.
    ///   - mixLane: Optional mix automation (absolute `0…1` → 0–100 % wet).
    ///   - totalFrames: The full dry length (the lane's time base).
    ///   - seed: The IR noise seed — same seed, same room, every render.
    public init(sampleRate: Double,
                profile: ReverbProfile,
                decaySeconds: Double,
                mix: Float,
                mixLane: AutomationLane? = nil,
                totalFrames: Int? = nil,
                seed: UInt64 = 0x1B5E_EDED_C0FF_EE42) {
        self.sampleRate = sampleRate
        let m = min(max(mix, 0), 100) / 100
        self.wet = m
        self.dry = 1 - m
        self.mixLane = mixLane
        self.totalFrames = totalFrames

        let (irL, irR) = Self.makeImpulseResponse(profile: profile,
                                                  decaySeconds: min(max(decaySeconds, 0.1), Self.maxDecaySeconds),
                                                  sampleRate: sampleRate,
                                                  seed: seed)
        self.irFrames = irL.count
        self.convL = PartitionedConvolver(impulse: irL, blockSize: blockSize)
        self.convR = PartitionedConvolver(impulse: irR, blockSize: blockSize)
    }

    // MARK: - IR generation

    private struct Profile {
        let preDelay: Double            // silence before the wash, seconds
        let decayCurve: Double          // exponent on (1−t)^c
        let brightness: Double          // one-pole LP coefficient on the noise
        let lowBoost: Double            // dedicated low layer amount
        let earlyReflectionsDensity: Double
    }

    private static func profileTable(_ p: ReverbProfile) -> Profile {
        switch p {
        case .plate:
            return Profile(preDelay: 0.0, decayCurve: 3.2, brightness: 0.92,
                           lowBoost: 0.0, earlyReflectionsDensity: 0.6)
        case .hall:
            return Profile(preDelay: 0.035, decayCurve: 1.8, brightness: 0.62,
                           lowBoost: 0.25, earlyReflectionsDensity: 0.25)
        case .cathedral:
            return Profile(preDelay: 0.08, decayCurve: 1.2, brightness: 0.4,
                           lowBoost: 0.55, earlyReflectionsDensity: 0.15)
        case .exponential:
            // Handled separately (pure exponential-approach wash).
            return Profile(preDelay: 0.01, decayCurve: 0, brightness: 1,
                           lowBoost: 0, earlyReflectionsDensity: 0)
        }
    }

    /// The exponential profile's envelope: `exp(-dt/τ)` with
    /// `τ = ln(decay+1)/ln(200)`, held to 90 % of the decay then ramped
    /// linearly to zero so the tail closes cleanly.
    static func exponentialEnvelope(dt: Double, decay: Double) -> Double {
        let d = max(0.001, decay)
        if dt <= 0 { return 1 }
        if dt >= d { return 0 }
        let tau = log(d + 1) / log(200.0)
        let hold = 0.9 * d
        if dt <= hold { return exp(-dt / tau) }
        let atHold = exp(-hold / tau)
        let f = (dt - hold) / max(1e-9, d - hold)
        return atHold * (1 - f)
    }

    /// Builds the stereo IR (independent noise per channel), peak-normalised
    /// to 0.9.
    static func makeImpulseResponse(profile: ReverbProfile,
                                    decaySeconds: Double,
                                    sampleRate sr: Double,
                                    seed: UInt64) -> (l: [Float], r: [Float]) {
        var rng = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        func noise() -> Double {
            rng ^= rng << 13
            rng ^= rng >> 7
            rng ^= rng << 17
            return Double(rng >> 11) * (2.0 / 9007199254740992.0) - 1.0
        }

        let p = profileTable(profile)
        let totalSec = max(0.05, decaySeconds + p.preDelay)
        let length = Int(sr * totalSec)
        let preFrames = Int(p.preDelay * sr)
        let decayFrames = max(1, length - preFrames)
        var channels: [[Float]] = []

        if profile == .exponential {
            for _ in 0..<2 {
                var data = [Float](repeating: 0, count: length)
                for i in preFrames..<length {
                    let dt = Double(i - preFrames) / sr
                    data[i] = Float(noise() * exponentialEnvelope(dt: dt, decay: decaySeconds))
                }
                channels.append(data)
            }
        } else {
            // Early reflections scatter within the first 250 ms after pre-delay.
            let erWindow = min(Int(0.25 * sr), decayFrames)
            let erCount = Int(p.earlyReflectionsDensity * 60)
            // Deep low-pass for the dedicated low layer (~180 Hz corner) with
            // makeup gain so lowBoost has audible weight.
            let lowAlpha = 1 - exp(-2 * Double.pi * 180 / sr)
            let lowMakeupGain = 3.0

            for _ in 0..<2 {
                var data = [Float](repeating: 0, count: length)
                var lpState = 0.0
                var lowState = 0.0
                for i in preFrames..<length {
                    let t = Double(i - preFrames) / Double(decayFrames)
                    let env = pow(1 - t, p.decayCurve)
                    lpState = p.brightness * noise() + (1 - p.brightness) * lpState
                    var lowLayer = 0.0
                    if p.lowBoost > 0 {
                        lowState = lowAlpha * noise() + (1 - lowAlpha) * lowState
                        let lowEnv = pow(1 - t, p.decayCurve * 0.45)
                        lowLayer = lowState * lowEnv * p.lowBoost * lowMakeupGain
                    }
                    data[i] = Float(lpState * env + lowLayer)
                }
                for _ in 0..<erCount {
                    let pos = preFrames + Int(noise().magnitude * Double(max(1, erWindow - 1)))
                    if pos >= length { continue }
                    let localT = Double(pos - preFrames) / Double(max(1, erWindow))
                    let erEnv = pow(1 - localT, 1.5) * 0.5
                    data[pos] += Float(noise() * erEnv)
                }
                channels.append(data)
            }
        }

        // Peak-normalise to 0.9 across both channels.
        var peak: Float = 0
        for ch in channels { for v in ch { peak = max(peak, abs(v)) } }
        if peak > 0 {
            let gain = 0.9 / peak
            for c in 0..<channels.count {
                for i in 0..<channels[c].count { channels[c][i] *= gain }
            }
        }
        return (channels[0], channels[1])
    }

    // MARK: - Streaming

    /// Mixes and emits `count` finalised frames from the queues.
    private func emitFrames(_ count: Int) -> (l: [Float], r: [Float]) {
        var outL = [Float](repeating: 0, count: count)
        var outR = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let frame = emitted + i
            var w = wet
            var d = dry
            if let lane = mixLane, let total = totalFrames, total > 1 {
                let v = Float(lane.value(at: Double(min(frame, total - 1)) / Double(total - 1)))
                w = min(max(v, 0), 1)
                d = 1 - w
            }
            let idx = frame - wetBase
            outL[i] = dryPendingL[i] * d + wetL[idx] * w
            outR[i] = dryPendingR[i] * d + wetR[idx] * w
        }
        dryPendingL.removeFirst(count)
        dryPendingR.removeFirst(count)
        emitted += count
        let drop = min(emitted - wetBase, wetL.count)
        if drop > 0 {
            wetL.removeFirst(drop)
            wetR.removeFirst(drop)
            wetBase += drop
        }
        return (outL, outR)
    }

    /// Feeds a chunk and returns the frames **finalised** so far — up to one
    /// convolution block behind the input (the remainder arrives with the
    /// next call or ``tail()``). Emission depends only on cumulative counts,
    /// so any chunking produces bit-identical output.
    public func process(l: [Float], r: [Float]) -> (l: [Float], r: [Float]) {
        let n = min(l.count, r.count)
        guard let convL, let convR, n > 0 else { return (l: l, r: r) }
        bufferedL.append(contentsOf: l[0..<n])
        bufferedR.append(contentsOf: r[0..<n])
        dryPendingL.append(contentsOf: l[0..<n])
        dryPendingR.append(contentsOf: r[0..<n])

        // Convolve every full block that's ready.
        while bufferedL.count >= blockSize {
            wetL.append(contentsOf: convL.processBlock(Array(bufferedL[0..<blockSize])))
            wetR.append(contentsOf: convR.processBlock(Array(bufferedR[0..<blockSize])))
            bufferedL.removeFirst(blockSize)
            bufferedR.removeFirst(blockSize)
        }

        // Emit everything whose wet is final.
        let available = (wetBase + wetL.count) - emitted
        guard available > 0 else { return (l: [], r: []) }
        return emitFrames(available)
    }

    /// Flushes the withheld remainder (dry + wet) and the IR-length
    /// ring-out. Call once, after the last ``process(l:r:)``.
    public func tail() -> (l: [Float], r: [Float]) {
        guard let convL, let convR else { return ([], []) }
        let remainder = dryPendingL.count
        let target = emitted + remainder + irFrames
        while wetBase + wetL.count < target {
            var blockL = bufferedL
            var blockR = bufferedR
            bufferedL.removeAll(keepingCapacity: true)
            bufferedR.removeAll(keepingCapacity: true)
            if blockL.count < blockSize {
                blockL.append(contentsOf: [Float](repeating: 0, count: blockSize - blockL.count))
                blockR.append(contentsOf: [Float](repeating: 0, count: blockSize - blockR.count))
            }
            wetL.append(contentsOf: convL.processBlock(blockL))
            wetR.append(contentsOf: convR.processBlock(blockR))
        }
        // The withheld dry remainder first…
        var head: (l: [Float], r: [Float]) = (l: [], r: [])
        if remainder > 0 { head = emitFrames(remainder) }
        // …then the pure-wet ring-out at the lane's final mix level.
        var w = wet
        if let lane = mixLane, let total = totalFrames, total > 1 {
            w = min(max(Float(lane.value(at: 1)), 0), 1)
        }
        var ringL = [Float](repeating: 0, count: irFrames)
        var ringR = [Float](repeating: 0, count: irFrames)
        for i in 0..<irFrames {
            let idx = emitted + i - wetBase
            if idx >= 0 && idx < wetL.count {
                ringL[i] = wetL[idx] * w
                ringR[i] = wetR[idx] * w
            }
        }
        emitted = target
        return (l: head.l + ringL, r: head.r + ringR)
    }
}

#endif  // !os(watchOS)
