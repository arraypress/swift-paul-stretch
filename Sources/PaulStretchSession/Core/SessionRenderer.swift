//
//  SessionRenderer.swift
//  SwiftPaulStretch
//
//  The deterministic session bounce: resolve each track's voice, bake its
//  stack, place/loop it on the timeline with lanes and pan law, sum, and
//  run the master stack.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import PaulStretch
import PaulStretchEffects

// This product builds on PaulStretchEffects, which compiles to an empty
// module on watchOS.
#if !os(watchOS)

/// Errors thrown while rendering a session.
public enum SessionRenderError: Error, Sendable {
    /// A track's audio reference didn't resolve (bad bytes, missing file).
    case unresolvableAudio(trackName: String)
    /// A generative render was cancelled or produced nothing.
    case emptyRender(trackName: String)
}

/// Renders ``Session``s: per-track voices (cacheable — everything is
/// deterministic) and the full timeline bounce.
public enum SessionRenderer {

    /// The automation-lane evaluation stride for placement, in frames.
    /// Ambient lanes move over tens of seconds; ~23 ms steps are inaudible
    /// and keep hour-long bounces cheap.
    static let laneBlockFrames = 1024

    // MARK: - Voices

    /// Renders one track's voice: source resolved, engine run (for
    /// generative tracks), channel strip baked.
    ///
    /// Voices are *timeline-independent* — gain/pan and their lanes apply at
    /// placement — so a voice can be cached against
    /// ``voiceCacheKey(for:sampleRate:)`` and reused across edits that don't
    /// touch the source or the stack.
    ///
    /// - Parameters:
    ///   - track: The track whose voice to render.
    ///   - sampleRate: The session sample rate, in hertz.
    ///   - isCancelled: Polled during generative renders; return `true` to
    ///     abandon.
    /// - Returns: The voice audio.
    /// - Throws: ``SessionRenderError`` when the source doesn't resolve or
    ///   the render comes back empty.
    public static func renderVoice(for track: Track,
                                   sampleRate: Double,
                                   isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> StereoBuffer {
        guard let source = track.source.audio.resolve(sampleRate: sampleRate) else {
            throw SessionRenderError.unresolvableAudio(trackName: track.name)
        }
        var voice: StereoBuffer
        switch track.source {
        case .sample(let s):
            voice = source
            if track.loops && s.seamlessLoop {
                voice = voice.seamlesslyLooped()
            }
        case .generative(let g):
            var params = g.parameters
            params.seamlessLoop = track.loops    // loop seam handled by the engine
            voice = StretchRenderer.render(source, parameters: params, seed: g.seed,
                                           isCancelled: isCancelled)
            if voice.isEmpty {
                throw SessionRenderError.emptyRender(trackName: track.name)
            }
        }
        return EffectStackBaker.bake(voice, stack: track.stack)
    }

    /// A cache key for ``renderVoice(for:sampleRate:)`` output: it changes
    /// exactly when the rendered voice would (source, engine settings, seed,
    /// loop treatment, stack — not mixer state or timeline position).
    ///
    /// Compare within a single process only (embedded bytes fold in via
    /// `hashValue`).
    ///
    /// - Parameters:
    ///   - track: The track.
    ///   - sampleRate: The session sample rate, in hertz.
    /// - Returns: The key.
    public static func voiceCacheKey(for track: Track, sampleRate: Double) -> String {
        var key = "sr:\(sampleRate)|loops:\(track.loops)"
        let audio = track.source.audio
        key += "|audio:\(audio.path ?? ""),\(audio.data?.count ?? -1),\(audio.data?.hashValue ?? 0)"
        switch track.source {
        case .sample(let s):
            key += "|sample:\(s.seamlessLoop)"
        case .generative(let g):
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let params = (try? encoder.encode(g.parameters)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            key += "|gen:\(g.seed);\(params)"
        }
        return key + "|stack:\(track.stack.signature)"
    }

    // MARK: - Bounce

    /// Bounces the whole session to a buffer.
    ///
    /// Deterministic: the same session renders the identical file every
    /// time. Pass pre-rendered voices (keyed by track `id`) to skip the
    /// per-track render — the host's cache layer; any track missing from
    /// the dictionary is rendered here.
    ///
    /// - Parameters:
    ///   - session: The session to bounce.
    ///   - voices: Optional pre-rendered voices by track `id`.
    ///   - isCancelled: Polled between stages; return `true` to abandon
    ///     (an empty buffer is returned).
    ///   - progress: Called with `0…1` as tracks complete.
    /// - Returns: The bounced mix (session length plus any master tail).
    /// - Throws: ``SessionRenderError`` from voice rendering.
    public static func render(_ session: Session,
                              voices: [UUID: StereoBuffer] = [:],
                              isCancelled: @escaping @Sendable () -> Bool = { false },
                              progress: (@Sendable (Double) -> Void)? = nil) throws -> StereoBuffer {
        let sr = session.sampleRate
        let frames = max(1, Int(session.durationSeconds * sr))
        var mixL = [Float](repeating: 0, count: frames)
        var mixR = [Float](repeating: 0, count: frames)

        let audible = session.tracks.filter { session.isAudible($0) }
        for (index, track) in audible.enumerated() {
            if isCancelled() { return StereoBuffer(l: [], r: [], sampleRate: sr) }
            let voice = try voices[track.id]
                ?? renderVoice(for: track, sampleRate: sr, isCancelled: isCancelled)
            place(voice, for: track, sessionSeconds: session.durationSeconds,
                  into: &mixL, &mixR)
            progress?(Double(index + 1) / Double(audible.count + 1))
        }

        if isCancelled() { return StereoBuffer(l: [], r: [], sampleRate: sr) }
        var mix = StereoBuffer(l: mixL, r: mixR, sampleRate: sr)
        mix = EffectStackBaker.bake(mix, stack: session.master)
        progress?(1)
        return mix
    }

    // MARK: - Placement

    /// Places a voice onto the timeline: entry point, looping with phase,
    /// gain/pan (and their session-time lanes, evaluated per block), summed
    /// into the mix.
    static func place(_ voice: StereoBuffer,
                      for track: Track,
                      sessionSeconds: Double,
                      into mixL: inout [Float], _ mixR: inout [Float]) {
        let frames = mixL.count
        let voiceLen = voice.frameCount
        guard voiceLen > 0, frames > 0 else { return }
        let sr = voice.sampleRate

        let startFrame = max(0, Int(track.startSeconds * sr))
        let phaseFrames = max(0, Int(track.loopPhaseSeconds * sr)) % voiceLen
        guard startFrame < frames else { return }

        var n = startFrame
        while n < frames {
            // One lane block: constant gain/pan, cheap inner loop.
            let blockEnd = min(frames, n + laneBlockFrames)
            let t = Double(n) / (Double(frames) - 1)
            let gain = track.gain * Float(laneValue(track.gainLane, at: t, fallback: 1))
            let pan = track.panLane.map { Float($0.value(at: t)) * 2 - 1 } ?? track.pan
            let (gL, gR) = Self.balanceGains(pan: pan)

            for i in n..<blockEnd {
                let rel = i - startFrame
                let local: Int
                if track.loops {
                    local = (rel + phaseFrames) % voiceLen
                } else {
                    local = rel + phaseFrames
                    if local >= voiceLen { return }
                }
                mixL[i] += voice.l[local] * gain * gL
                mixR[i] += voice.r[local] * gain * gR
            }
            n = blockEnd
        }
    }

    /// The stereo balance law shared with `AutoPan`: unity at centre, the
    /// far side attenuated on a cosine.
    static func balanceGains(pan: Float) -> (Float, Float) {
        let p = max(-1, min(1, pan))
        let attenuation = cosf(abs(p) * .pi / 2)
        return p >= 0 ? (attenuation, 1) : (1, attenuation)
    }

    @inline(__always)
    private static func laneValue(_ lane: AutomationLane?, at t: Double, fallback: Double) -> Double {
        lane?.value(at: t) ?? fallback
    }
}

#endif  // !os(watchOS)
