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
    /// shimmering indefinitely. See ``SpectralFreezer``.
    case spectralFreeze
}
