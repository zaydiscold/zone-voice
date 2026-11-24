// by zayd/cold @ zayd.wtf

import Foundation

/// Runs async work that must not hang forever, and fails visibly when it stops making progress.
///
/// A meeting once sat at "Transcribing, 100%" on the phone because nothing bounded a step that
/// never returned. `Watchdog.run` gives every such step a limit: the work beats a `Pulse` as it
/// makes progress (a chunk fed, a diarizer window done), and when no beat arrives for `limit`
/// seconds the caller gets `Watchdog.Stalled` at once. The work itself is cancelled; work that
/// ignores cancellation keeps running detached, but the caller is never stuck behind it.
public enum Watchdog {
    /// The work made no progress for `seconds`.
    public struct Stalled: LocalizedError, Equatable, Sendable {
        public let what: String
        public let seconds: Double
        public init(what: String, seconds: Double) {
            self.what = what
            self.seconds = seconds
        }
        public var errorDescription: String? {
            "\(what) did not respond for \(Int(seconds.rounded())) seconds"
        }
    }

    /// Progress beats from the work, readable from any thread.
    public final class Pulse: @unchecked Sendable {
        private let lock = NSLock()
        private var last: TimeInterval
        private let clock: @Sendable () -> TimeInterval

        public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
            self.clock = clock
            last = clock()
        }

        /// The work is alive and moving.
        public func beat() {
            let now = clock()
            lock.lock()
            last = now
            lock.unlock()
        }

        /// Seconds since the last beat (or since creation).
        public var idle: TimeInterval {
            let now = clock()
            lock.lock()
            defer { lock.unlock() }
            return max(0, now - last)
        }
    }

    /// Runs `operation`, throwing `Stalled` once `pulse` has been idle for `limit` seconds. With
    /// no pulse (or one never beaten) `limit` is a plain deadline. Cancelling the caller cancels
    /// the work and throws `CancellationError`.
    public static func run<T: Sendable>(
        what: String,
        limit: TimeInterval,
        pulse: Pulse = Pulse(),
        checkEvery: TimeInterval = 0.25,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let outcome = Outcome<T>()
        let work = Task { try await operation() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                outcome.install(continuation)
                Task {
                    do { outcome.resolve(.success(try await work.value)) }
                    catch { outcome.resolve(.failure(error)) }
                }
                Task {
                    while !outcome.isResolved {
                        if pulse.idle >= limit {
                            // Claim the timeout before cancellation can produce a different error.
                            outcome.resolve(.failure(Stalled(what: what, seconds: limit)))
                            work.cancel()
                            return
                        }
                        try? await Task.sleep(nanoseconds: UInt64(max(checkEvery, 0.01) * 1_000_000_000))
                    }
                }
            }
        } onCancel: {
            work.cancel()
            outcome.resolve(.failure(CancellationError()))
        }
    }

    /// Exactly one resolution reaches the continuation, whichever of work, timer or cancel is first.
    private final class Outcome<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var early: Result<T, Error>?
        private var resolved = false

        var isResolved: Bool { lock.withLock { resolved } }

        func install(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            if let early {
                lock.unlock()
                continuation.resume(with: early)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resolve(_ result: Result<T, Error>) {
            lock.lock()
            guard !resolved else { lock.unlock(); return }
            resolved = true
            if let continuation {
                self.continuation = nil
                lock.unlock()
                continuation.resume(with: result)
            } else {
                // Cancelled before the continuation was installed.
                early = result
                lock.unlock()
            }
        }
    }
}
