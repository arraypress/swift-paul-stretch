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
  feedback), because `AVAudioEngine` graphs can't hold the feedback cycle
  shimmer needs. The wash climbs in octaves; bakes offline and streams.
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
    .package(url: "https://github.com/arraypress/swift-paul-stretch.git", from: "1.0.0")
]
```

Add `PaulStretch` to your target; add `PaulStretchEffects` as well if you
want the stock effect chain.

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
let slow   = source.applyingTapeSpeed(0.5)                              // varispeed
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

// Shimmer reverb (baked path only — feedback cycles can't live on an
// AVAudioEngine graph; hosts re-bake to audition):
fx.shimmerEnabled = true
fx.shimmerPitch = 12          // octave-up bloom (+7 for fifths)
fx.shimmerFeedback = 55
let halo = EffectsBaker.bake(drone, effects: fx)

// Or streamed, for long effected exports in bounded memory:
try StretchRenderer.renderToWAVFile(source, parameters: params, effects: fx, url: exportURL)
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

A bare stretch carries ~30 % amplitude flutter — that is inherent to
PaulStretch's phase randomisation (reference implementations measure the
same), not a defect. The traditional masker is reverb; `ReverbPreset.cathedral`
exists for exactly this.

## Testing

```bash
swift test -c release
```

57 tests cover FFT correctness against a scalar oracle, determinism, every
`StereoBuffer` transform, all pipeline modes, file I/O round trips and the
effects bakers. The load-bearing suite asserts that chunked output is
**bit-identical** to in-memory output across the full mode matrix and
arbitrary chunk sizes. (Use `-c release` — unoptimised FFT loops are
20–50× slower.)

## License

MIT License — see LICENSE file for details.

## Author

Created by David Sherlock ([ArrayPress](https://github.com/arraypress)) in 2026.
