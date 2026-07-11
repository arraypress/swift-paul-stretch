//
//  StretchMode.swift
//  SwiftPaulStretch
//
//  The three rendering engines the library can drive a source through.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// The engine used to turn a short source into a long ambient render.
///
/// Host apps are free to present these under their own labels (for example
/// "Drone / Slow / Freeze") — the enum names follow the underlying
/// algorithms rather than any particular UI.
public enum StretchMode: String, CaseIterable, Sendable, Codable {

    /// Classic PaulStretch — a windowed STFT with per-window phase
    /// randomisation and 4× Hann overlap-add, producing the characteristic
    /// smeared, choir-like wash. Supports layering, FFT-domain pitch shift
    /// and onset preservation. See ``PaulStretcher``.
    case paulStretch

    /// Tape-style slow-down ("slowed + reverb"). The source is varispeed
    /// resampled (longer *and* lower-pitched, like slowing a tape machine)
    /// and then tile-crossfaded to fill the target duration. No FFT is
    /// involved, so this mode is extremely cheap.
    case tapeSlow

    /// Spectral freeze — the magnitude spectrum is captured at a single
    /// instant (``StretchParameters/freezePosition``) and resynthesised
    /// forever with fresh random phase every hop: one frozen moment,
    /// shimmering indefinitely. With ``StretchParameters/freezeScan`` above
    /// zero the capture point drifts through the source, so the frozen
    /// spectrum slowly morphs. See ``SpectralFreezer``.
    case spectralFreeze

    /// Classic phase-vocoder time stretch — phases are *propagated* between
    /// windows instead of randomised, preserving the source's structure and
    /// transient identity. The clean way to slow audio 2–8× without the
    /// PaulStretch wash and without the pitch drop of ``tapeSlow``. Use
    /// short windows (``StretchParameters/windowSeconds`` around
    /// `0.05`–`0.1`); layering and phase randomness are ignored.
    case phaseVocoder

    /// Granular cloud — dense, Hann-windowed grains scattered from a scrub
    /// position that advances through the source, with per-grain position
    /// jitter, pitch spread and stereo pan. The other classic ambient
    /// texture engine: grainy and shimmering where PaulStretch is smeared
    /// and choral. Tuned by the `grain…` parameters on
    /// ``StretchParameters``.
    case granularCloud
}
