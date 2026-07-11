//
//  StretchSourceNode.swift
//  SwiftPaulStretch
//
//  Realtime playback: an AVAudioSourceNode that synthesises the render
//  timeline just in time — endless ambience with zero pre-render and a few
//  megabytes of memory.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation

/// Errors thrown by ``StretchSourceNode/prepare(source:parameters:seed:bufferSeconds:)``.
public enum StretchSourceNodeError: Error, Sendable {
    /// The source was empty (or too short to freeze) — there is no timeline
    /// to play.
    case nothingToRender
}

/// A realtime source node that plays a render **without rendering it
/// first** — the timeline is synthesised just-in-time on a background
/// thread while an `AVAudioSourceNode` plays it.
///
/// This is the zero-memory way to play ambience on iOS: no pre-rendered
/// buffer, no file, just a few seconds of lookahead in a ring buffer
/// (~2 MB). With ``StretchParameters/seamlessLoop`` enabled the node wraps
/// the loop-crossfaded timeline forever, so playback is endless. All three
/// engines work — PaulStretch, tape-slow and spectral freeze — because the
/// node plays the same deterministic timeline the offline renderers
/// produce, sample for sample.
///
/// ```swift
/// var params = StretchParameters()
/// params.targetSeconds = 120
/// params.seamlessLoop = true                      // wrap forever
/// let node = try await StretchSourceNode.prepare(source: source, parameters: params)
///
/// engine.attach(node.avAudioNode)
/// engine.connect(node.avAudioNode, to: engine.mainMixerNode, format: node.format)
/// try engine.start()                              // plays endlessly
/// ```
///
/// `prepare` runs the render plan's peak passes up front (instant for
/// tape-slow, a sweep of the timeline for the other modes), so keep loop
/// targets modest — a 1–2 minute loop prepares in well under a second on
/// modern hardware and repeats imperceptibly under the wash.
///
/// The synthesis thread stays a few seconds ahead of the playhead; if it
/// ever falls behind (it shouldn't — synthesis runs hundreds of times
/// faster than realtime) the callback plays silence for the shortfall and
/// counts it in ``underrunFrames`` rather than blocking the audio thread.
public final class StretchSourceNode {

    /// The node to attach and connect in your `AVAudioEngine`.
    public private(set) var avAudioNode: AVAudioSourceNode!

    /// The node's output format (stereo float at the source's sample rate).
    public let format: AVAudioFormat

    /// The length of one pass of the timeline, in frames.
    public let totalFrames: Int

    /// Whether the node wraps the timeline forever
    /// (``StretchParameters/seamlessLoop``) or plays it once then goes
    /// silent.
    public let loops: Bool

    /// Frames of silence emitted because the synthesiser fell behind.
    public var underrunFrames: Int { state.underrunFrames }

    /// The playback position within the current timeline pass, in seconds.
    public var playheadSeconds: Double {
        let frame = state.ring.framesRead
        let wrapped = loops ? frame % Int64(totalFrames) : min(frame, Int64(totalFrames))
        return Double(wrapped) / format.sampleRate
    }

    /// `true` once a non-looping node has synthesised and played its whole
    /// timeline.
    public var isFinished: Bool {
        !loops && state.producerDone && state.ring.availableFrames == 0
    }

    /// Shared with the producer thread and the render callback.
    private final class State {
        let ring: AudioRingBuffer
        var producerDone = false
        var stopped = false
        var underrunFrames = 0
        init(ring: AudioRingBuffer) { self.ring = ring }
    }

    private let state: State
    private let run: ChunkedRun
    private var producer: Thread?

    /// Builds a ready-to-attach node: resolves the render plan, runs its
    /// peak passes, pre-fills the lookahead buffer and starts the synthesis
    /// thread.
    ///
    /// - Parameters:
    ///   - source: The source audio.
    ///   - parameters: The render settings. Set
    ///     ``StretchParameters/seamlessLoop`` for endless playback.
    ///   - seed: The render seed. Defaults to ``PaulStretcher/defaultSeed``.
    ///   - bufferSeconds: The synthesis lookahead. Defaults to 4 s (~1.4 MB).
    /// - Returns: The prepared node, already buffering.
    /// - Throws: ``StretchSourceNodeError/nothingToRender`` for empty
    ///   sources; `CancellationError` if the preparing task is cancelled.
    public static func prepare(source: StereoBuffer,
                               parameters: StretchParameters,
                               seed: UInt64 = PaulStretcher.defaultSeed,
                               bufferSeconds: Double = 4) async throws -> StretchSourceNode {
        // Plan + peak passes off the cooperative pool, honouring Task
        // cancellation.
        let run: ChunkedRun = try await runCancellableRender { isCancelled in
            let plan = makeRenderPlan(source, parameters, seed: seed)
            if case .empty = plan.path { throw StretchSourceNodeError.nothingToRender }
            guard plan.finalFrames > 0 else { throw StretchSourceNodeError.nothingToRender }
            let run = ChunkedRun(plan: plan, progress: nil)
            guard run.computeGains(isCancelled: isCancelled) else { throw CancellationError() }
            return run
        }
        return StretchSourceNode(run: run, loops: parameters.seamlessLoop, bufferSeconds: bufferSeconds)
    }

    private init(run: ChunkedRun, loops: Bool, bufferSeconds: Double) {
        let sampleRate = run.plan.sampleRate
        self.run = run
        self.loops = loops
        self.totalFrames = run.plan.finalFrames
        self.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                    channels: 2, interleaved: false)!

        let capacity = Int(max(1, bufferSeconds) * sampleRate)
        let state = State(ring: AudioRingBuffer(capacityFrames: capacity))
        self.state = state

        // Synthesis granularity: small enough to keep the ring topped up
        // responsively, big enough to amortise per-range kernel setup.
        run.prepareDelivery(chunkFrames: min(1 << 16, max(4096, capacity / 4)))

        self.avAudioNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard abl.count >= 2,
                  let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let outR = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                return OSStatus(-50)   // paramErr (AudioToolbox is absent on watchOS)
            }
            let got = state.ring.read(intoL: outL, intoR: outR, count: frames)
            if got < frames {
                // Zero-fill the shortfall; never block the audio thread.
                for i in got..<frames { outL[i] = 0; outR[i] = 0 }
                if !state.producerDone { state.underrunFrames += frames - got }
            }
            return noErr
        }

        startProducer()
    }

    deinit {
        stop()
    }

    /// Stops the synthesis thread. The node keeps playing whatever is left
    /// in the lookahead buffer, then silence. Irreversible — prepare a new
    /// node to resume.
    public func stop() {
        state.stopped = true
    }

    /// Frames currently synthesised ahead of the playhead.
    public var bufferedFrames: Int {
        state.ring.availableFrames
    }

    /// Fraction of the lookahead buffer currently filled (`0…1`) — useful
    /// for "wait until ready" UI before starting the engine.
    public var bufferedFraction: Double {
        Double(state.ring.availableFrames) / Double(state.ring.capacity)
    }

    private func startProducer() {
        let state = self.state
        let run = self.run
        let loops = self.loops
        let thread = Thread {
            var pending: RenderChunk?
            while !state.stopped {
                // Synthesise the next chunk (or retry the one that didn't fit).
                if pending == nil {
                    if let chunk = run.nextChunk(isCancelled: { state.stopped }) {
                        pending = chunk
                    } else if loops && !run.wasCancelled {
                        run.rewindDelivery()
                        continue
                    } else {
                        break
                    }
                }
                // Push it into the ring, waiting for space when full.
                if let chunk = pending {
                    if state.ring.freeFrames >= chunk.frameCount {
                        _ = state.ring.write(l: chunk.l, r: chunk.r, count: chunk.frameCount)
                        pending = nil
                    } else {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
            }
            state.producerDone = true
        }
        thread.name = "PaulStretch.StretchSourceNode"
        thread.qualityOfService = .userInitiated
        producer = thread
        thread.start()
    }
}
