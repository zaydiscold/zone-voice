// by zayd/cold @ zayd.wtf

import Foundation

/// One lane per loaded native decoder, shared across utterances. Jobs run one at a time and in
/// the order they were queued; chaining each job behind the previous one prevents a cancelled
/// old call overlapping its replacement.
///
/// The lane also knows when the model last did any work, so a caller can warm it before it is
/// needed (`warmUp`). On the phone, Fluid Speech Mini's Core ML CPU program is 1.14 GB of
/// file-backed memory. Under memory pressure iOS drops those pages while Zone idles in the
/// background, and the first decode after a pause read them back from flash: about 3 s on
/// every such dictation, whatever its length. A warm-up queued when the
/// recording starts moves that read under the person's speech.
///
/// Queueing is synchronous (a lock, not an actor hop), so a warm-up queued before an
/// utterance's first segment always runs ahead of it.
public final class SerialRecognitionDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var pending = 0
    private var lastFinished: TimeInterval?
    private let clock: @Sendable () -> TimeInterval

    /// - Parameter clock: seconds on a monotonic clock; tests inject their own.
    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// Runs `operation` after every job queued before it. Cancelling the caller cancels the job.
    public func run(priority: TaskPriority? = nil,
                    _ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        let job = enqueue(priority: priority, operation)
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    /// Queues `operation` ahead of any later job when the lane is idle: nothing queued or
    /// running, and no job has finished within `idle` seconds. A lane that has never run a job
    /// counts as idle. Its result and errors are discarded. Returns whether it was queued.
    @discardableResult
    public func warmUp(ifIdleFor idle: TimeInterval, priority: TaskPriority? = .userInitiated,
                       _ operation: @escaping @Sendable () async throws -> Void) -> Bool {
        lock.lock()
        let now = clock()
        guard pending == 0, lastFinished.map({ now - $0 >= idle }) ?? true else {
            lock.unlock()
            return false
        }
        _ = enqueueLocked(priority: priority) {
            try await operation()
            return ""
        }
        lock.unlock()
        return true
    }

    /// Seconds since the last job finished, or nil while one is queued or running or before
    /// the first. For logs and tests.
    public var idleSeconds: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard pending == 0, let lastFinished else { return nil }
        return clock() - lastFinished
    }

    public func drain() async {
        let last = lock.withLock { tail }
        await last?.value
    }

    private func enqueue(priority: TaskPriority?, _ operation: @escaping @Sendable () async throws -> String) -> Task<String, Error> {
        lock.lock(); defer { lock.unlock() }
        return enqueueLocked(priority: priority, operation)
    }

    /// Called with the lock held.
    private func enqueueLocked(priority: TaskPriority?, _ operation: @escaping @Sendable () async throws -> String) -> Task<String, Error> {
        let previous = tail
        pending += 1
        let job = Task(priority: priority) {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { [weak self] in
            _ = try? await job.value
            self?.finished()
        }
        return job
    }

    private func finished() {
        lock.lock()
        pending -= 1
        lastFinished = clock()
        lock.unlock()
    }
}
