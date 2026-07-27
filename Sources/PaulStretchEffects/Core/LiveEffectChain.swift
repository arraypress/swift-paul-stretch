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
    private var lock = os_unfair_lock()

    /// Finished audio waiting to be served, absorbing the mismatch between
    /// what a block-based stage emits and the quantum the host asks for.
    private var queueL: [Float] = []
    private var queueR: [Float] = []

    /// `true` when no stage is active, so the host can skip the node.
    public private(set) var isEmpty: Bool

    /// Creates a live chain for `effects`.
    ///
    /// - Parameters:
    ///   - sampleRate: The stream's sample rate, in hertz.
    ///   - effects: The initial settings.
    public init(sampleRate: Double, effects: EffectsParameters) {
        self.sampleRate = sampleRate
        // `totalFrames: nil` — automation lanes are a render-length concept
        // and there is no known length when playing live.
        self.stages = makePureStages(sampleRate: sampleRate, effects: effects, totalFrames: nil)
        self.isEmpty = stages.isEmpty
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
        pendingStages = built
        os_unfair_lock_unlock(&lock)
        isEmpty = built.isEmpty
    }

    /// Processes one quantum in place. **Audio thread only.**
    ///
    /// - Parameters:
    ///   - l: Left channel, modified in place.
    ///   - r: Right channel, modified in place.
    public func render(l: inout [Float], r: inout [Float]) {
        // Non-blocking pickup: if the writer holds the lock we keep the
        // current chain and try again next quantum.
        if os_unfair_lock_trylock(&lock) {
            if let p = pendingStages { stages = p; pendingStages = nil }
            os_unfair_lock_unlock(&lock)
        }
        guard !stages.isEmpty else { return }

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
