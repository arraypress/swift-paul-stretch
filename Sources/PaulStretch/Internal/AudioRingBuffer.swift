//
//  AudioRingBuffer.swift
//  SwiftPaulStretch
//
//  Single-producer / single-consumer stereo ring buffer feeding the
//  realtime StretchSourceNode.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation
import os.lock

/// A fixed-capacity stereo float ring buffer for one producer thread and
/// one consumer (the realtime render callback).
///
/// Positions are monotonically increasing frame counters; an
/// `os_unfair_lock` guards only the counter reads/writes (nanoseconds), and
/// the sample copies happen outside the lock. That is safe in strict SPSC
/// use: the producer only writes frames the consumer hasn't been shown yet
/// (`writePos` advances *after* the copy), and the consumer only reads
/// frames the producer has finished (`readPos` advances *after* the copy),
/// so snapshotted ranges stay valid without holding the lock.
final class AudioRingBuffer {

    /// Capacity in frames (rounded up to a power of two for cheap masking).
    let capacity: Int
    private let mask: Int
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>

    private var lock = os_unfair_lock()
    /// Total frames ever read (consumer-owned, guarded by `lock`).
    private var readPos: Int64 = 0
    /// Total frames ever written (producer-owned, guarded by `lock`).
    private var writePos: Int64 = 0

    init(capacityFrames: Int) {
        self.capacity = nextPow2(max(4096, capacityFrames))
        self.mask = capacity - 1
        self.bufL = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        self.bufR = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        bufL.initialize(repeating: 0, count: capacity)
        bufR.initialize(repeating: 0, count: capacity)
    }

    deinit {
        bufL.deallocate()
        bufR.deallocate()
    }

    /// Frames currently buffered and ready to read.
    var availableFrames: Int {
        os_unfair_lock_lock(&lock)
        let n = Int(writePos - readPos)
        os_unfair_lock_unlock(&lock)
        return n
    }

    /// Frames of free space the producer can write into.
    var freeFrames: Int { capacity - availableFrames }

    /// Total frames the consumer has ever read (the playback clock).
    var framesRead: Int64 {
        os_unfair_lock_lock(&lock)
        let n = readPos
        os_unfair_lock_unlock(&lock)
        return n
    }

    /// Producer side: appends up to `count` frames, returning how many fit.
    func write(l: [Float], r: [Float], count: Int) -> Int {
        os_unfair_lock_lock(&lock)
        let free = capacity - Int(writePos - readPos)
        let start = writePos
        os_unfair_lock_unlock(&lock)

        let n = min(count, free)
        guard n > 0 else { return 0 }
        l.withUnsafeBufferPointer { lp in
            r.withUnsafeBufferPointer { rp in
                for i in 0..<n {
                    let idx = Int((start + Int64(i))) & mask
                    bufL[idx] = lp[i]
                    bufR[idx] = rp[i]
                }
            }
        }

        os_unfair_lock_lock(&lock)
        writePos = start + Int64(n)
        os_unfair_lock_unlock(&lock)
        return n
    }

    /// Consumer side (realtime-safe): copies up to `count` frames into the
    /// channel pointers, returning how many were available. The caller
    /// zero-fills any shortfall.
    func read(intoL outL: UnsafeMutablePointer<Float>,
              intoR outR: UnsafeMutablePointer<Float>,
              count: Int) -> Int {
        os_unfair_lock_lock(&lock)
        let avail = Int(writePos - readPos)
        let start = readPos
        os_unfair_lock_unlock(&lock)

        let n = min(count, avail)
        guard n > 0 else { return 0 }
        for i in 0..<n {
            let idx = Int((start + Int64(i))) & mask
            outL[i] = bufL[idx]
            outR[i] = bufR[idx]
        }

        os_unfair_lock_lock(&lock)
        readPos = start + Int64(n)
        os_unfair_lock_unlock(&lock)
        return n
    }
}
