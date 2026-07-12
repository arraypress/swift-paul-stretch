//
//  StretchPlayer.swift
//  SwiftPaulStretch
//
//  Seekable, pausable, region-looping StereoBuffer playback through the
//  live stock effect chain, with a spectrum tap — the playback half every
//  host app otherwise rebuilds (and re-debugs) by hand.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation
import Combine
import PaulStretch

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// A seekable, region-looping player for ``StereoBuffer``s, wired through
/// the live stock ``EffectChain`` with a built-in ``SpectrumAnalyzer`` tap.
///
/// Playback position is wall-clock derived (playback is realtime 1.0×), so
/// the readout stays correct across seeks and loops without juggling
/// `AVAudioPlayerNode` sample times. Two `AVAudioPlayerNode` pitfalls are
/// handled internally: `stop()` fires the *previous* buffer's completion
/// handler (guarded by a generation counter), and re-wiring is performed
/// whenever a loaded buffer's sample rate differs from the current graph.
///
/// The published properties make it drop-in observable from SwiftUI:
///
/// ```swift
/// let player = StretchPlayer()
/// player.load(render, loop: true)
/// player.setEffects(effects)   // live stock chain
/// player.play()
/// ```
@MainActor
public final class StretchPlayer: ObservableObject {

    /// `true` while audio is playing.
    @Published public private(set) var isPlaying = false

    /// The playhead position, in seconds (wall-clock derived).
    @Published public private(set) var currentTime: Double = 0

    /// The loaded buffer's duration, in seconds (`0` before any load).
    @Published public private(set) var duration: Double = 0

    /// The live post-effects spectrum, `0…1` per band, updated ~continuously
    /// while the engine runs. Band count is fixed at init.
    @Published public private(set) var spectrum: [Float]

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let chain = EffectChain()
    private let analyzer: SpectrumAnalyzer

    private var buf: StereoBuffer?
    private var fullPCM: AVAudioPCMBuffer?
    private var fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private var looping = false
    private var regionStart: Double = 0      // playable range (whole buffer by default)
    private var regionEnd: Double = 0
    private var basePosition: Double = 0     // seconds into buffer at last (re)start
    private var startDate: Date?
    private var timer: Timer?
    private var started = false
    private var connectedRate: Double = 44100
    private var generation = 0               // invalidates stale completion handlers

    /// Creates a player (and its engine graph, not yet running).
    ///
    /// - Parameter spectrumBandCount: The number of bands ``spectrum``
    ///   carries. Defaults to `56`.
    public init(spectrumBandCount: Int = 56) {
        analyzer = SpectrumAnalyzer(bandCount: spectrumBandCount)
        spectrum = Array(repeating: 0, count: analyzer.bandCount)

        engine.attach(player)
        chain.install(in: engine, from: player, to: engine.mainMixerNode, format: fmt)

        // Live spectrum: tap the mixer output (post-effects). The closure
        // runs on the audio thread; results hop to main for the UI.
        let az = analyzer
        az.onBands = { [weak self] bands in
            Task { @MainActor in self?.spectrum = bands }
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, _ in
            az.process(buf)
        }
    }

    /// Applies stock-chain effect settings to the live graph.
    ///
    /// - Parameter fx: The effect settings (only the stock chain runs live;
    ///   bake the pure-DSP stages into the buffer before loading).
    public func setEffects(_ fx: EffectsParameters) { chain.apply(fx) }

    /// Loads a buffer, stopping any current playback.
    ///
    /// - Parameters:
    ///   - b: The audio to play.
    ///   - loop: Whether playback loops (within the region, if one is set).
    ///   - region: An optional playable sub-range, in seconds.
    public func load(_ b: StereoBuffer, loop: Bool, region: ClosedRange<Double>? = nil) {
        stop()
        fmt = AVAudioFormat(standardFormatWithSampleRate: b.sampleRate, channels: 2)!
        // The chain was wired at init's rate; re-wire when the buffer's
        // rate differs (connect replaces the existing connections).
        if b.sampleRate != connectedRate {
            engine.stop()
            started = false
            chain.install(in: engine, from: player, to: engine.mainMixerNode, format: fmt)
            connectedRate = b.sampleRate
        }
        buf = b
        fullPCM = AudioFileIO.makePCMBuffer(b, format: fmt)
        duration = b.duration
        looping = loop
        applyRegion(region)
        currentTime = regionStart
        basePosition = regionStart
    }

    /// Restricts playback (and looping) to a sub-range; the playhead stays
    /// inside it. Pass `nil` (or a degenerate range) to clear.
    ///
    /// - Parameter region: The playable range, in seconds.
    public func setRegion(_ region: ClosedRange<Double>?) {
        applyRegion(region)
        if currentTime < regionStart || currentTime > regionEnd {
            currentTime = regionStart; basePosition = regionStart
        }
        if isPlaying { restart(from: currentTime) }
    }

    /// Turns looping on or off, taking effect immediately when playing.
    ///
    /// - Parameter on: Whether playback loops.
    public func setLoop(_ on: Bool) {
        looping = on
        if isPlaying { restart(from: currentTime) }
    }

    /// Plays if paused, pauses if playing.
    public func togglePlayPause() { isPlaying ? pause() : play() }

    /// Starts (or resumes) playback from the current position, rewinding to
    /// the region start when the playhead sits at the end.
    public func play() {
        guard buf != nil else { return }
        if currentTime >= regionEnd - 0.01 { currentTime = regionStart; basePosition = regionStart }
        restart(from: currentTime)
    }

    /// Pauses playback, keeping the position.
    public func pause() {
        generation += 1                  // stale completions must not fire
        player.pause()
        if let s = startDate { basePosition += Date().timeIntervalSince(s) }
        startDate = nil
        isPlaying = false
        stopTimer()
        tick()
    }

    /// Moves the playhead (clamped to the region), keeping the play state.
    ///
    /// - Parameter t: The target position, in seconds.
    public func seek(to t: Double) {
        let clamped = max(regionStart, min(regionEnd, t))
        currentTime = clamped
        basePosition = clamped
        if isPlaying { restart(from: clamped) } else { startDate = nil }
    }

    /// Stops playback and returns the playhead to the region start.
    public func stop() {
        generation += 1
        player.stop()
        isPlaying = false
        startDate = nil
        stopTimer()
        currentTime = regionStart      // stop returns to the region start
        basePosition = regionStart
    }

    // MARK: - Internals

    private func applyRegion(_ region: ClosedRange<Double>?) {
        regionStart = max(0, region?.lowerBound ?? 0)
        regionEnd = min(duration, region?.upperBound ?? duration)
        if regionEnd <= regionStart + 0.02 { regionStart = 0; regionEnd = duration }
    }

    private func slicePCM(fromSeconds a: Double, toSeconds b: Double) -> AVAudioPCMBuffer? {
        guard let buf, let fullPCM else { return nil }
        let slice = buf.trimmed(fromSeconds: a, toSeconds: b)
        if slice.frameCount == buf.frameCount { return fullPCM }
        return AudioFileIO.makePCMBuffer(slice, format: fmt)
    }

    private func restart(from t: Double) {
        guard buf != nil else { return }
        if !started { try? engine.start(); started = true }
        generation += 1
        let gen = generation
        player.stop()                    // fires the previous buffer's completion (now stale)
        let startT = max(regionStart, min(regionEnd - 0.005, t))
        guard let seg = slicePCM(fromSeconds: startT, toSeconds: regionEnd) else { return }
        player.scheduleBuffer(seg, at: nil, options: [], completionHandler: { [weak self] in
            Task { @MainActor in self?.segmentFinished(gen) }
        })
        if looping, let regionPCM = slicePCM(fromSeconds: regionStart, toSeconds: regionEnd) {
            player.scheduleBuffer(regionPCM, at: nil, options: .loops, completionHandler: nil)
        }
        basePosition = startT
        startDate = Date()
        player.play()
        isPlaying = true
        startTimer()
    }

    /// Called when a scheduled segment finishes. Ignored if a newer restart /
    /// stop / pause has bumped the generation (a stale callback from a
    /// `player.stop()` we triggered ourselves).
    private func segmentFinished(_ gen: Int) {
        guard gen == generation, !looping else { return }
        generation += 1
        player.stop()
        isPlaying = false
        startDate = nil
        stopTimer()
        currentTime = regionStart
        basePosition = regionStart
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard duration > 0 else { return }
        let regionDur = max(0.001, regionEnd - regionStart)
        var elapsed = 0.0
        if let s = startDate { elapsed = Date().timeIntervalSince(s) }
        if looping {
            let rel = (basePosition - regionStart) + elapsed
            currentTime = regionStart + rel.truncatingRemainder(dividingBy: regionDur)
        } else {
            currentTime = min(regionEnd, basePosition + elapsed)
        }
    }
}

#endif  // !os(watchOS)
