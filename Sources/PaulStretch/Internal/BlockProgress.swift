//
//  BlockProgress.swift
//  SwiftPaulStretch
//
//  Thread-safe progress aggregation for multicore renders.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// Aggregates per-worker window counts into a single `0…1` progress stream.
///
/// Workers report batches of completed windows from multiple threads; the
/// counter serialises them behind a lock and forwards the running fraction
/// to the caller's progress closure (on the reporting worker's thread).
final class BlockProgress {
    private let lock = NSLock()
    private var done = 0
    private let total: Int
    private let callback: ((Double) -> Void)?

    init(total: Int, callback: ((Double) -> Void)?) {
        self.total = max(1, total)
        self.callback = callback
    }

    /// Records `n` more completed windows and reports the new fraction.
    func add(_ n: Int) {
        guard callback != nil else { return }
        lock.lock(); done += n; let d = done; lock.unlock()
        callback?(min(1.0, Double(d) / Double(total)))
    }
}
