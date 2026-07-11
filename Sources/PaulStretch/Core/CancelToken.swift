//
//  CancelToken.swift
//  SwiftPaulStretch
//
//  Thread-safe cooperative cancellation flag shared with render workers.
//
//  Created by David Sherlock on 7/12/26.
//

import Foundation

/// A thread-safe, cooperative cancellation flag for long renders.
///
/// Create a token on the UI side, hand its ``isCancelled`` into a render's
/// `isCancelled` closure, and call ``cancel()`` from any thread to stop the
/// work. Cancelled in-memory renders return an empty ``StereoBuffer``;
/// cancelled chunked renders stop delivering and return `false`.
///
/// ```swift
/// let token = CancelToken()
/// Task.detached {
///     let out = StretchRenderer.render(source, parameters: params,
///                                      isCancelled: { token.isCancelled })
/// }
/// // later, from the UI:
/// token.cancel()
/// ```
public final class CancelToken: @unchecked Sendable {

    private let lock = NSLock()
    private var flag = false

    /// Creates a token in the not-cancelled state.
    public init() {}

    /// Whether ``cancel()`` has been called. Safe to poll from any thread.
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    /// Requests cancellation. Safe to call from any thread; irreversible.
    public func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }
}
