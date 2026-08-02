//
//  LiveEffectChain.swift
//  SwiftPaulStretch
//
//  The library's own DSP (shimmer, convolution reverb, sweep filter, wow,
//  pump, auto-pan) running in a realtime render callback instead of being
//  baked into the playback buffer.
//
//  Created by David Sherlock on 7/27/26.
//

import Foundation
import PaulStretch
import os.lock

#if !os(watchOS)

/// Runs the pure-DSP stages live, so their parameters can be tweaked while
/// audio plays instead of forcing a re-bake of the whole render.
///
/// ### Why this can exist
///
/// These stages were baked because ``ShimmerReverb`` is a feedback loop and
/// an `AVAudioEngine` graph cannot contain cycles. That constraint applies
/// to the *graph*, not to DSP inside a single node: a feedback loop kept
/// entirely within one render callback is just an algorithm with state.
///
/// Measured per 512-frame quantum (11.6 ms budget) on an M3 Pro: wow 0.07 ms,
/// sweep 0.06, pump+pan 0.03, shimmer 0.35, convolution 1.06 — about 1.6 ms
/// worst case for all six, or 13 % of budget.
///
/// ### Realtime discipline
///
/// ``render(l:r:)`` is called from the audio thread and must not block. Two
/// rules follow, and both are load-bearing:
///
/// - **Parameter changes never block the audio thread.** ``setEffects(_:)``
///   builds the replacement chain on the *calling* thread and publishes it;
///   the render callback picks it up with a `try`-lock and simply keeps the
///   current chain if it loses the race. A missed swap costs one quantum of
///   staleness (11 ms), where blocking would cost a dropout.
/// - **Rebuilds are not free musically.** A new chain starts with empty
///   delay lines, so a live parameter change truncates reverb tails. The
///   host should cross-fade over a swap rather than cutting to it.
///
/// ### Known compromise: the stages still allocate
///
/// ``PureStage/process(l:r:)`` takes and returns `[Float]`, so each stage
/// allocates its output array every call. Strict realtime practice forbids
/// allocation in a render callback, because `malloc` can take a lock and a
/// blocked audio thread is a dropout.
///
/// This is knowingly accepted for now: the allocations are small, fixed-size
/// and hit the allocator's fast path, and the whole chain measures ~1.6 ms
/// against an 11.6 ms budget. Removing it means giving every stage a
/// write-into-caller-buffer variant — worth doing, but it is a rewrite of
/// six stage classes and buys headroom that is not currently scarce. If
/// dropouts ever appear under load, this is the first thing to fix.
public final class LiveEffectChain {

    private let sampleRate: Double
    /// The chain the audio thread is currently using. Audio-thread only.
    private var stages: [PureStage]
    /// A replacement published by ``setEffects(_:)``, consumed by the next
    /// render. Guarded by ``lock``.
    private var pendingStages: [PureStage]?
    /// New continuous parameter values published by ``updateParameters(_:)``,
    /// applied to the LIVE stages by the next render without rebuilding them.
    /// Guarded by ``lock``.
    private var pendingParams: EffectsParameters?
    /// The chain (and any consumed parameter struct) the render callback just
    /// swapped OUT. Freed by the next writer-thread call, never by the render
    /// callback: a convolver holds megabytes of partition spectra and an FFT
    /// setup, and `free` can take a lock — releasing the outgoing chain inside
    /// the callback was an audio-thread hazard. Guarded by ``lock``.
    private var retiredStages: [PureStage]?
    private var retiredParams: EffectsParameters?
    private var lock = os_unfair_lock()

    /// Finished audio waiting to be served, absorbing the mismatch between
    /// what a block-based stage emits and the quantum the host asks for.
    private var queueL: [Float] = []
    private var queueR: [Float] = []

    /// `true` when no stage is active, so the host can skip the node.
    public private(set) var isEmpty: Bool

    /// Frames of latency the chain's queueing introduces, for the host to
    /// report (see `LiveEffectAudioUnit.latency`).
    ///
    /// Only the convolver withholds audio: it buffers input until it has a
    /// full FFT partition, so a chain containing one runs up to a block
    /// late and the queue below serves silence while it fills. Every other
    /// stage returns frame for frame. The value is conservative (the worst
    /// case; the true lag is `block - queued` and varies with the quantum),
    /// which is the right direction for a host aligning layers.
    ///
    /// Must match `ConvolutionReverb.blockSize`, which is private — if that
    /// block size ever changes, change this with it.
    public private(set) var latencyFrames: Int

    private static let convolverBlockSize = 4096

    private static func latency(of stages: [PureStage]) -> Int {
        stages.contains { $0 is ConvolutionReverb } ? convolverBlockSize : 0
    }

    /// Creates a live chain for `effects`.
    ///
    /// - Parameters:
    ///   - sampleRate: The stream's sample rate, in hertz.
    ///   - effects: The initial settings.
    public init(sampleRate: Double, effects: EffectsParameters) {
        self.sampleRate = sampleRate
        // `totalFrames: nil` — automation lanes are a render-length concept
        // and there is no known length when playing live.
        let built = makePureStages(sampleRate: sampleRate, effects: effects, totalFrames: nil)
        self.stages = built
        self.isEmpty = built.isEmpty
        self.latencyFrames = LiveEffectChain.latency(of: built)
    }

    /// Publishes new settings. Safe to call from the main thread while audio
    /// runs; the swap happens on the next render callback.
    ///
    /// Stage *construction* — the expensive part, which builds delay lines
    /// and convolver partitions — happens here on the calling thread rather
    /// than in the render callback.
    ///
    /// - Parameter fx: The settings to apply.
    public func setEffects(_ fx: EffectsParameters) {
        let built = makePureStages(sampleRate: sampleRate, effects: fx, totalFrames: nil)
        os_unfair_lock_lock(&lock)
        let trash = retiredStages
        let trashParams = retiredParams
        retiredStages = nil
        retiredParams = nil
        pendingStages = built
        pendingParams = nil
        os_unfair_lock_unlock(&lock)
        // The chain the render callback swapped out dies HERE, on the calling
        // thread — see `retiredStages`.
        _ = trash
        _ = trashParams
        isEmpty = built.isEmpty
        // Reported, not applied: the AU reads this when its render
        // resources are (re)allocated, so a swap that adds or removes the
        // convolver mid-render is not reflected until the engine restarts.
        latencyFrames = LiveEffectChain.latency(of: built)
    }

    /// Publishes new continuous parameter values for the RUNNING stages.
    ///
    /// Unlike ``setEffects(_:)`` this does not rebuild anything: each live
    /// stage retunes in place, keeping its delay lines and tails. The pure-DSP
    /// stages had no path like this at all, so an automated shimmer mix or a
    /// dragged pitch knob rebuilt the whole chain — tails truncated, convolver
    /// partitions recomputed, thirty times a second under automation.
    ///
    /// Only continuous parameters take effect; if a STRUCTURAL setting changed
    /// (compare ``EffectsParameters/pureDSPStructureSignature``), call
    /// ``setEffects(_:)`` instead.
    ///
    /// - Parameter fx: The settings to retune to.
    public func updateParameters(_ fx: EffectsParameters) {
        os_unfair_lock_lock(&lock)
        let trash = retiredStages
        let trashParams = retiredParams
        retiredStages = nil
        retiredParams = nil
        // A pending rebuild supersedes a retune — the freshly built stages
        // were made from at-least-as-new settings.
        if pendingStages == nil { pendingParams = fx }
        os_unfair_lock_unlock(&lock)
        _ = trash
        _ = trashParams
    }

    /// Processes one quantum in place. **Audio thread only.**
    ///
    /// - Parameters:
    ///   - l: Left channel, modified in place.
    ///   - r: Right channel, modified in place.
    public func render(l: inout [Float], r: inout [Float]) {
        // Non-blocking pickup: if the writer holds the lock we keep the
        // current chain and try again next quantum. Whatever gets swapped out
        // parks in the retired slots for the writer thread to free — nothing
        // is deallocated here.
        if os_unfair_lock_trylock(&lock) {
            if let p = pendingStages {
                retiredStages = stages
                stages = p
                pendingStages = nil
            } else if let fx = pendingParams {
                for stage in stages { stage.update(from: fx) }
                retiredParams = pendingParams
                pendingParams = nil
            }
            os_unfair_lock_unlock(&lock)
        }
        guard !stages.isEmpty else { return }

        // Scrub non-finite input before it reaches any stage. A single NaN
        // or Inf sample latches every piece of recirculating state it
        // touches — the shimmer tank, the SVF integrators, the convolver's
        // frequency-domain delay line — into permanent NaN until the chain
        // is rebuilt, so one upstream glitch silences the effect forever.
        // Cost: one `isFinite` test per sample over two arrays (~1k
        // compares per 512-frame quantum), no allocation — noise next to
        // the stages themselves, and cheap insurance against a poisoned
        // chain.
        for i in 0..<l.count where !l[i].isFinite { l[i] = 0 }
        for i in 0..<r.count where !r[i].isFinite { r[i] = 0 }

        var cl = l, cr = r
        for stage in stages {
            let out = stage.process(l: cl, r: cr)
            cl = out.l
            cr = out.r
        }

        // A stage need not return as many frames as it was given — the
        // convolver withholds input until it has a whole block, then emits
        // two blocks at once. Padding those short returns with silence turns
        // the effect into a gate (this shipped once and sounded like a trance
        // gate), so instead the output is queued and the quantum is served
        // from the queue. The chain runs one block behind, which is latency,
        // not a gap.
        queueL.append(contentsOf: cl)
        queueR.append(contentsOf: cr)

        let n = l.count
        guard queueL.count >= n else {
            // Priming only: the first few quanta before the convolver has
            // filled its first block. Nothing is dropped, just deferred.
            for i in 0..<n { l[i] = 0; r[i] = 0 }
            return
        }
        for i in 0..<n { l[i] = queueL[i]; r[i] = queueR[i] }
        queueL.removeFirst(n)
        queueR.removeFirst(n)
    }
}

#endif  // !os(watchOS)
