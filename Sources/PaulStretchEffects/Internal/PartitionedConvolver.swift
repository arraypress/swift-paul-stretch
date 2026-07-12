//
//  PartitionedConvolver.swift
//  SwiftPaulStretch
//
//  Uniform-partition FFT convolution (overlap-add with a frequency-domain
//  delay line) — streams arbitrarily long impulse responses in fixed-size
//  blocks. The engine behind ConvolutionReverb.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import Accelerate

// The AVAudioUnit effect classes do not exist on watchOS — this product
// compiles to an empty module there. The PaulStretch core is unaffected.
#if !os(watchOS)

/// Minimal vDSP complex FFT for the convolver (the core module's FFT is
/// internal to its package).
private final class ConvFFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    init?(n: Int) {
        guard n > 1, (n & (n - 1)) == 0 else { return nil }
        self.n = n
        self.log2n = vDSP_Length(Int(log2(Double(n)).rounded()))
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = s
    }
    deinit { vDSP_destroy_fftsetup(setup) }
    func forward(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        var sp = DSPSplitComplex(realp: re, imagp: im)
        vDSP_fft_zip(setup, &sp, 1, log2n, FFTDirection(FFT_FORWARD))
    }
    func inverse(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        var sp = DSPSplitComplex(realp: re, imagp: im)
        vDSP_fft_zip(setup, &sp, 1, log2n, FFTDirection(FFT_INVERSE))
        var scale = Float(1.0 / Double(n))
        vDSP_vsmul(re, 1, &scale, re, 1, vDSP_Length(n))
        vDSP_vsmul(im, 1, &scale, im, 1, vDSP_Length(n))
    }
}

/// Streaming FFT convolution of a mono signal with a mono impulse response,
/// in uniform partitions of `blockSize` frames.
///
/// Feed exactly `blockSize` frames per call; the output block is the
/// convolution's next `blockSize` frames (the IR's tail keeps flowing after
/// the input stops — feed zero blocks to drain it).
final class PartitionedConvolver {
    let blockSize: Int
    private let fftSize: Int
    private let fft: ConvFFT
    /// IR partition spectra.
    private var irRe: [[Float]] = []
    private var irIm: [[Float]] = []
    /// Frequency-domain delay line of past input spectra (ring).
    private var inRe: [[Float]]
    private var inIm: [[Float]]
    private var fdlIndex = 0
    /// Overlap carried between output blocks.
    private var overlap: [Float]
    // Scratch.
    private var re: [Float]
    private var im: [Float]
    private var accRe: [Float]
    private var accIm: [Float]

    /// The number of partitions (exposed for cost reasoning in tests).
    var partitionCount: Int { irRe.count }

    init?(impulse: [Float], blockSize: Int = 4096) {
        guard !impulse.isEmpty, blockSize > 0, (blockSize & (blockSize - 1)) == 0 else { return nil }
        self.blockSize = blockSize
        self.fftSize = blockSize * 2
        guard let fft = ConvFFT(n: fftSize) else { return nil }
        self.fft = fft

        let partitions = (impulse.count + blockSize - 1) / blockSize
        self.inRe = Array(repeating: [Float](repeating: 0, count: fftSize), count: partitions)
        self.inIm = Array(repeating: [Float](repeating: 0, count: fftSize), count: partitions)
        self.overlap = [Float](repeating: 0, count: blockSize)
        self.re = [Float](repeating: 0, count: fftSize)
        self.im = [Float](repeating: 0, count: fftSize)
        self.accRe = [Float](repeating: 0, count: fftSize)
        self.accIm = [Float](repeating: 0, count: fftSize)

        // Precompute each partition's spectrum.
        for p in 0..<partitions {
            var pr = [Float](repeating: 0, count: fftSize)
            var pi = [Float](repeating: 0, count: fftSize)
            let start = p * blockSize
            let count = min(blockSize, impulse.count - start)
            for i in 0..<count { pr[i] = impulse[start + i] }
            pr.withUnsafeMutableBufferPointer { rp in
                pi.withUnsafeMutableBufferPointer { ip in
                    fft.forward(rp.baseAddress!, ip.baseAddress!)
                }
            }
            irRe.append(pr)
            irIm.append(pi)
        }
    }

    /// Convolves the next block. `input` must hold exactly `blockSize`
    /// frames (zero-pad the final one); returns `blockSize` frames.
    func processBlock(_ input: [Float]) -> [Float] {
        let partitions = irRe.count
        // Push the new input spectrum into the delay line.
        for i in 0..<blockSize { re[i] = input[i]; im[i] = 0 }
        for i in blockSize..<fftSize { re[i] = 0; im[i] = 0 }
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                fft.forward(rp.baseAddress!, ip.baseAddress!)
            }
        }
        fdlIndex = (fdlIndex + 1) % partitions
        inRe[fdlIndex] = re
        inIm[fdlIndex] = im

        // Accumulate Σ input[t−p] × ir[p] in the frequency domain.
        for i in 0..<fftSize { accRe[i] = 0; accIm[i] = 0 }
        for p in 0..<partitions {
            let slot = (fdlIndex - p + partitions) % partitions
            inRe[slot].withUnsafeBufferPointer { xr in
            inIm[slot].withUnsafeBufferPointer { xi in
            irRe[p].withUnsafeBufferPointer { hr in
            irIm[p].withUnsafeBufferPointer { hi in
            accRe.withUnsafeMutableBufferPointer { ar in
            accIm.withUnsafeMutableBufferPointer { ai in
                var x = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: xr.baseAddress!),
                                        imagp: UnsafeMutablePointer(mutating: xi.baseAddress!))
                var h = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: hr.baseAddress!),
                                        imagp: UnsafeMutablePointer(mutating: hi.baseAddress!))
                var acc = DSPSplitComplex(realp: ar.baseAddress!, imagp: ai.baseAddress!)
                // acc += x * h (complex multiply-accumulate)
                vDSP_zvma(&x, 1, &h, 1, &acc, 1, &acc, 1, vDSP_Length(fftSize))
            }}}}}}
        }

        // Back to time domain; emit block + carried overlap.
        accRe.withUnsafeMutableBufferPointer { rp in
            accIm.withUnsafeMutableBufferPointer { ip in
                fft.inverse(rp.baseAddress!, ip.baseAddress!)
            }
        }
        var out = [Float](repeating: 0, count: blockSize)
        for i in 0..<blockSize {
            out[i] = accRe[i] + overlap[i]
            overlap[i] = accRe[blockSize + i]
        }
        return out
    }
}

#endif  // !os(watchOS)
