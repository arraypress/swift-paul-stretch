//
//  SessionMixer.swift
//  SwiftPaulStretch
//
//  The live transport: every track's voice on its own sample-locked,
//  loop-phasing channel, with realtime gain / pan / mute / solo.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation
import Combine
import PaulStretch
import PaulStretchEffects

// This product builds on PaulStretchEffects, which compiles to an empty
// module on watchOS.
#if !os(watchOS)

/// Live multitrack playback for a ``Session``.
///
/// Each track gets its own `AVAudioPlayerNode` → `AVAudioMixerNode` channel;
/// all channels start on a single shared `AVAudioTime`, so loops of
/// different lengths stay sample-locked while they phase against each
/// other. Gain, pan, mute and solo respond live; the channel strips are
/// already baked into the voices you pass to ``prepare(session:voices:)``
/// (see ``SessionRenderer/renderVoice(for:sampleRate:isCancelled:)``).
///
/// Master-stack note: the summed bus is played dry live in this version —
/// the master strip (often shimmer/convolution, which can't sit on a live
/// graph) is applied by the bounce, exactly like the single-render apps
/// bake pure effects. Track strips are always audible because they live in
/// the voices.
@MainActor
public final class SessionMixer: ObservableObject {

    /// `true` while the transport runs.
    @Published public private(set) var isPlaying = false

    /// The playhead, in session seconds (wall-clock derived; the audio
    /// itself is sample-locked).
    @Published public private(set) var currentTime: Double = 0

    /// The prepared session's length, in seconds.
    @Published public private(set) var duration: Double = 0

    private struct Channel {
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        var track: Track
        var voice: StereoBuffer
        var format: AVAudioFormat
        var laneGain: Float = 1
    }

    private let engine = AVAudioEngine()
    private var channels: [UUID: Channel] = [:]
    private var session: Session?
    private var basePosition: Double = 0
    private var startDate: Date?
    private var timer: Timer?

    /// Creates an idle mixer.
    public init() {}

    // MARK: - Setup

    /// Loads a session and its rendered voices, (re)building the graph.
    ///
    /// - Parameters:
    ///   - session: The session to play.
    ///   - voices: The rendered voice for every track `id` (tracks without
    ///     one are silent).
    public func prepare(session: Session, voices: [UUID: StereoBuffer]) {
        stop()
        for ch in channels.values {
            engine.detach(ch.player)
            engine.detach(ch.mixer)
        }
        channels.removeAll()

        self.session = session
        duration = session.durationSeconds

        guard let format = AVAudioFormat(standardFormatWithSampleRate: session.sampleRate,
                                         channels: 2) else { return }
        for track in session.tracks {
            guard let voice = voices[track.id], voice.frameCount > 0 else { continue }
            var ch = Channel(track: track, voice: voice, format: format)
            ch.track = track
            engine.attach(ch.player)
            engine.attach(ch.mixer)
            engine.connect(ch.player, to: ch.mixer, format: format)
            engine.connect(ch.mixer, to: engine.mainMixerNode, format: format)
            applyMixerState(to: &ch, session: session)
            channels[track.id] = ch
        }
    }

    // MARK: - Live mixer state

    /// Updates a track's live gain (linear).
    public func setGain(trackID: UUID, _ gain: Float) {
        mutateTrack(trackID) { $0.gain = gain }
    }

    /// Updates a track's live stereo balance (`-1…1`).
    public func setPan(trackID: UUID, _ pan: Float) {
        mutateTrack(trackID) { $0.pan = pan }
    }

    /// Mutes or unmutes a track.
    public func setMuted(trackID: UUID, _ muted: Bool) {
        mutateTrack(trackID) { $0.isMuted = muted }
    }

    /// Solos or unsolos a track (soloing silences all unsoloed tracks).
    public func setSoloed(trackID: UUID, _ soloed: Bool) {
        mutateTrack(trackID) { $0.isSoloed = soloed }
    }

    /// Live automation drive: a multiplier on top of the track's gain.
    ///
    /// Hosts evaluate session-time gain lanes on a timer during playback
    /// and feed the values here, so what you hear tracks what the bounce
    /// applies sample-accurately. Reset to `1` when the lane is removed.
    ///
    /// - Parameters:
    ///   - trackID: The track.
    ///   - multiplier: The lane value (`0…1` typically).
    public func setGainMultiplier(trackID: UUID, _ multiplier: Float) {
        guard let session, var ch = channels[trackID] else { return }
        ch.laneGain = max(0, multiplier)
        applyMixerState(to: &ch, session: session)
        channels[trackID] = ch
    }

    private func mutateTrack(_ id: UUID, _ mutate: (inout Track) -> Void) {
        guard var session, var ch = channels[id] else { return }
        mutate(&ch.track)
        if let i = session.tracks.firstIndex(where: { $0.id == id }) {
            mutate(&session.tracks[i])
        }
        self.session = session
        channels[id] = ch
        // Solo state affects every channel's audibility.
        for (key, var other) in channels {
            applyMixerState(to: &other, session: session)
            channels[key] = other
        }
    }

    private func applyMixerState(to ch: inout Channel, session: Session) {
        ch.mixer.outputVolume = session.isAudible(ch.track) ? ch.track.gain * ch.laneGain : 0
        ch.mixer.pan = max(-1, min(1, ch.track.pan))
    }

    // MARK: - Transport

    /// Starts playback at a session time, sample-locking every channel to
    /// one shared start.
    ///
    /// - Parameter t: The session time to start from, in seconds.
    public func play(from t: Double = 0) {
        guard let session, !channels.isEmpty else { return }
        stopPlayers()
        if !engine.isRunning { try? engine.start() }

        let at = max(0, min(t, duration))
        // One shared anchor ~120 ms out gives every channel time to schedule.
        let hostStart = AVAudioTime(hostTime: mach_absolute_time()
            + AVAudioTime.hostTime(forSeconds: 0.12))

        for ch in channels.values {
            schedule(ch, sessionTime: at, sessionSeconds: session.durationSeconds, at: hostStart)
            ch.player.play(at: hostStart)
        }
        basePosition = at
        startDate = Date()
        isPlaying = true
        startTimer()
    }

    /// Pauses, keeping the position.
    public func pause() {
        guard isPlaying else { return }
        if let s = startDate { basePosition += Date().timeIntervalSince(s) }
        stopPlayers()
        startDate = nil
        isPlaying = false
        stopTimer()
        currentTime = min(duration, basePosition)
    }

    /// Moves the playhead, keeping the play state (a live seek reschedules
    /// every channel on a fresh shared anchor).
    ///
    /// - Parameter t: The target session time, in seconds.
    public func seek(to t: Double) {
        let clamped = max(0, min(duration, t))
        if isPlaying {
            play(from: clamped)
        } else {
            basePosition = clamped
            currentTime = clamped
        }
    }

    /// Stops and rewinds to the start.
    public func stop() {
        stopPlayers()
        startDate = nil
        isPlaying = false
        stopTimer()
        basePosition = 0
        currentTime = 0
    }

    // MARK: - Scheduling

    /// Schedules one channel from a session time: the first segment picks up
    /// mid-loop (honouring entry point and phase), then a full-loop buffer
    /// repeats seamlessly — `AVAudioPlayerNode` concatenates queued buffers
    /// sample-accurately, so phasing stays exact.
    private func schedule(_ ch: Channel, sessionTime: Double, sessionSeconds: Double,
                          at when: AVAudioTime) {
        let sr = ch.voice.sampleRate
        let voiceLen = ch.voice.frameCount
        guard voiceLen > 0 else { return }
        let voiceSeconds = Double(voiceLen) / sr

        let track = ch.track
        var delay = 0.0
        var localSeconds: Double

        if sessionTime < track.startSeconds {
            // The track enters later — schedule it to start in the future.
            delay = track.startSeconds - sessionTime
            localSeconds = track.loopPhaseSeconds.truncatingRemainder(dividingBy: voiceSeconds)
        } else {
            let rel = sessionTime - track.startSeconds + track.loopPhaseSeconds
            if track.loops {
                localSeconds = rel.truncatingRemainder(dividingBy: voiceSeconds)
            } else {
                localSeconds = rel
                if localSeconds >= voiceSeconds { return }   // already finished
            }
        }

        let startAt: AVAudioTime = delay > 0
            ? AVAudioTime(hostTime: when.hostTime + AVAudioTime.hostTime(forSeconds: delay))
            : when

        let head = ch.voice.trimmed(fromSeconds: localSeconds, toSeconds: voiceSeconds)
        if let headPCM = AudioFileIO.makePCMBuffer(head, format: ch.format) {
            ch.player.scheduleBuffer(headPCM, at: startAt, options: [], completionHandler: nil)
        }
        if track.loops, let loopPCM = AudioFileIO.makePCMBuffer(ch.voice, format: ch.format) {
            ch.player.scheduleBuffer(loopPCM, at: nil, options: .loops, completionHandler: nil)
        }
    }

    private func stopPlayers() {
        for ch in channels.values { ch.player.stop() }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard isPlaying, let s = startDate else { return }
        let t = basePosition + Date().timeIntervalSince(s)
        if t >= duration {
            pause()
            currentTime = duration
        } else {
            currentTime = t
        }
    }
}

#endif  // !os(watchOS)
