//
//  SessionRenderer.swift
//  SwiftPaulStretch
//
//  The deterministic session bounce: render each clip's voice (cacheable),
//  place clips on the timeline (tiling, trims, fades, gains), apply track
//  channels and lanes, sum, and run the master stack.
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
    /// A clip's audio reference didn't resolve (bad bytes, missing file).
    case unresolvableAudio(clipName: String)
    /// A generative render was cancelled or produced nothing.
    case emptyRender(clipName: String)
}

/// Renders ``Session``s: per-clip voices (cacheable — everything is
/// deterministic) and the full timeline bounce.
public enum SessionRenderer {

    /// The automation-lane evaluation stride for placement, in frames.
    /// Ambient lanes move over tens of seconds; ~23 ms steps are inaudible
    /// and keep hour-long bounces cheap.
    static let laneBlockFrames = 1024

    // MARK: - Voices

    /// Renders one clip's voice: source resolved, engine run (for
    /// generative clips), the owning track's channel strip baked.
    ///
    /// Voices are *placement-independent* — position, length, trim, fades
    /// and gains apply at placement — so dragging or trimming a clip never
    /// re-renders. Cache against ``voiceCacheKey(for:trackStack:sampleRate:)``.
    ///
    /// - Parameters:
    ///   - clip: The clip whose voice to render.
    ///   - trackStack: The owning track's channel strip.
    ///   - sampleRate: The session sample rate, in hertz.
    ///   - isCancelled: Polled during generative renders; return `true` to
    ///     abandon.
    /// - Returns: The voice audio.
    /// - Throws: ``SessionRenderError`` when the source doesn't resolve or
    ///   the render comes back empty.
    public static func renderVoice(for clip: Clip,
                                   trackStack: EffectStack = EffectStack(),
                                   sampleRate: Double,
                                   isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> StereoBuffer {
        guard let source = clip.source.audio.resolve(sampleRate: sampleRate) else {
            throw SessionRenderError.unresolvableAudio(clipName: clip.name)
        }
        var voice: StereoBuffer
        switch clip.source {
        case .sample(let s):
            voice = source
            if clip.fillsWithLoop && s.seamlessLoop {
                voice = voice.seamlesslyLooped()
            }
        case .generative(let g):
            var params = g.parameters
            params.seamlessLoop = clip.fillsWithLoop   // loop seam handled by the engine
            voice = StretchRenderer.render(source, parameters: params, seed: g.seed,
                                           isCancelled: isCancelled)
            if voice.isEmpty {
                throw SessionRenderError.emptyRender(clipName: clip.name)
            }
        }
        return EffectStackBaker.bake(voice, stack: trackStack)
    }

    /// A cache key for ``renderVoice(for:trackStack:sampleRate:)`` output:
    /// it changes exactly when the rendered voice would (source, engine
    /// settings, seed, loop treatment, the track's strip — never placement,
    /// trims, fades or gains).
    ///
    /// Compare within a single process only (embedded bytes fold in via
    /// `hashValue`).
    ///
    /// - Parameters:
    ///   - clip: The clip.
    ///   - trackStack: The owning track's channel strip.
    ///   - sampleRate: The session sample rate, in hertz.
    /// - Returns: The key.
    public static func voiceCacheKey(for clip: Clip,
                                     trackStack: EffectStack = EffectStack(),
                                     sampleRate: Double) -> String {
        var key = "sr:\(sampleRate)|fills:\(clip.fillsWithLoop)"
        let audio = clip.source.audio
        key += "|audio:\(audio.path ?? ""),\(audio.data?.count ?? -1),\(audio.data?.hashValue ?? 0)"
        switch clip.source {
        case .sample(let s):
            key += "|sample:\(s.seamlessLoop)"
        case .generative(let g):
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let params = (try? encoder.encode(g.parameters)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            key += "|gen:\(g.seed);\(params)"
        }
        return key + "|stack:\(trackStack.signature)"
    }

    // MARK: - Bounce

    /// Bounces the whole session to a buffer.
    ///
    /// Deterministic: the same session renders the identical file every
    /// time. Pass pre-rendered voices (keyed by clip `id`) to skip the
    /// per-clip render — the host's cache layer; any clip missing from the
    /// dictionary is rendered here.
    ///
    /// - Parameters:
    ///   - session: The session to bounce.
    ///   - voices: Optional pre-rendered voices by clip `id`.
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

        let audible = session.tracks.filter { session.isAudible($0) && !$0.clips.isEmpty }
        for (index, track) in audible.enumerated() {
            if isCancelled() { return StereoBuffer(l: [], r: [], sampleRate: sr) }

            // Clips accumulate into the track bus, then the channel
            // (gain/pan + lanes) applies while summing into the mix.
            var busL = [Float](repeating: 0, count: frames)
            var busR = [Float](repeating: 0, count: frames)
            for clip in track.clips {
                let voice = try voices[clip.id]
                    ?? renderVoice(for: clip, trackStack: track.stack, sampleRate: sr,
                                   isCancelled: isCancelled)
                place(clip, voice: voice, into: &busL, &busR, sampleRate: sr)
            }
            applyChannel(track, bus: busL, busR, into: &mixL, &mixR)
            progress?(Double(index + 1) / Double(audible.count + 1))
        }

        if isCancelled() { return StereoBuffer(l: [], r: [], sampleRate: sr) }
        var mix = StereoBuffer(l: mixL, r: mixR, sampleRate: sr)
        mix = EffectStackBaker.bake(mix, stack: session.master)
        progress?(1)
        return mix
    }

    // MARK: - Placement

    /// Places one clip onto a track bus: entry point, voice tiling (or
    /// one-shot), left-trim offset, clip gain, linear edge fades.
    static func place(_ clip: Clip, voice: StereoBuffer,
                      into busL: inout [Float], _ busR: inout [Float],
                      sampleRate sr: Double) {
        let frames = busL.count
        let voiceLen = voice.frameCount
        guard voiceLen > 0, frames > 0, clip.durationSeconds > 0 else { return }

        let startFrame = Int(clip.startSeconds * sr)
        let clipFrames = Int(clip.durationSeconds * sr)
        let offsetFrames = max(0, Int(clip.offsetSeconds * sr))
        let fadeInFrames = max(0, Int(clip.fadeInSeconds * sr))
        let fadeOutFrames = max(0, Int(clip.fadeOutSeconds * sr))

        let first = max(0, startFrame)
        let last = min(frames, startFrame + clipFrames)
        guard first < last else { return }

        for n in first..<last {
            let posInClip = n - startFrame
            var local = posInClip + offsetFrames
            if clip.fillsWithLoop {
                local %= voiceLen
            } else if local >= voiceLen {
                break
            }
            var g = clip.gain
            if fadeInFrames > 0 && posInClip < fadeInFrames {
                g *= Float(posInClip) / Float(fadeInFrames)
            }
            let fromEnd = clipFrames - posInClip
            if fadeOutFrames > 0 && fromEnd < fadeOutFrames {
                g *= Float(fromEnd) / Float(fadeOutFrames)
            }
            busL[n] += voice.l[local] * g
            busR[n] += voice.r[local] * g
        }
    }

    /// Applies a track's channel — gain/pan and their session-time lanes,
    /// evaluated per block — while summing the bus into the mix.
    static func applyChannel(_ track: Track,
                             bus busL: [Float], _ busR: [Float],
                             into mixL: inout [Float], _ mixR: inout [Float]) {
        let frames = mixL.count
        var n = 0
        while n < frames {
            let blockEnd = min(frames, n + laneBlockFrames)
            let t = Double(n) / Double(max(1, frames - 1))
            let gain = track.gain * Float(track.gainLane?.value(at: t) ?? 1)
            let pan = track.panLane.map { Float($0.value(at: t)) * 2 - 1 } ?? track.pan
            let (gL, gR) = balanceGains(pan: pan)
            for i in n..<blockEnd {
                mixL[i] += busL[i] * gain * gL
                mixR[i] += busR[i] * gain * gR
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
}

#endif  // !os(watchOS)
