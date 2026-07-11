//
//  EffectsBaker.swift
//  SwiftPaulStretch
//
//  Offline (faster-than-realtime, headless-safe) effect baking via
//  AVAudioEngine manual rendering — the export half of the
//  what-you-hear-is-what-you-export pattern.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// Bakes the ``EffectChain`` into a buffer offline.
///
/// Uses `AVAudioEngine` manual rendering, so it runs faster than realtime
/// and needs no audio hardware (it works in headless processes and tests).
/// A decay tail is appended when reverb or delay is active so their tails
/// aren't clipped.
public enum EffectsBaker {

    /// The tail appended for reverb/delay decays, in seconds.
    public static let tailSeconds = 4.0

    /// Returns `input` with `effects` baked in.
    ///
    /// With no effects enabled the input is returned untouched. The shimmer
    /// reverb (the library's own DSP — see ``ShimmerReverb``) runs first and
    /// appends its own ring-out; the stock chain then adds ``tailSeconds``
    /// when reverb or delay is active. If the offline engine cannot be set
    /// up, the (shimmered) dry input is returned rather than throwing
    /// mid-export.
    ///
    /// - Parameters:
    ///   - input: The dry audio.
    ///   - effects: The effect settings to bake.
    /// - Returns: The wet audio.
    public static func bake(_ input: StereoBuffer, effects fx: EffectsParameters) -> StereoBuffer {
        guard fx.isAnyEnabled, input.frameCount > 0 else { return input }
        let sr = input.sampleRate

        // Shimmer first: its haloed output feeds the stock chain, so a
        // cathedral on top smooths the octave bloom.
        var working = input
        if fx.shimmerEnabled {
            let shimmer = ShimmerReverb(sampleRate: sr, parameters: fx)
            let wet = shimmer.process(l: input.l, r: input.r)
            let ring = shimmer.tail()
            working = StereoBuffer(l: wet.l + ring.l, r: wet.r + ring.r, sampleRate: sr)
        }
        let stockActive = fx.reverbEnabled || fx.eqEnabled || fx.filterEnabled || fx.delayEnabled
        guard stockActive else { return working }
        let input = working

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2),
              let inBuf = AudioFileIO.makePCMBuffer(input, format: format) else { return input }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let chain = EffectChain()
        chain.install(in: engine, from: player, to: engine.mainMixerNode, format: format)
        chain.apply(fx)

        let tail = AVAudioFrameCount((fx.reverbEnabled || fx.delayEnabled) ? sr * tailSeconds : 0)
        let total = AVAudioFrameCount(input.frameCount) + tail

        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            player.scheduleBuffer(inBuf, at: nil, options: [], completionHandler: nil)
            try engine.start()
            player.play()
        } catch {
            return input
        }

        guard let outChunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else {
            engine.stop(); return input
        }
        var outL = [Float](); outL.reserveCapacity(Int(total))
        var outR = [Float](); outR.reserveCapacity(Int(total))
        var rendered: AVAudioFrameCount = 0
        while rendered < total {
            let frames = min(4096, total - rendered)
            do {
                let status = try engine.renderOffline(frames, to: outChunk)
                guard status == .success else { break }
            } catch { break }
            let n = Int(outChunk.frameLength)
            if n == 0 { break }
            if let ch = outChunk.floatChannelData {
                outL.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
                outR.append(contentsOf: UnsafeBufferPointer(start: ch[1], count: n))
            }
            rendered += outChunk.frameLength
        }
        engine.stop()
        if outL.isEmpty { return input }
        return StereoBuffer(l: outL, r: outR, sampleRate: sr)
    }
}

#endif  // !os(watchOS)
