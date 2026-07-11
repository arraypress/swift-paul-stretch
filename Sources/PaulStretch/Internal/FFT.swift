//
//  FFT.swift
//  SwiftPaulStretch
//
//  Reusable vDSP complex FFT (SIMD) plus a dependency-free scalar reference
//  kept as a correctness oracle for the test suite.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import Accelerate

/// Reusable vDSP complex FFT for a fixed power-of-two size.
///
/// Operates in place on separate real/imaginary `Float` buffers (viewed as a
/// `DSPSplitComplex`). Convention: the forward transform is **unscaled**; the
/// inverse is normalised by `1/N`, so `inverse(forward(x)) == x`. One
/// instance is created per worker thread — the underlying `FFTSetup` is not
/// re-entrant.
final class PSFFT {
    /// The transform size (a power of two).
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    /// Creates an FFT for size `n`, or fails if `n` is not a power of two
    /// greater than one.
    init?(n: Int) {
        guard n > 1, (n & (n - 1)) == 0 else { return nil }
        self.n = n
        self.log2n = vDSP_Length(flsl(n) - 1)
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = s
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Unscaled forward transform, in place.
    func forward(_ real: UnsafeMutablePointer<Float>, _ imag: UnsafeMutablePointer<Float>) {
        var sp = DSPSplitComplex(realp: real, imagp: imag)
        vDSP_fft_zip(setup, &sp, 1, log2n, FFTDirection(FFT_FORWARD))
    }

    /// Inverse transform normalised by `1/N`, in place.
    func inverse(_ real: UnsafeMutablePointer<Float>, _ imag: UnsafeMutablePointer<Float>) {
        var sp = DSPSplitComplex(realp: real, imagp: imag)
        vDSP_fft_zip(setup, &sp, 1, log2n, FFTDirection(FFT_INVERSE))
        var scale = Float(1.0 / Double(n))
        vDSP_vsmul(real, 1, &scale, real, 1, vDSP_Length(n))
        vDSP_vsmul(imag, 1, &scale, imag, 1, vDSP_Length(n))
    }
}

// MARK: - Scalar reference (correctness oracle, used by the test suite)

/// A direct, dependency-free radix-2 FFT with the same conventions as
/// ``PSFFT`` (unscaled forward, `1/N` inverse). Slow — kept only so tests
/// can verify the vDSP path against an independent implementation.
func scalarFFT(_ real: UnsafeMutablePointer<Float>,
               _ imag: UnsafeMutablePointer<Float>,
               _ n: Int,
               _ inverse: Bool) {
    var i = 1
    var j = 0
    while i < n {
        var bit = n >> 1
        while (j & bit) != 0 { j ^= bit; bit >>= 1 }
        j ^= bit
        if i < j {
            let tr = real[i]; real[i] = real[j]; real[j] = tr
            let ti = imag[i]; imag[i] = imag[j]; imag[j] = ti
        }
        i += 1
    }
    var len = 2
    while len <= n {
        let halfLen = len >> 1
        let angle = (inverse ? 2.0 : -2.0) * Double.pi / Double(len)
        let wReal = cos(angle)
        let wImag = sin(angle)
        var base = 0
        while base < n {
            var curReal = 1.0
            var curImag = 0.0
            for k in 0..<halfLen {
                let aReal = Double(real[base + k])
                let aImag = Double(imag[base + k])
                let cr = Double(real[base + k + halfLen])
                let ci = Double(imag[base + k + halfLen])
                let bReal = cr * curReal - ci * curImag
                let bImag = cr * curImag + ci * curReal
                real[base + k] = Float(aReal + bReal)
                imag[base + k] = Float(aImag + bImag)
                real[base + k + halfLen] = Float(aReal - bReal)
                imag[base + k + halfLen] = Float(aImag - bImag)
                let nextReal = curReal * wReal - curImag * wImag
                let nextImag = curReal * wImag + curImag * wReal
                curReal = nextReal
                curImag = nextImag
            }
            base += len
        }
        len <<= 1
    }
    if inverse {
        let invN = 1.0 / Double(n)
        for idx in 0..<n {
            real[idx] = Float(Double(real[idx]) * invN)
            imag[idx] = Float(Double(imag[idx]) * invN)
        }
    }
}
