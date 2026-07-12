//
//  SpectrumAnalyzer.swift
//  SwiftPaulStretch
//
//  A realtime log-band magnitude spectrum for level displays: feed it the
//  buffers from an audio-engine tap, get back smoothed 0…1 band values.
//
//  Created by David Sherlock on 7/12/26.
//

import AVFoundation
import Accelerate

/// Computes a log-spaced band magnitude spectrum from audio-thread buffers,
/// for driving a live spectrum display.
///
/// Install a tap on your engine's mixer and forward its buffers; the
/// analyzer windows the first channel, FFTs it, folds the bins into
/// `bandCount` logarithmically spaced bands between `minFrequency` and
/// `maxFrequency`, maps −60…0 dB to 0…1, and applies fast-attack /
/// slow-decay smoothing for a musical meter feel. Results arrive through
/// ``onBands`` on the same (audio) thread that called ``process(_:)`` —
/// hop to the main actor before touching UI.
///
/// ```swift
/// let analyzer = SpectrumAnalyzer()
/// analyzer.onBands = { bands in Task { @MainActor in view.bands = bands } }
/// mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
///     analyzer.process(buffer)
/// }
/// ```
public final class SpectrumAnalyzer: @unchecked Sendable {

    /// The number of log-spaced output bands.
    public let bandCount: Int

    /// Receives the smoothed band values (`0…1`, `bandCount` of them) after
    /// every ``process(_:)`` call, on the calling thread.
    public var onBands: (([Float]) -> Void)?

    private let n: Int
    private let half: Int
    private let fft: SpectrumFFT?
    private let minFrequency: Double
    private let maxFrequency: Double
    private var window: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var smoothed: [Float]

    /// Creates a spectrum analyzer.
    ///
    /// - Parameters:
    ///   - bandCount: The number of log-spaced output bands. Defaults to `56`.
    ///   - fftSize: The FFT length (a power of two). Defaults to `1024` —
    ///     ~43 Hz resolution at 44.1 kHz, plenty for a meter.
    ///   - minFrequency: The low edge of the displayed range, in hertz.
    ///   - maxFrequency: The high edge of the displayed range, in hertz.
    public init(bandCount: Int = 56,
                fftSize: Int = 1024,
                minFrequency: Double = 40,
                maxFrequency: Double = 18_000) {
        self.bandCount = max(1, bandCount)
        self.n = fftSize
        self.half = fftSize / 2
        self.minFrequency = minFrequency
        self.maxFrequency = max(maxFrequency, minFrequency + 1)
        self.fft = SpectrumFFT(n: fftSize)
        self.window = (0..<fftSize).map {
            Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize - 1)))
        }
        self.real = [Float](repeating: 0, count: fftSize)
        self.imag = [Float](repeating: 0, count: fftSize)
        self.smoothed = [Float](repeating: 0, count: self.bandCount)
    }

    /// Analyzes one tap buffer (first channel) and reports the bands.
    ///
    /// Safe to call from the audio thread; does nothing when the buffer has
    /// no float data or the FFT size was not a power of two.
    ///
    /// - Parameter buffer: A PCM buffer from an audio-engine tap.
    public func process(_ buffer: AVAudioPCMBuffer) {
        guard let fft, let ch = buffer.floatChannelData else { return }
        let m = min(Int(buffer.frameLength), n)
        for i in 0..<n { real[i] = i < m ? ch[0][i] * window[i] : 0; imag[i] = 0 }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in fft.forward(rp.baseAddress!, ip.baseAddress!) }
        }
        let sr = buffer.format.sampleRate
        var bands = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let f0 = minFrequency * pow(maxFrequency / minFrequency, Double(b) / Double(bandCount))
            let f1 = minFrequency * pow(maxFrequency / minFrequency, Double(b + 1) / Double(bandCount))
            let k0 = max(1, Int(f0 / sr * Double(n)))
            let k1 = min(half - 1, max(k0, Int(f1 / sr * Double(n))))
            var mx: Float = 0
            for k in k0...k1 { mx = max(mx, (real[k] * real[k] + imag[k] * imag[k]).squareRoot()) }
            let db = 20 * log10f(mx / Float(half) + 1e-7)   // ~ -140…0
            let v = min(1, max(0, (db + 60) / 60))          // map -60…0 dB → 0…1
            // Fast attack, slow decay for a musical meter feel.
            smoothed[b] = v > smoothed[b] ? v : smoothed[b] * 0.82 + v * 0.18
            bands[b] = smoothed[b]
        }
        onBands?(bands)
    }

    /// Clears the decay smoothing (e.g. when playback stops) so the next
    /// buffer starts from silence instead of decaying stale peaks.
    public func reset() {
        for i in 0..<smoothed.count { smoothed[i] = 0 }
    }
}

/// Minimal vDSP complex FFT for the spectrum tap (the render engine's own
/// FFT stays internal to the stretch kernels).
private final class SpectrumFFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init?(n: Int) {
        guard n > 1, (n & (n - 1)) == 0 else { return nil }
        self.n = n
        self.log2n = vDSP_Length(flsl(n) - 1)
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = s
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func forward(_ real: UnsafeMutablePointer<Float>, _ imag: UnsafeMutablePointer<Float>) {
        var sp = DSPSplitComplex(realp: real, imagp: imag)
        vDSP_fft_zip(setup, &sp, 1, log2n, FFTDirection(FFT_FORWARD))
    }
}
