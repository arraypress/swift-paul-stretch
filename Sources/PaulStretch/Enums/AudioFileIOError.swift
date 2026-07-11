//
//  AudioFileIOError.swift
//  SwiftPaulStretch
//
//  Errors thrown by the audio file reading/writing helpers.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// Errors thrown by ``AudioFileIO`` and ``StreamingAudioWriter``.
public enum AudioFileIOError: LocalizedError, Sendable {

    /// An audio buffer could not be allocated.
    case cannotAllocateBuffer

    /// Sample-rate/format conversion failed, with the underlying reason.
    case conversionFailed(String)

    /// ``StreamingAudioWriter/append(l:r:)`` was called after
    /// ``StreamingAudioWriter/close()``.
    case writerClosed

    public var errorDescription: String? {
        switch self {
        case .cannotAllocateBuffer: return "Could not allocate audio buffer."
        case .conversionFailed(let m): return "Audio conversion failed: \(m)"
        case .writerClosed: return "The WAV writer has already been closed."
        }
    }
}
