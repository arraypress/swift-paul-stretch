# Swift PaulStretch

A pure-Swift PaulStretch engine for turning short sounds into long ambient
drones — extreme time stretching, tape-style slow-down and spectral freeze,
built on Accelerate/vDSP with no third-party dependencies. Ported faithfully
from a battle-tested in-house engine (bit-for-bit verified) and designed for
reuse across macOS **and** iOS apps: every render can stream in bounded
memory, so an hour-long export never has to exist in RAM.

## Features

- 🌀 **Classic PaulStretch** — windowed STFT with per-window phase
  randomisation and 4× Hann overlap-add; stretch ratios into the thousands
  with layering (1/3/5 passes), FFT-domain pitch shift and onset preservation.
- ✨ **Shimmer layers** — layer presets with per-layer pitch offsets
  (octave-up / sub-octave voices) for Eno-style shimmer drones.
- 🐢 **Tape slow-down** — varispeed "slowed + reverb" treatment, tiled with
  equal-power crossfades to any target length. No FFT, nearly free.
- ❄️ **Spectral freeze** — capture one instant's spectrum and sustain it
  forever with shimmering random phase; a smear control morphs tonal → washy,
  and a scan control lets the frozen spectrum drift through the source —
  frozen but alive.
- 🎼 **Phase-vocoder stretch** — coherent, propagated phases for clean
  2–8× slow-downs that keep the source's structure and pitch: no wash, no
  tape pitch-drop, and a fraction of PaulStretch's amplitude flutter.
- 🌫 **Granular cloud** — dense Hann grains with position jitter, pitch
  spread and stereo scatter; the grainy, shimmering sibling of the
  PaulStretch wash.
- 📱 **iOS-safe chunked rendering** — stream any render as ordered chunks or
  straight to disk with a peak footprint of a few megabytes,
  **bit-for-bit identical** to the in-memory render.
- 💾 **Every Apple-encodable format** — WAV, AIFF, CAF, AAC (CBR/VBR/HE),
  Apple Lossless, FLAC and Opus, with bit-depth/bit-rate/quality controls;
  compressed formats encode on the fly during chunked export (a 60-minute
  render: ~950 MB WAV vs ~115 MB AAC).
- 🔁 **Seamless loops** — equal-power loop crossfade baked into the render,
  so a 45-second file repeats invisibly (the memory-free way to play
  "endless" ambience on iOS).
- 🎧 **Realtime playback node** — `StretchSourceNode` synthesises the
  timeline just-in-time on a background thread and plays it through an
  `AVAudioSourceNode`: endless looped ambience with **zero pre-render** and
  a few megabytes of lookahead, for all three engines.
- ▶️ **Drop-in buffer player** — `StretchPlayer` (PaulStretchEffects) plays
  rendered `StereoBuffer`s with seek, pause, region-looping, the live stock
  effect chain and a built-in spectrum tap — observable from SwiftUI, with
  the `AVAudioPlayerNode` completion-handler races already handled.
- 📊 **Display helpers** — `SpectrumAnalyzer` folds engine-tap buffers into
  smoothed log-band meter values; `StereoBuffer.peaks(columns:)` produces
  waveform-view peak columns.
- ⏳ **async/await throughout** — `try await` renders that honour `Task`
  cancellation, plus a pull-based `AsyncSequence` of chunks with natural
  backpressure.
- 🎲 **Deterministic seeding** — same source + parameters + seed always
  reproduces identical output; variation seeds give batch-friendly
  alternates of the same settings.
- ⚡ **Multicore** — the output timeline is partitioned across cores with
  lock-free, seed-stable workers (~2000× realtime for a single-layer stretch
  on an M-series Mac).
- 🎛 **Optional stock effects** — a second product (`PaulStretchEffects`)
  wraps Apple's reverb/EQ/filter/delay as a live chain plus offline and
  streaming bakes, so what you monitor is what you export.
- 🌠 **Shimmer reverb** — the library's own DSP (Freeverb tank + pitch-shifted
  feedback). An `AVAudioEngine` *graph* can't hold the feedback cycle shimmer
  needs, but a cycle kept inside one render callback can — so it runs live via
  `LiveEffectNode`, and bakes offline and streams for export.
- 🏛 **Convolution reverb** — algorithmically-generated impulse responses
  (plate / hall / cathedral / exponential wash) with a real **decay-time**
  control up to 30 s, convolved in streaming FFT partitions. Seeded and
  deterministic.
- 🌊 **Ambient motion suite** — a breathing **sweep filter** (TPT
  state-variable core, LFO in octaves, bass-cut companion), tape
  **wow & flutter** (cubic-interpolated, with seeded drift), a tidal
  **breathing pump**, and a slow **auto-pan** — movement, colour and space
  for drones.
- ⚡️ **Realtime pure DSP** — `LiveEffectChain` + `LiveEffectNode` run
  shimmer, convolution reverb, sweep filter, wow, pump, auto-pan, gate and
  placement *on the playback graph* as an in-process v3 audio unit, so every
  effect is tweakable while audio plays instead of forcing a re-render.
  Measured at ~1.6 ms per 512-frame quantum — about 13% of the budget.
- 🎚 **Parametric EQ** — seven bands (high-pass, two shelves, three bells,
  low-pass), each with shape, frequency, gain and bandwidth. Runs live on
  `AVAudioUnitEQ`; every band starts flat, so enabling it is silent.
- ⏹ **Trance gate** — 16-step rhythmic gating with named patterns
  (eighths / sixteenths / off-beat / tresillo / sparse), rate, depth,
  edge smoothing and a ping-pong stereo offset. The one effect that gives a
  static drone a pulse.
- ↔️ **Stereo placement** — equal-power pan (unity at centre, no 3 dB dip)
  plus mid/side width: collapse to mono at `0`, spread past the original
  image at `2`. Mono-safe, unlike a delay-based widener.
- 📈 **Automation lanes** — Catmull-Rom spline curves
  (`AutomationLane`) drive effect parameters across the whole render:
  a filter opening over twenty minutes is composition, not just processing.
- 📦 **Codable parameters** — persist presets as JSON straight from
  `StretchParameters` / `EffectsParameters`.

## Requirements

- iOS 13.0+ / macOS 10.15+ / tvOS 13.0+ / watchOS 6.0+ / visionOS 1.0+
- Swift 5.9+
- `PaulStretchEffects` is unavailable on watchOS (the `AVAudioUnit` effect
  classes don't exist there); the core `PaulStretch` product works everywhere.

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/arraypress/swift-paul-stretch.git", from: "2.0.0")
]
```

Add `PaulStretch` to your target; add `PaulStretchEffects` for the effect
chains and channel strips, and `PaulStretchSession` for the multitrack
arrangement model.

## Usage

### Load a source and render a drone

```swift
import PaulStretch

let source = try AudioFileIO.readStereo(url: fileURL)   // any format AVFoundation reads
    .trimmed(fromSeconds: 2.0, toSeconds: 6.5)          // optional region
    .peakNormalized()

var params = StretchParameters()                        // layered-drone defaults
params.targetSeconds = 300
params.windowSeconds = 0.30
let drone = StretchRenderer.render(source, parameters: params)
// drone is a StereoBuffer — play it, export it, inspect it
```

### Seamless loops — the iOS playback strategy

Rendering a short loop and repeating it forever costs a few megabytes and a
fraction of a second, and the PaulStretch wash makes the repeat all but
imperceptible:

```swift
var params = StretchParameters()
params.targetSeconds = 45
params.seamlessLoop = true          // renders 6 s extra, crossfades tail → head
let loop = StretchRenderer.render(source, parameters: params)
// schedule `loop` end-to-start with no gap; the seam is inaudible
```

### Chunked render to disk — the iOS export strategy

A 60-minute stereo render is ~1.3 GB as a single buffer — enough for iOS to
jetsam-kill the app. The chunked renderer streams the identical audio with a
peak footprint of a few chunks:

```swift
var params = StretchParameters()
params.targetSeconds = 3600
try StretchRenderer.renderToFile(source, parameters: params,
                                 url: exportURL,          // use .m4a for the AAC/ALAC formats
                                 format: .aac256,          // ~115 MB/hour instead of ~950 MB WAV
                                 progress: { print("\\($0 * 100)%") })
```

`AudioFileFormat` covers everything Apple platforms can encode — `.wav` /
`.aiff` / `.caf` PCM (16/24-bit int, 32-bit float), `.m4aAAC(bitRate:quality:)`,
`.m4aAACVBR(quality:)`, `.m4aHEAAC(bitRate:)` (tiny background-ambience
files), `.m4aALAC(bitDepth:)`, `.flac(bitDepth:)` and `.opusCAF(bitRate:)`
(48 kHz streams only). One caveat: lossy `.m4a` files carry encoder
priming, so a file meant to **loop directly in a streaming player** should
be PCM or lossless — decoding an `.m4a` back to memory first loops
seamlessly (AVFoundation trims the priming on read).

Or drive the chunks yourself (feed a player, a network stream, …):

```swift
StretchRenderer.renderChunks(source, parameters: params) { chunk in
    try myWriter.append(l: chunk.l, r: chunk.r)     // arrives in timeline order
}
```

Chunked output is **bit-for-bit identical** to
`StretchRenderer.render(...)` — the test suite asserts exact equality for
every mode.

### Realtime playback — zero pre-render

For playback (rather than export) you can skip rendering entirely:
`StretchSourceNode` synthesises the timeline just-in-time while it plays,
holding only a few seconds of lookahead. With `seamlessLoop` it wraps
forever — endless ambience from a one-second source with ~2 MB of memory:

```swift
var params = StretchParameters()
params.targetSeconds = 120
params.seamlessLoop = true
let node = try await StretchSourceNode.prepare(source: source, parameters: params)

engine.attach(node.avAudioNode)
engine.connect(node.avAudioNode, to: engine.mainMixerNode, format: node.format)
try engine.start()                       // plays endlessly, synthesised live
```

Works for all three modes (tape-slow even prepares instantly — it has no
peak passes). The node plays the *same deterministic timeline* the offline
renderers produce, so what you preview live is exactly what an export
writes.

### async/await

Every render has an async form that runs off the cooperative pool and
honours `Task` cancellation (cancelling throws `CancellationError` and, for
file renders, deletes the partial file):

```swift
let drone = try await StretchRenderer.render(source, parameters: params)
try await StretchRenderer.renderToFile(source, parameters: params,
                                       url: exportURL, format: .aac256)

for try await chunk in StretchRenderer.renderChunkSequence(source, parameters: params) {
    feed(chunk)      // pull-based: chunks are computed as you consume them
}
```

### Modes

```swift
params.mode = .paulStretch     // the classic wash (layering, pitch, onsets)
params.mode = .tapeSlow        // varispeed slow-down, tiled to length
params.mode = .spectralFreeze  // one frozen instant, sustained forever
params.mode = .phaseVocoder    // clean structural stretch, pitch preserved
params.mode = .granularCloud   // grain cloud: jitter, pitch spread, pan scatter
```

```swift
// Shimmer drones: layering presets with pitched voices.
params.layering = .shimmer         // adds an octave-up stretch layer
params.layering = .shimmerDeep     // octave-up + sub-octave

// A freeze that slowly morphs through the source:
params.mode = .spectralFreeze
params.freezeScan = 0.6            // capture point drifts 60% of the way

// Granular clouds:
params.mode = .granularCloud
params.grainSeconds = 0.12
params.grainPitchSpread = 7        // grains scattered across ±7 semitones
params.grainPanSpread = 1.0        // full stereo field
```

Notes: the phase vocoder wants short windows (`windowSeconds` ≈ 0.05–0.1)
and ignores layering/phase-randomness; its chunked path renders through
sequential streams (single-core) — still far faster than realtime.

### Batch variations

```swift
for i in 0..<10 {
    let seed = StretchRenderer.variationSeed(i)
    let take = StretchRenderer.render(source, parameters: params, seed: seed)
    // ten audibly different washes from the same settings, reproducibly
}
```

### Raw algorithms

The pipeline pieces are exposed directly when you don't want the full render:

```swift
let washed = PaulStretcher.stretch(source, ratio: 8)                    // raw stretch
let frozen = SpectralFreezer.render(source, position: 0.5, smear: 0.3,
                                    targetSeconds: 120)                 // raw freeze
let slow   = source.applyingTapeSpeed(0.5)                              // varispeed (windowed sinc)
let wide   = drone.applyingStereoWidth(1.4)                             // mid/side width
let ready  = drone.seamlesslyLooped()                                   // loop crossfade
```

### Effects (PaulStretchEffects)

```swift
import PaulStretchEffects

var fx = EffectsParameters()
fx.reverbEnabled = true
fx.reverbPreset = .cathedral    // the classic PaulStretch pairing
fx.reverbMix = 42

// Live, on a playback graph:
let chain = EffectChain()
chain.install(in: engine, from: playerNode, to: engine.mainMixerNode, format: format)
chain.apply(fx)                 // update any time, even while playing

// Baked into an export (same parameters → what you hear is what you export):
let wet = EffectsBaker.bake(drone, effects: fx)

// Shimmer reverb — runs live via LiveEffectNode (below), and bakes for export:
fx.shimmerEnabled = true
fx.shimmerPitch = 12          // octave-up bloom (+7 for fifths)
fx.shimmerFeedback = 55
let halo = EffectsBaker.bake(drone, effects: fx)

// Or streamed, for long effected exports in bounded memory:
try StretchRenderer.renderToWAVFile(source, parameters: params, effects: fx, url: exportURL)
```

### Chain order

Order is not a detail: distortion before a filter is a different sound from
distortion after it, and a limiter anywhere but last is not a limiter. The
running order lives in the settings as a list of `EffectSlot`, and both halves
of the chain read it.

```swift
var fx = EffectsParameters()
fx.chainOrder                    // every unit exactly once, in running order
fx.stockOrder                    // the AVAudioUnit half
fx.pureOrder                     // the pure-DSP half

fx.move(.distortion, by: -2)     // two places earlier; false if it can't move
fx.resetChainOrder()             // back to how it shipped

chain.install(in: engine, from: player, to: mixer,
              format: format, order: fx.chainOrder)
chain.reorder(to: fx.chainOrder) // rewires live; costs a buffer, so not per-knob
```

The two halves cannot interleave with each other. The stock units are separate
nodes in the engine graph; every pure-DSP stage runs inside a single node. So a
move is confined to its own half, and `move` returns `false` rather than
silently doing nothing.

Setting `chainOrder` accepts a partial list — anything you leave out is appended
in `EffectSlot.naturalOrder`, and duplicates collapse. That is what makes the
order safe to persist: adding a unit to the library never invalidates a saved
chain, and a document written before this feature existed decodes to the
sequence it always ran in.

### Pitch — a live shifter with detuned voices

```swift
fx.pitchEnabled = true
fx.pitchSemitones = 7      // a fifth up, automatable by the host
fx.pitchCents = 0
fx.pitchSpread = 12        // cents between voices — this is what makes a drone move
fx.pitchVoices = 3         // spread across the stereo field
fx.pitchMix = 50           // below 100 keeps the dry, so it is an INTERVAL not a transposition
```

A crossfaded delay line, not an FFT. Reading a buffer faster or slower than it is written IS a pitch
shift; the only problem is the wrap, and two taps half a buffer apart windowed by Hann solve it —
`w(x) + w(x + 0.5) == 1` for Hann, so the pair sums to unity while each tap is silent exactly where
it wraps.

`StretchParameters.pitchSemitones` is a different thing: it is baked into a render, so it cannot be
drawn on a curve. It shifts by RESAMPLING the input and compensating the ratio, which is what
PaulStretch itself does — bin remapping was not phase-coherent and flutter measured worse shifting
up than down.

### Realtime effects — tweak while it plays

The stock Apple chain was always live; the library's own DSP used to be baked
into the playback buffer, so changing shimmer or the sweep filter meant a
re-render. `LiveEffectNode` puts those stages on the graph too.

```swift
// One call, before playback. Everything is live from then on.
await player.enableLiveEffects(fx)

fx.shimmerMix = 60
fx.tranceGateEnabled = true
player.setEffects(fx)          // heard on the next 512-frame quantum
```

Or drive the chain yourself, outside `StretchPlayer`:

```swift
let chain = LiveEffectChain(sampleRate: 44100, effects: fx)
let node  = await LiveEffectNode.make(chain: chain)!
engine.attach(node)
engine.connect(player, to: node, format: format)
chain.setEffects(updated)      // non-blocking; the render picks it up
```

Two things worth knowing. **Parameter changes never block the audio thread** —
`setEffects` builds the replacement chain on the calling thread and publishes
it; the render callback takes it with a try-lock and keeps the current one if
it loses the race, costing at most a quantum of staleness rather than a
dropout. And **a rebuilt chain starts with empty delay lines**, so a live
change truncates reverb tails — cross-fade over a swap rather than cutting to
it.

Export still bakes the identical stages offline, so tune-then-bounce holds.

### Channel-strip effect stacks (PaulStretchEffects)

`EffectStack` is the Ableton-style device model: an ordered, reorderable
chain of `EffectDevice`s — each one effect with its own settings and bypass,
duplicates welcome. The library's pure-DSP devices and the whole Apple
palette share one stack, and `EffectStackBaker` honours the order exactly
(consecutive Apple devices group into a single offline pass).

```swift
var strip = EffectStack([
    EffectDevice(.sweepFilter(filter)),        // darken the send…
    EffectDevice(.shimmer(shimmer)),           // …bloom it…
    EffectDevice(.convolutionReverb(space)),   // …then place it in a room
    EffectDevice(.apple(.peakLimiter(.init()))),
])
strip.move(fromIndex: 0, toIndex: 2)           // filter the tail instead
let wet = EffectStackBaker.bake(dry, stack: strip)
// strip.signature — cache key: re-bake playback when (and only when) it changes
```

### Ambient sessions (PaulStretchSession)

A time-based multitrack arrangement model for generative ambient — the
ruler is seconds, not bars. Tracks hold `Clip`s: blocks with a timeline
position, placed length, left-trim, gain, edge fades, and loop-fill (the
clip's voice tiles to fill the block; blocks with different voice lengths
phase against each other endlessly — the tape-loop model behind *Music for
Airports*). A clip's voice renders deterministically and caches:
**dragging, trimming and fading never re-render** — only source or strip
changes do. The same session always bounces the identical file.

```swift
import PaulStretchSession

var session = Session()

var track = Track(name: "piano drone")
track.stack = EffectStack([EffectDevice(.shimmer(shimmer))])   // baked per voice
track.gainLane = AutomationLane(points: [AutomationPoint(t: 0, v: 0.2),
                                         AutomationPoint(t: 1, v: 0.9)])

var clip = Clip(name: "drone",
                source: .generative(GenerativeSource(audio: .init(path: noteURL.path),
                                                     parameters: droneParams, seed: 3)),
                startSeconds: 0, durationSeconds: 1800)  // 61 s voice tiles 30 min
clip.fadeInSeconds = 20
track.clips = [clip]
session.tracks = [track]
session.durationSeconds = 1800
session.master = EffectStack([EffectDevice(.convolutionReverb(hall))])

let mix = try SessionRenderer.render(session)            // deterministic bounce
try AudioFileIO.write(mix, to: outURL, format: .aac256)

// Live: render voices once (cache by SessionRenderer.voiceCacheKey), then
let mixer = SessionMixer()          // player-per-clip, one shared sample-locked anchor
mixer.prepare(session: session, voices: voicesByClipID)
mixer.play(from: 0)                 // live gain/pan/mute/solo + `levels` meters
```

### Playing renders (PaulStretchEffects)

`StretchPlayer` is the playback half of a host app: load a render, scrub it,
loop a region, and tweak the stock chain live. Its published `isPlaying` /
`currentTime` / `duration` / `spectrum` drive SwiftUI directly.

```swift
@StateObject var player = StretchPlayer()

player.load(render, loop: true)      // or region: 2.0...6.5
player.setEffects(fx)                // live stock chain on top
player.play()
player.seek(to: 30)
```

The pure-DSP stages (shimmer, convolution reverb, sweep filter, wow, pump,
auto-pan) can't run on a live graph — bake them with
`EffectsBaker.bakePureStages(_:effects:)` and reload the player when
`fx.pureDSPSignature` changes:

```swift
if fx.pureDSPSignature != lastBakedSignature {
    lastBakedSignature = fx.pureDSPSignature
    player.load(EffectsBaker.bakePureStages(dry, effects: fx), loop: true)
}
```

### Cancellation and progress

Every render takes an `isCancelled` closure (poll-based, thread-safe with the
provided `CancelToken`) and a `progress` closure:

```swift
let token = CancelToken()
Task.detached {
    let out = StretchRenderer.render(source, parameters: params,
                                     isCancelled: { token.isCancelled },
                                     progress: { fraction in /* update UI */ })
}
// from the UI:
token.cancel()
```

## How It Works

```
source ──► reverse? ──► tape speed? ──► ┌──────────────────────────────┐
                                        │ paulStretch:  STFT → random  │
                                        │   phases → IFFT → overlap-add│
                                        │   (× layers, × tiles)        │
                                        │ tapeSlow:     tile the       │
                                        │   varispeed source           │
                                        │ spectralFreeze: resynthesise │
                                        │   one captured spectrum      │
                                        └──────────────┬───────────────┘
                                                       ▼
                          stereo width ──► seamless loop  OR  fade in/out
```

The property that makes the library special: **every STFT window is seeded
independently** (splitmix64-mixed per-window seeds), so any output range can
be rendered in isolation with identical results. That one invariant powers
both the lock-free multicore renderer (cores own disjoint output segments)
and the chunked renderer (time owns disjoint output segments). Where the
in-memory path normalises buffers in place, the chunked path first sweeps
the timeline to measure the same peaks, then streams the final pass — the
arithmetic is identical down to the operation order, which is why the
outputs match bit for bit.

## Performance & Memory

**A bypassed `AVAudioUnit` is not free.** `EffectChain` wires in only the units that are switched
on; the rest stay attached and out of the path. Measured on a host playing two layers with no
effects: 12.8% of a core with everything wired, 6.5% with only what is on.

**Rewiring stops the engine.** Switching a unit on changes the chain's topology, and an
`AVAudioUnit` that was attached but never connected has not been prepared — connecting it into a
live graph leaves the path mute. `apply` stops and restarts around the change, which costs a buffer.
A host must RE-ARM its players afterwards, because stopping drops what they had scheduled.

**Relative cost of the pure-DSP stages**, measured on six voices against a silent baseline: shimmer
is by far the most expensive, roughly 2.5x the convolution reverb — which is the only stage using
vDSP and therefore one of the cheapest. Shimmer and pitch are feedback algorithms and cannot be
parallelised, on the CPU or anywhere else.



Measured on an M-series Mac (14 cores), 3 s source → 10-minute render:

| Render | Speed | Peak memory |
| --- | --- | --- |
| In-memory, single layer | ~2100× realtime | whole output (~100 MB/10 min) |
| In-memory, 3 layers | ~600× realtime | whole output + intermediates |
| Chunked, single layer | ~590× realtime | a few chunks (~10 MB) |
| Chunked, 3 layers | ~120× realtime | a few chunks (~10 MB) |

Chunked rendering trades compute (the peak-measuring passes re-render) for
bounded memory. Rules of thumb:

- **Mac, or renders under ~10 minutes** → `render(...)`, simplest and fastest.
- **iOS playback** → `seamlessLoop` + a short target; loop the file forever.
- **iOS export of a genuine long render** → `renderToWAVFile(...)`; a
  60-minute file streams to disk in well under a minute of CPU on modern
  phones instead of holding ~1.3 GB (+ intermediates) in RAM.

**Tape-slow tiles are held to the source's peak.** Passthrough tiles are never
normalised — the caller's level is kept — but where two full-scale tiles overlap
at a seam their peaks can coincide and sum past full scale (a pad measured
+0.98 dBFS, clipped at every seam). Every seam's crossfade now follows the
measured correlation between the block's tail and head (equal-power for
uncorrelated material, linear for correlated, solved in closed form for the
midpoint to sit at unity power), and the whole passthrough render is scaled down
— only down — to the peak of the source as given, measured before varispeed.
Both renderers compute it identically, so chunked and in-memory stay bit-exact.

**Varispeed is a windowed sinc** (64 taps, Blackman, 512-phase table): it nulls
against an ideal resample at better than -60 dB where linear interpolation
managed -42, and speeding up band-limits to the new Nyquist instead of aliasing.

A bare stretch carries ~30 % amplitude flutter — that is inherent to
PaulStretch's phase randomisation (reference implementations measure the
same), not a defect. The traditional masker is reverb; `ReverbPreset.cathedral`
exists for exactly this.

## Testing

```bash
swift test -c release
```

168 tests cover FFT correctness against a scalar oracle, determinism, every
`StereoBuffer` transform, all pipeline modes, file I/O round trips and the
effects bakers. The load-bearing suite asserts that chunked output is
**bit-identical** to in-memory output across the full mode matrix and
arbitrary chunk sizes. The realtime suite proves the live chain matches the
offline bake sample-for-sample, is independent of quantum size, survives
parameter swaps mid-stream, and does not gate the audio when a block-based
stage withholds frames. (Use `-c release` — unoptimised FFT loops are
20–50× slower.)

## License

MIT License — see LICENSE file for details.

## Author

Created by David Sherlock ([ArrayPress](https://github.com/arraypress)) in 2026.
