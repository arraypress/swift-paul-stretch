//
//  SessionMixer.swift
//  SwiftPaulStretch
//
//  The live transport: clips scheduled sample-locked on per-track channels,
//  realtime gain / pan / mute / solo, lane drive, and per-track meters.
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
/// Each track gets an `AVAudioMixerNode` channel; each of its clips gets an
/// `AVAudioPlayerNode` feeding that channel. Every player starts against
/// one shared `AVAudioTime` anchor, so clips (and tiled loops of different
/// lengths) stay sample-locked while they phase. Gain, pan, mute and solo
/// respond live; ``levels`` publishes smoothed per-track meter values.
///
/// The clips' voices are pre-rendered (see
/// ``SessionRenderer/renderVoice(for:trackStack:sampleRate:isCancelled:)``)
/// with the track strip baked in. Clip fades are printed by the bounce but
/// not applied live in this version. The master strip is bounce-only (its
/// pure-DSP devices can't sit on a live graph).
@MainActor
public final class SessionMixer: ObservableObject {

    /// `true` while the transport runs.
    @Published public private(set) var isPlaying = false

    /// The playhead, in session seconds (wall-clock derived; the audio
    /// itself is sample-locked).
    @Published public private(set) var currentTime: Double = 0

    /// The prepared session's length, in seconds.
    @Published public private(set) var duration: Double = 0

    /// Smoothed post-channel meter levels by track `id`, `0…1`.
    @Published public private(set) var levels: [UUID: Float] = [:]

    private struct Channel {
        let mixer = AVAudioMixerNode()
        var players: [AVAudioPlayerNode] = []
        var track: Track
        var voices: [UUID: StereoBuffer] = [:]   // by clip id
        var laneGain: Float = 1
    }

    private let engine = AVAudioEngine()
    private var channels: [UUID: Channel] = [:]
    private var session: Session?
    private var format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var basePosition: Double = 0
    private var startDate: Date?
    private var timer: Timer?

    /// Creates an idle mixer.
    public init() {}

    // MARK: - Setup

    /// Loads a session and its rendered clip voices, (re)building the graph.
    ///
    /// - Parameters:
    ///   - session: The session to play.
    ///   - voices: The rendered voice for every clip `id` (clips without
    ///     one are silent).
    public func prepare(session: Session, voices: [UUID: StereoBuffer]) {
        stop()
        for ch in channels.values {
            ch.mixer.removeTap(onBus: 0)
            ch.players.forEach { engine.detach($0) }
            engine.detach(ch.mixer)
        }
        channels.removeAll()
        levels.removeAll()

        self.session = session
        duration = session.durationSeconds
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: session.sampleRate,
                                      channels: 2) else { return }
        format = fmt

        for track in session.tracks {
            var ch = Channel(track: track)
            engine.attach(ch.mixer)
            engine.connect(ch.mixer, to: engine.mainMixerNode, format: fmt)
            for clip in track.clips {
                guard let voice = voices[clip.id], voice.frameCount > 0 else { continue }
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: ch.mixer, format: fmt)
                player.volume = clip.gain
                ch.players.append(player)
                ch.voices[clip.id] = voice
            }
            installMeterTap(on: ch.mixer, trackID: track.id)
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

    /// Starts playback at a session time, sample-locking every clip player
    /// to one shared start.
    ///
    /// - Parameter t: The session time to start from, in seconds.
    public func play(from t: Double = 0) {
        guard let session, !channels.isEmpty else { return }
        stopPlayers()
        if !engine.isRunning { try? engine.start() }

        let at = max(0, min(t, duration))
        // One shared anchor ~120 ms out gives every player time to schedule.
        let hostStart = AVAudioTime(hostTime: mach_absolute_time()
            + AVAudioTime.hostTime(forSeconds: 0.12))

        for ch in channels.values {
            for (index, clip) in ch.track.clips.enumerated() {
                guard index < ch.players.count,
                      let voice = ch.voices[clip.id] else { continue }
                let player = ch.players[index]
                schedule(clip, voice: voice, on: player,
                         from: at, sessionEnd: session.durationSeconds, anchor: hostStart)
                player.play(at: hostStart)
            }
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
    /// every clip on a fresh shared anchor).
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

    /// Schedules one clip from a transport time: a possibly-partial first
    /// slice (honouring the clip's left-trim and where the playhead falls),
    /// then whole-voice iterations back-to-back — `AVAudioPlayerNode`
    /// concatenates queued buffers sample-accurately, so tiling stays exact.
    private func schedule(_ clip: Clip, voice: StereoBuffer, on player: AVAudioPlayerNode,
                          from t: Double, sessionEnd: Double, anchor: AVAudioTime) {
        let voiceSeconds = voice.duration
        guard voiceSeconds > 0 else { return }
        let clipStart = clip.startSeconds
        let clipEnd = min(clip.endSeconds, sessionEnd)
        guard clipEnd > t else { return }

        let audioBegins = max(t, clipStart)
        let delay = audioBegins - t
        var posInClip = audioBegins - clipStart
        var remaining = clipEnd - audioBegins
        var when: AVAudioTime? = delay > 0
            ? AVAudioTime(hostTime: anchor.hostTime + AVAudioTime.hostTime(forSeconds: delay))
            : anchor
        let fullPCM = AudioFileIO.makePCMBuffer(voice, format: format)

        while remaining > 0.001 {
            var posInVoice = clip.offsetSeconds + posInClip
            if clip.fillsWithLoop {
                posInVoice = posInVoice.truncatingRemainder(dividingBy: voiceSeconds)
            } else if posInVoice >= voiceSeconds - 0.001 {
                break
            }
            let sliceSeconds = min(voiceSeconds - posInVoice, remaining)
            let isWholeVoice = posInVoice < 0.0005 && abs(sliceSeconds - voiceSeconds) < 0.0005
            let pcm: AVAudioPCMBuffer?
            if isWholeVoice {
                pcm = fullPCM   // shared buffer for full iterations — no copies
            } else {
                pcm = AudioFileIO.makePCMBuffer(
                    voice.trimmed(fromSeconds: posInVoice, toSeconds: posInVoice + sliceSeconds),
                    format: format)
            }
            if let pcm {
                player.scheduleBuffer(pcm, at: when, options: [], completionHandler: nil)
            }
            when = nil          // subsequent slices queue back-to-back
            posInClip += sliceSeconds
            remaining -= sliceSeconds
        }
    }

    // MARK: - Meters

    private func installMeterTap(on mixer: AVAudioMixerNode, trackID: UUID) {
        var smoothed: Float = 0
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let ch = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            var peak: Float = 0
            for i in 0..<n { peak = max(peak, abs(ch[0][i])) }
            // Fast attack, slow decay.
            smoothed = peak > smoothed ? peak : smoothed * 0.86 + peak * 0.14
            let value = min(1, smoothed)
            Task { @MainActor in self?.levels[trackID] = value }
        }
    }

    private func stopPlayers() {
        for ch in channels.values { ch.players.forEach { $0.stop() } }
        for id in levels.keys { levels[id] = 0 }
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
