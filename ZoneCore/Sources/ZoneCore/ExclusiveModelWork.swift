// by zayd/cold @ zayd.wtf

import Foundation

/// A watchdog can stop waiting without stopping a native model call. Keep ownership inside
/// that call until it really returns; retries fail visibly instead of accumulating model work.
public final class ExclusiveModelWork: @unchecked Sendable {
    public struct Busy: LocalizedError {
        public init() {}
        public var errorDescription: String? { "The previous speaker-labeling task is still stopping. Try again after it finishes." }
    }
    private let lock = NSLock()
    private var occupied = false
    public init() {}

    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let acquired = lock.withLock {
            guard !occupied else { return false }
            occupied = true
            return true
        }
        guard acquired else { throw Busy() }
        defer { lock.withLock { occupied = false } }
        try Task.checkCancellation()
        return try await operation()
    }
}
